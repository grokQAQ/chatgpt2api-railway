#!/bin/bash
set -e

echo "[entrypoint] === chatgpt2api (Railway/Render) ==="

# 1. 启动 xray 代理（通过订阅链接）
XRAY_STARTED=false
if [ -n "$PROXY_SUB_URL" ]; then
    echo "[entrypoint] Fetching proxy subscription..."
    if python3 /app/scripts/fetch_sub.py; then
        echo "[entrypoint] Starting xray proxy on 127.0.0.1:1080..."
        xray run -c /app/xray-config.json &
        XRAY_PID=$!
        sleep 3
        if kill -0 $XRAY_PID 2>/dev/null; then
            echo "[entrypoint] Xray proxy is running"
            XRAY_STARTED=true
            # 确保 config.json 指向本地 xray
            python3 -c "
import json
with open('/app/config.json','r') as f: cfg=json.load(f)
cfg['proxy_runtime']['enabled'] = True
cfg['proxy_runtime']['egress_mode'] = 'single_proxy'
cfg['proxy_runtime']['proxy_url'] = 'socks5://127.0.0.1:1080'
with open('/app/config.json','w') as f: json.dump(cfg,f,indent=2)
"
        else
            echo "[entrypoint] WARNING: Xray failed to start"
        fi
    else
        echo "[entrypoint] WARNING: Subscription fetch failed"
    fi
fi

# 2. 如果没有 xray，检查是否有 PROXY_URL 环境变量（直接指定代理地址）
if [ "$XRAY_STARTED" = false ] && [ -n "$PROXY_URL" ]; then
    echo "[entrypoint] Using PROXY_URL environment variable: ${PROXY_URL%%@*}@***"
    python3 -c "
import json, os
with open('/app/config.json','r') as f: cfg=json.load(f)
cfg['proxy_runtime']['enabled'] = True
cfg['proxy_runtime']['egress_mode'] = 'single_proxy'
cfg['proxy_runtime']['proxy_url'] = os.environ['PROXY_URL']
with open('/app/config.json','w') as f: json.dump(cfg,f,indent=2)
"
fi

# 3. 如果既没有 xray 也没有 PROXY_URL，检查 config.json 中是否已有代理配置
if [ "$XRAY_STARTED" = false ] && [ -z "$PROXY_URL" ]; then
    HAS_PROXY=$(python3 -c "
import json
with open('/app/config.json','r') as f: cfg=json.load(f)
proxy_url = cfg.get('proxy_runtime',{}).get('proxy_url','')
egress = cfg.get('proxy_runtime',{}).get('egress_mode','direct')
print('yes' if proxy_url and egress != 'direct' else 'no')
")
    if [ "$HAS_PROXY" = "yes" ]; then
        echo "[entrypoint] Using proxy from config.json"
    else
        echo "[entrypoint] WARNING: No proxy configured! FlareSolverr will use direct connection."
        echo "[entrypoint] Cloudflare will likely block requests from Railway IP."
        echo "[entrypoint] Set PROXY_SUB_URL or PROXY_URL environment variable to fix this."
    fi
fi

# 4. 启动 FlareSolverr
# HOST=127.0.0.1 绑定本地，避免 Railway 把流量路由到 FlareSolverr
# PORT=8191 明确指定，避免读到 Railway 的 PORT=10000
# HEADLESS=true 表示使用 Xvfb 虚拟显示（head-full 模式，避免被 Cloudflare 检测）
echo "[entrypoint] Starting FlareSolverr on 127.0.0.1:8191..."
cd /opt/flaresolverr
PYTHONPATH=/opt/flaresolverr/src:$PYTHONPATH \
LOG_LEVEL=${LOG_LEVEL:-info} \
HEADLESS=true \
HOST=127.0.0.1 \
PORT=8191 \
python -m src.flaresolverr > /tmp/flaresolverr.log 2>&1 &
FLARE_PID=$!
cd /app

# 等待 FlareSolverr 就绪（最多 90 秒，首次启动需要下载 chromedriver）
echo "[entrypoint] Waiting for FlareSolverr..."
for i in $(seq 1 90); do
    if curl -s http://127.0.0.1:8191/ > /dev/null 2>&1; then
        echo "[entrypoint] FlareSolverr is ready! (took ${i}s)"
        break
    fi
    if ! kill -0 $FLARE_PID 2>/dev/null; then
        echo "[entrypoint] WARNING: FlareSolverr died, checking log..."
        tail -30 /tmp/flaresolverr.log >&2 2>/dev/null
        break
    fi
    if [ $((i % 15)) -eq 0 ]; then
        echo "[entrypoint] Still waiting for FlareSolverr... (${i}s)"
    fi
    sleep 1
done

# 5. 打印当前代理配置摘要
python3 -c "
import json
with open('/app/config.json','r') as f: cfg=json.load(f)
rt = cfg.get('proxy_runtime', {})
cl = rt.get('clearance', {})
print(f'[entrypoint] Proxy config: enabled={rt.get(\"enabled\")}, mode={rt.get(\"egress_mode\")}, proxy_url={rt.get(\"proxy_url\",\"\")[:30]}...')
print(f'[entrypoint] Clearance config: mode={cl.get(\"mode\")}, flaresolverr_url={cl.get(\"flaresolverr_url\",\"\")}, timeout={cl.get(\"timeout_sec\",60)}s')
"

# 6. 启动主应用
PORT=${PORT:-10000}
echo "[entrypoint] Starting chatgpt2api on port $PORT..."
exec uv run uvicorn main:app --host 0.0.0.0 --port $PORT --access-log
