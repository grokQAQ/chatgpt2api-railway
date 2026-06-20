#!/bin/bash
# chatgpt2api HF Space 版 entrypoint：直连模式 + FlareSolverr
# HF Space IP 信誉高，直连能过 Cloudflare，不需要代理

echo "[entrypoint] === chatgpt2api (HF Space) ===" >&2

# 1. 直连模式（HF IP 能过 Cloudflare，不需要代理）
echo "[entrypoint] Using direct mode (HF IP trusted by Cloudflare)" >&2
export CHATGPT2API_PROXY_RUNTIME_EGRESS_MODE="direct"
export CHATGPT2API_PROXY_RUNTIME_PROXY_URL=""
export CHATGPT2API_PROXY_RUNTIME_ENABLED="true"

# 2. 使用 init_proxy_config.py 生成 proxy_runtime 配置
export CHATGPT2API_PROXY_RUNTIME_CLEARANCE_ENABLED="${CHATGPT2API_PROXY_RUNTIME_CLEARANCE_ENABLED:-true}"
export CHATGPT2API_PROXY_RUNTIME_CLEARANCE_MODE="${CHATGPT2API_PROXY_RUNTIME_CLEARANCE_MODE:-flaresolverr}"
export CHATGPT2API_FLARESOLVERR_URL="${CHATGPT2API_FLARESOLVERR_URL:-http://127.0.0.1:8191}"
export CHATGPT2API_PROXY_RUNTIME_FORCE="${CHATGPT2API_PROXY_RUNTIME_FORCE:-true}"

echo "[entrypoint] Running init_proxy_config.py..." >&2
python3 /app/scripts/init_proxy_config.py 2>&2

# 3. 启动 FlareSolverr（Chromium headless 模式，直连不走代理）
echo "[entrypoint] Starting FlareSolverr on port 8191..." >&2
cd /opt/flaresolverr
DISPLAY= PYTHONPATH=/opt/flaresolverr/src:$PYTHONPATH \
LOG_LEVEL=${FLARESOLVERR_LOG_LEVEL:-info} \
CHROME_EXE_PATH=$(which chromium) \
python -m src.flaresolverr > /tmp/flaresolverr.log 2>&1 &
FLARE_PID=$!
cd /app

# 等待 FlareSolverr 就绪（最多 30 秒）
echo "[entrypoint] Waiting for FlareSolverr..." >&2
for i in $(seq 1 30); do
    if curl -s http://127.0.0.1:8191/ >/dev/null 2>&1; then
        echo "[entrypoint] FlareSolverr is ready!" >&2
        break
    fi
    if ! kill -0 $FLARE_PID 2>/dev/null; then
        echo "[entrypoint] WARNING: FlareSolverr died, checking log..." >&2
        tail -20 /tmp/flaresolverr.log >&2 2>/dev/null
        break
    fi
    sleep 1
done

# 4. 启动主应用（HF Space 端口 7860）
PORT=${PORT:-7860}
echo "[entrypoint] Starting chatgpt2api on port $PORT..." >&2
exec uv run uvicorn main:app --host 0.0.0.0 --port $PORT --access-log
