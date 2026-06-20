#!/bin/bash
set -e

# 启动 Xvfb 虚拟显示（FlareSolverr 的 Chromium 需要）
Xvfb :99 -screen 0 1280x720x24 &
sleep 1

# 启动 FlareSolverr 后台服务
echo "[entrypoint] Starting FlareSolverr on port 8191..."
cd /opt/flaresolverr
LOG_LEVEL=${LOG_LEVEL:-info} python -m src.flaresolverr &
FLARE_PID=$!
cd /app

# 等待 FlareSolverr 就绪（最多 30 秒）
echo "[entrypoint] Waiting for FlareSolverr to be ready..."
for i in $(seq 1 30); do
    if curl -s http://127.0.0.1:8191/ > /dev/null 2>&1; then
        echo "[entrypoint] FlareSolverr is ready!"
        break
    fi
    if ! kill -0 $FLARE_PID 2>/dev/null; then
        echo "[entrypoint] WARNING: FlareSolverr process died, continuing without it"
        break
    fi
    sleep 1
done

# 启动主应用
echo "[entrypoint] Starting chatgpt2api on port 7860..."
exec uv run uvicorn main:app --host 0.0.0.0 --port 7860 --access-log
