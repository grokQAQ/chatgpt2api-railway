from __future__ import annotations

import json
import time
from typing import Any

from sqlalchemy import Boolean, Column, String, Text, create_engine, Integer, text
from sqlalchemy.exc import OperationalError
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker

from services.storage.base import StorageBackend

# CockroachDB Serverless 使用 Serializable 隔离级别，多实例并发写同一行时会报
# SerializationFailure (RETRY_SERIALIZABLE)，需要自动重试。
_COCKROACH_RETRY_CODES = {"40001", "RETRY_SERIALIZABLE"}
_MAX_TXN_RETRIES = 3
_TXN_RETRY_BASE_DELAY = 0.1  # 秒，指数退避

Base = declarative_base()


class AccountModel(Base):
    """账号数据模型"""
    __tablename__ = "accounts"

    id = Column(Integer, primary_key=True, autoincrement=True)
    access_token = Column(String(2048), unique=True, nullable=False, index=True)
    data = Column(Text, nullable=False)  # JSON 格式存储完整账号数据
    deleted = Column(Boolean, default=False, nullable=False)  # 软删除标记
    deleted_at = Column(String(64), nullable=True)  # 软删除时间


class AuthKeyModel(Base):
    """鉴权密钥数据模型"""
    __tablename__ = "auth_keys"

    id = Column(Integer, primary_key=True, autoincrement=True)
    key_id = Column(String(255), unique=True, nullable=False, index=True)
    data = Column(Text, nullable=False)


class DatabaseStorageBackend(StorageBackend):
    """数据库存储后端（支持 SQLite、PostgreSQL、CockroachDB 等）"""

    def __init__(self, database_url: str):
        self.database_url = database_url
        self.engine = create_engine(
            database_url,
            pool_pre_ping=True,
            pool_recycle=3600,
        )

        # CockroachDB compatibility: monkey-patch dialect version parser
        # Must happen BEFORE create_all which triggers first connect
        from sqlalchemy.dialects.postgresql.base import PGDialect
        _orig_get_version = PGDialect._get_server_version_info
        def _patched_get_version(self, connection):
            try:
                return _orig_get_version(self, connection)
            except (AssertionError, ValueError):
                return (14, 0, 0)
        PGDialect._get_server_version_info = _patched_get_version

        Base.metadata.create_all(self.engine)
        self.Session = sessionmaker(bind=self.engine)

        # 迁移：为已有表添加 deleted / deleted_at 列
        self._migrate_soft_delete_columns()

    def load_accounts(self) -> list[dict[str, Any]]:
        """从数据库加载账号数据（跳过已软删除的记录）"""
        session = self.Session()
        try:
            accounts = []
            for row in session.query(AccountModel).filter(AccountModel.deleted == False):  # noqa: E712
                try:
                    account_data = json.loads(row.data)
                    if isinstance(account_data, dict):
                        accounts.append(account_data)
                except json.JSONDecodeError:
                    continue
            return accounts
        finally:
            session.close()

    def save_accounts(self, accounts: list[dict[str, Any]]) -> None:
        """保存账号数据到数据库（UPSERT 模式，不会覆盖其他实例写入的新数据）"""
        self._upsert_rows(AccountModel, accounts, "access_token")

    def delete_accounts(self, tokens: list[str]) -> int:
        """软删除指定 access_token 的账号（标记 deleted=True），返回删除数量。
        同时清理超过 7 天的旧软删除记录。
        """
        if not tokens:
            return 0
        for attempt in range(_MAX_TXN_RETRIES):
            session = self.Session()
            try:
                now_str = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
                rows = session.query(AccountModel).filter(
                    AccountModel.access_token.in_(tokens),
                    AccountModel.deleted == False,  # noqa: E712
                ).all()
                count = len(rows)
                for row in rows:
                    row.deleted = True
                    row.deleted_at = now_str
                # 清理超过 7 天的旧软删除记录
                cutoff = time.strftime(
                    "%Y-%m-%dT%H:%M:%SZ",
                    time.gmtime(time.time() - 7 * 24 * 3600),
                )
                session.query(AccountModel).filter(
                    AccountModel.deleted == True,  # noqa: E712
                    AccountModel.deleted_at < cutoff,
                ).delete(synchronize_session="fetch")
                session.commit()
                return count
            except Exception as e:
                session.rollback()
                if self._is_serialization_error(e) and attempt < _MAX_TXN_RETRIES - 1:
                    delay = _TXN_RETRY_BASE_DELAY * (2 ** attempt)
                    print(f"[storage] CockroachDB SerializationFailure，第{attempt + 1}次重试，等待{delay:.1f}s...")
                    time.sleep(delay)
                    continue
                raise e
            finally:
                session.close()
        return 0

    def load_auth_keys(self) -> list[dict[str, Any]]:
        """加载所有鉴权密钥数据"""
        return self._load_rows(AuthKeyModel)

    def save_auth_keys(self, auth_keys: list[dict[str, Any]]) -> None:
        """保存鉴权密钥数据到数据库（UPSERT 模式）"""
        self._upsert_rows(AuthKeyModel, auth_keys, "id", "key_id")

    def _load_rows(self, model: type[AccountModel] | type[AuthKeyModel]) -> list[dict[str, Any]]:
        session = self.Session()
        try:
            items = []
            for row in session.query(model).all():
                try:
                    item_data = json.loads(row.data)
                    if isinstance(item_data, dict):
                        items.append(item_data)
                except json.JSONDecodeError:
                    continue
            return items
        finally:
            session.close()

    @staticmethod
    def _is_serialization_error(exc: Exception) -> bool:
        """判断是否为 CockroachDB SerializationFailure，需要重试。"""
        msg = str(exc)
        if any(code in msg for code in _COCKROACH_RETRY_CODES):
            return True
        if isinstance(exc, OperationalError):
            orig = getattr(exc, "orig", None)
            if orig is not None:
                orig_msg = str(orig)
                if any(code in orig_msg for code in _COCKROACH_RETRY_CODES):
                    return True
                # psycopg2 errors have a .pgcode attribute
                pgcode = getattr(orig, "pgcode", None)
                if pgcode and str(pgcode) == "40001":
                    return True
        return False

    def _upsert_rows(
        self,
        model: type[AccountModel] | type[AuthKeyModel],
        items: list[dict[str, Any]],
        source_key: str,
        target_key: str | None = None,
    ) -> None:
        """UPSERT 模式：已有的更新 data，没有的插入，不删除其他实例写入的数据。
        遇到 CockroachDB SerializationFailure 自动重试（最多3次，指数退避）。
        对于 AccountModel：跳过已软删除的行，防止其他实例把已删除账号写回数据库。
        """
        for attempt in range(_MAX_TXN_RETRIES):
            session = self.Session()
            try:
                col_name = target_key or source_key
                col = getattr(model, col_name)

                incoming_keys: set[str] = set()
                for item in items:
                    if not isinstance(item, dict):
                        continue
                    key_value = str(item.get(source_key) or "").strip()
                    if not key_value:
                        continue
                    incoming_keys.add(key_value)
                    data_json = json.dumps(item, ensure_ascii=False)

                    existing = session.query(model).filter(col == key_value).first()
                    if existing:
                        # 如果是 AccountModel 且已被软删除，跳过（防止写回已删除的账号）
                        if model is AccountModel and getattr(existing, "deleted", False):
                            continue
                        existing.data = data_json
                    else:
                        session.add(
                            model(**{col_name: key_value}, data=data_json)
                        )

                session.commit()
                return
            except Exception as e:
                session.rollback()
                if self._is_serialization_error(e) and attempt < _MAX_TXN_RETRIES - 1:
                    delay = _TXN_RETRY_BASE_DELAY * (2 ** attempt)
                    print(f"[storage] CockroachDB SerializationFailure，第{attempt + 1}次重试，等待{delay:.1f}s...")
                    time.sleep(delay)
                    continue
                raise e
            finally:
                session.close()

    def _save_rows(
        self,
        model: type[AccountModel] | type[AuthKeyModel],
        items: list[dict[str, Any]],
        source_key: str,
        target_key: str | None = None,
    ) -> None:
        """保留旧接口兼容，内部调用 _upsert_rows。"""
        self._upsert_rows(model, items, source_key, target_key)

    def list_deleted_tokens(self) -> list[str]:
        """返回所有已软删除的 access_token 列表（供多实例同步使用）。"""
        session = self.Session()
        try:
            return [
                row.access_token
                for row in session.query(AccountModel).filter(
                    AccountModel.deleted == True  # noqa: E712
                )
            ]
        finally:
            session.close()

    def _migrate_soft_delete_columns(self) -> None:
        """为已有的 accounts 表添加 deleted / deleted_at 列（兼容已有数据库）。"""
        session = self.Session()
        try:
            for col_name, col_type in [("deleted", "BOOLEAN DEFAULT FALSE"), ("deleted_at", "VARCHAR(64)")]:
                try:
                    session.execute(text(
                        f"ALTER TABLE accounts ADD COLUMN IF NOT EXISTS {col_name} {col_type}"
                    ))
                    session.commit()
                except Exception:
                    session.rollback()
        finally:
            session.close()

    def health_check(self) -> dict[str, Any]:
        """健康检查"""
        try:
            session = self.Session()
            try:
                session.execute(text("SELECT 1"))
                count = session.query(AccountModel).count()
                auth_key_count = session.query(AuthKeyModel).count()
                return {
                    "status": "healthy",
                    "backend": "database",
                    "database_url": self._mask_password(self.database_url),
                    "account_count": count,
                    "auth_key_count": auth_key_count,
                }
            finally:
                session.close()
        except Exception as e:
            return {
                "status": "unhealthy",
                "backend": "database",
                "error": str(e),
            }

    def get_backend_info(self) -> dict[str, Any]:
        """获取存储后端信息"""
        db_type = "unknown"
        if "sqlite" in self.database_url:
            db_type = "sqlite"
        elif "cockroach" in self.database_url:
            db_type = "cockroachdb"
        elif "postgresql" in self.database_url or "postgres" in self.database_url:
            db_type = "postgresql"
        elif "mysql" in self.database_url:
            db_type = "mysql"

        return {
            "type": "database",
            "db_type": db_type,
            "description": f"数据库存储 ({db_type})",
            "database_url": self._mask_password(self.database_url),
        }

    @staticmethod
    def _mask_password(url: str) -> str:
        """隐藏数据库连接字符串中的密码"""
        if "://" not in url:
            return url
        try:
            protocol, rest = url.split("://", 1)
            if "@" in rest:
                credentials, host = rest.split("@", 1)
                if ":" in credentials:
                    username, _ = credentials.split(":", 1)
                    return f"{protocol}://{username}:****@{host}"
            return url
        except Exception:
            return url
