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
    CHROMIUM_FLAGS="--headless=new --no-sandbox --disable-gpu --disable-software-rasterizer --disable-dev-shm-usage --js-flags=--max-old-space-size=256"

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        libpq-dev \
        gcc \
        openssl \
        chromium \
        curl \
        unzip \
        && rm -rf /var/lib/apt/lists/*

# 安装 xray-core
RUN ARCH=$(case "$(dpkg --print-architecture)" in \
        amd64) echo "linux-64";; \
        arm64) echo "linux-arm64-v8a";; \
        *) echo "linux-64";; \
    esac) \
    && curl -fsSL "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-${ARCH}.zip" -o /tmp/xray.zip \
    && unzip -o /tmp/xray.zip -d /usr/local/bin xray \
    && chmod +x /usr/local/bin/xray \
    && rm -f /tmp/xray.zip

# 安装 FlareSolverr
RUN pip install --no-cache-dir uv \
    && git clone --depth 1 https://github.com/FlareSolverr/FlareSolverr.git /opt/flaresolverr \
    && cd /opt/flaresolverr \
    && pip install --no-cache-dir -r requirements.txt \
    && rm -rf /root/.cache/pip /opt/flaresolverr/.git

COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

COPY main.py ./
COPY VERSION ./
RUN printf '{}\n' > config.json
COPY api ./api
COPY services ./services
COPY utils ./utils
COPY scripts ./scripts
COPY --from=web-build /app/web/out ./web_dist

COPY entrypoint-hf.sh ./
RUN chmod +x entrypoint-hf.sh

EXPOSE 7860

ENTRYPOINT ["./entrypoint-hf.sh"]
