ARG BUILDPLATFORM
ARG TARGETPLATFORM
ARG TARGETARCH

FROM --platform=$BUILDPLATFORM node:22-alpine AS web-build

WORKDIR /app/web

COPY web/package.json web/bun.lock ./
RUN npm install

COPY VERSION /app/VERSION
COPY CHANGELOG.md /app/CHANGELOG.md
COPY web ./
RUN NEXT_PUBLIC_APP_VERSION="$(cat /app/VERSION)" npm run build


FROM --platform=$TARGETPLATFORM python:3.13-slim AS app

ARG TARGETPLATFORM
ARG TARGETARCH

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_LINK_MODE=copy \
    DISPLAY=:99

WORKDIR /app

# 安装系统依赖
# - git: Git 存储后端需要 / FlareSolverr 克隆需要
# - libpq-dev: PostgreSQL 客户端库
# - gcc: 编译 psycopg2-binary 需要
# - chromium, xvfb: FlareSolverr 绕过 Cloudflare 需要
# - curl: 健康检查 / 订阅获取
# - unzip: 安装 xray-core 需要
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    libpq-dev \
    gcc \
    openssl \
    chromium \
    chromium-driver \
    xvfb \
    curl \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# 安装 xray-core（用于 VLESS/VMess/Trojan 代理）
RUN ARCH=$(case "$(dpkg --print-architecture)" in \
        amd64) echo "linux-64";; \
        arm64) echo "linux-arm64-v8a";; \
        *) echo "linux-64";; \
    esac) \
    && curl -fsSL "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-${ARCH}.zip" -o /tmp/xray.zip \
    && unzip -o /tmp/xray.zip -d /usr/local/bin xray \
    && chmod +x /usr/local/bin/xray \
    && rm -f /tmp/xray.zip \
    && xray version

# 安装 FlareSolverr（从源码，用于绕过 Cloudflare）
RUN pip install --no-cache-dir uv \
    && git clone https://github.com/FlareSolverr/FlareSolverr.git /opt/flaresolverr \
    && cd /opt/flaresolverr \
    && pip install --no-cache-dir -r requirements.txt \
    && rm -rf /root/.cache/pip

# 验证 Chromium 可用
RUN chromium --version || echo "WARNING: chromium not found in PATH"

COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

COPY main.py ./
COPY VERSION ./
# config.json 被 .gitignore 排除，无法上传到 HF Space，直接生成默认配置
# 代理配置在运行时由 entrypoint.sh 根据 PROXY_SUB_URL 环境变量动态生成
RUN printf '{\n  "auth-key": "chatgpt2api",\n  "refresh_account_interval_minute": 5,\n  "proxy_runtime": {\n    "enabled": true,\n    "egress_mode": "single_proxy",\n    "proxy_url": "socks5h://127.0.0.1:1080",\n    "resource_proxy_url": "",\n    "skip_ssl_verify": false,\n    "reset_session_status_codes": [403],\n    "clearance": {\n      "enabled": true,\n      "mode": "flaresolverr",\n      "cf_cookies": "",\n      "cf_clearance": "",\n      "user_agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36",\n      "browser": "chrome",\n      "flaresolverr_url": "http://127.0.0.1:8191",\n      "timeout_sec": 60,\n      "refresh_interval": 3600,\n      "warm_up_on_start": false\n    }\n  }\n}\n' > config.json
COPY api ./api
COPY services ./services
COPY utils ./utils
COPY scripts ./scripts
COPY --from=web-build /app/web/out ./web_dist

COPY entrypoint.sh ./
RUN chmod +x entrypoint.sh

EXPOSE 7860

ENTRYPOINT ["./entrypoint.sh"]
