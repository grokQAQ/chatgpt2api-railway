#!/bin/bash
set -e

echo "[entrypoint] === chatgpt2api Register Bot (Render) ==="

# 1. 启动 Xvfb（Chromium 需要）
echo "[entrypoint] Starting Xvfb..."
Xvfb :99 -screen 0 1024x768x16 &
sleep 1

# 2. 启动 xray 代理
if [ -n "$PROXY_SUB_URL" ]; then
    echo "[entrypoint] Fetching proxy subscription..."
    if python3 /app/scripts/fetch_sub.py; then
        echo "[entrypoint] Starting xray proxy on 127.0.0.1:1080..."
        xray run -c /app/xray-config.json &
        XRAY_PID=$!
        sleep 2
        if kill -0 $XRAY_PID 2>/dev/null; then
            echo "[entrypoint] Xray proxy is running"
        else
            echo "[entrypoint] WARNING: Xray failed, falling back to direct"
            python3 -c "
import json
with open('/app/config.json','r') as f: cfg=json.load(f)
cfg['proxy_runtime']['egress_mode']='direct'
cfg['proxy_runtime']['proxy_url']=''
with open('/app/config.json','w') as f: json.dump(cfg,f,indent=2)
"
        fi
    else
        echo "[entrypoint] WARNING: Subscription fetch failed, using direct"
        python3 -c "
import json
with open('/app/config.json','r') as f: cfg=json.load(f)
cfg['proxy_runtime']['egress_mode']='direct'
cfg['proxy_runtime']['proxy_url']=''
with open('/app/config.json','w') as f: json.dump(cfg,f,indent=2)
"
    fi
else
    echo "[entrypoint] No PROXY_SUB_URL, using direct mode"
    python3 -c "
import json
with open('/app/config.json','r') as f: cfg=json.load(f)
cfg['proxy_runtime']['egress_mode']='direct'
cfg['proxy_runtime']['proxy_url']=''
with open('/app/config.json','w') as f: json.dump(cfg,f,indent=2)
"
fi

# 3. 启动 FlareSolverr
echo "[entrypoint] Starting FlareSolverr on port 8191..."
cd /opt/flaresolverr
PYTHONPATH=/opt/flaresolverr/src:$PYTHONPATH \
LOG_LEVEL=${LOG_LEVEL:-warning} \
CHROME_EXE_PATH=$(which chromium) \
python -m src.flaresolverr &
FLARE_PID=$!
cd /app

# 等待 FlareSolverr 就绪（最多 30 秒）
echo "[entrypoint] Waiting for FlareSolverr..."
for i in $(seq 1 30); do
    if curl -s http://127.0.0.1:8191/ > /dev/null 2>&1; then
        echo "[entrypoint] FlareSolverr is ready!"
        break
    fi
    if ! kill -0 $FLARE_PID 2>/dev/null; then
        echo "[entrypoint] WARNING: FlareSolverr died, continuing without it"
        break
    fi
    sleep 1
done

# 4. 启动主应用（Render 默认端口 10000）
PORT=${PORT:-10000}
echo "[entrypoint] Starting chatgpt2api on port $PORT..."
exec uv run uvicorn main:app --host 0.0.0.0 --port $PORT --access-log
