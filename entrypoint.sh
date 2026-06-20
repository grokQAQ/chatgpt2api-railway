#!/bin/bash
set -e

echo "[entrypoint] === chatgpt2api HF Space ==="

# 1. 启动 Xvfb 虚拟显示（FlareSolverr 的 Chromium 需要）
echo "[entrypoint] Starting Xvfb..."
Xvfb :99 -screen 0 1280x720x24 &
sleep 1

# 2. 启动 xray 代理（如果设置了 PROXY_SUB_URL）
if [ -n "$PROXY_SUB_URL" ]; then
    echo "[entrypoint] Fetching proxy subscription..."
    if python3 /app/scripts/fetch_sub.py; then
        echo "[entrypoint] Starting xray proxy on 127.0.0.1:1080..."
        xray run -c /app/xray-config.json &
        XRAY_PID=$!
        # 等待 xray 就绪
        sleep 2
        if kill -0 $XRAY_PID 2>/dev/null; then
            echo "[entrypoint] Xray proxy is running"
        else
            echo "[entrypoint] WARNING: Xray failed to start, falling back to direct"
            # 回退到直连模式：更新 config.json
            python3 -c "
import json
with open('/app/config.json', 'r') as f:
    cfg = json.load(f)
cfg['proxy_runtime']['egress_mode'] = 'direct'
cfg['proxy_runtime']['proxy_url'] = ''
with open('/app/config.json', 'w') as f:
    json.dump(cfg, f, indent=2)
print('  Fallback: proxy_runtime set to direct mode')
"
        fi
    else
        echo "[entrypoint] WARNING: Failed to fetch subscription, falling back to direct"
        python3 -c "
import json
with open('/app/config.json', 'r') as f:
    cfg = json.load(f)
cfg['proxy_runtime']['egress_mode'] = 'direct'
cfg['proxy_runtime']['proxy_url'] = ''
with open('/app/config.json', 'w') as f:
    json.dump(cfg, f, indent=2)
print('  Fallback: proxy_runtime set to direct mode')
"
    fi
else
    echo "[entrypoint] No PROXY_SUB_URL set, using direct mode"
    python3 -c "
import json
with open('/app/config.json', 'r') as f:
    cfg = json.load(f)
cfg['proxy_runtime']['egress_mode'] = 'direct'
cfg['proxy_runtime']['proxy_url'] = ''
with open('/app/config.json', 'w') as f:
    json.dump(cfg, f, indent=2)
print('  proxy_runtime set to direct mode')
"
fi

# 3. 启动 FlareSolverr 后台服务
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

# 4. 启动主应用
echo "[entrypoint] Starting chatgpt2api on port 7860..."
exec uv run uvicorn main:app --host 0.0.0.0 --port 7860 --access-log
