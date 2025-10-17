#!/usr/bin/env sh
set -eu

# ---------------------------
# 配置变量（可通过环境变量覆盖）
# ---------------------------
WORKDIR="${WORKDIR:-/home/container}"
DOMAIN="${DOMAIN:-$(hostname -f)}"   # 传入的容器域名/面板分配域名
PORT="${PORT:-10008}"                # 传入的外部端口映射
UUID="${UUID:-2584b733-2b32-4036-8e26-df7b984f7f9e}"
HY2_PASSWORD="${HY2_PASSWORD:-vevc.HY2.Password}"
WS_PATH="${WS_PATH:-/wspath}"

mkdir -p "$WORKDIR"
cd "$WORKDIR"

echo "[node] downloading app.js and package.json ..."
curl -sSL -o "$WORKDIR/app.js" https://raw.githubusercontent.com/DengekiBunko/vls/refs/heads/main/lunes-host/app.js || true
curl -sSL -o "$WORKDIR/package.json" https://raw.githubusercontent.com/DengekiBunko/vls/refs/heads/main/lunes-host/package.json || true

# ---------------------------
# Xray (VLESS WS+TLS) 安装与配置
# ---------------------------
mkdir -p "$WORKDIR/xy"
cd "$WORKDIR/xy"
echo "[Xray] downloading..."
curl -sSL -o Xray-linux-64.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip" || true
if command -v unzip >/dev/null 2>&1; then
  unzip -o Xray-linux-64.zip >/dev/null 2>&1 || true
fi
rm -f Xray-linux-64.zip
[ -f xray ] && mv -f xray xy || true
[ -f Xray ] && mv -f Xray xy || true
chmod +x xy || true

# 生成自签证书（用于 origin TLS，cloudflared 会做 edge TLS）
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout key.pem -out cert.pem -subj "/CN=$DOMAIN" >/dev/null 2>&1 || true

cat > config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": { "clients": [{ "id": "$UUID", "email": "lunes-ws-tls" }], "decryption": "none" },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": { "certificates": [{ "certificateFile": "$WORKDIR/xy/cert.pem", "keyFile": "$WORKDIR/xy/key.pem" }] },
        "wsSettings": { "path": "$WS_PATH" }
      }
    }
  ],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

# ---------------------------
# Hysteria2 安装与配置（直连）
# ---------------------------
mkdir -p "$WORKDIR/h2"
cd "$WORKDIR/h2"
echo "[h2] downloading..."
curl -sSL -o h2 "https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.2/hysteria-linux-amd64" || true
curl -sSL -o config.yaml "https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/hysteria-config.yaml" || true
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout key.pem -out cert.pem -subj "/CN=$DOMAIN" >/dev/null 2>&1 || true
chmod +x h2 || true
# 替换默认端口与密码（若 config.yaml 存在）
if [ -f config.yaml ]; then
  sed -i "s/10008/$PORT/g" config.yaml || true
  sed -i "s/HY2_PASSWORD/$HY2_PASSWORD/g" config.yaml || true
fi

# prepare hysteria url (direct)
ENC_PWD="$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$HY2_PASSWORD")"
HY2_URL="hysteria2://${ENC_PWD}@${DOMAIN}:${PORT}?insecure=1#lunes-hy2"

# ---------------------------
# Cloudflared: 下载 & (交互式) login
# ---------------------------
CLOUDFLARED_BIN="$WORKDIR/cloudflared"
CLOUDFLARED_DIR="$WORKDIR/.cloudflared"
mkdir -p "$CLOUDFLARED_DIR"

if [ ! -x "$CLOUDFLARED_BIN" ]; then
  echo "[cloudflared] downloading cloudflared..."
  curl -fsSL -o "$CLOUDFLARED_BIN" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" || true
  chmod +x "$CLOUDFLARED_BIN" || true
fi

echo "-------- Cloudflared interactive login (if required) --------"
# 交互认证：如果环境可以交互，会在终端打开 URL；如果非交互，会提示手动上载 cert.pem
set +e
"$CLOUDFLARED_BIN" login || true
set -e

# 等待 cert.pem（最多等待 120 秒）
WAIT=0
MAX_WAIT=120
SLEEP=1
CERT=""
while [ $WAIT -lt $MAX_WAIT ]; do
  if [ -f "$CLOUDFLARED_DIR/cert.pem" ]; then
    CERT="$CLOUDFLARED_DIR/cert.pem"
    break
  fi
  echo "[cloudflared] waiting for cert.pem ($WAIT/$MAX_WAIT)..."
  sleep $SLEEP
  WAIT=$((WAIT + SLEEP))
done

# ---------------------------
# 启动 Cloudflared 临时隧道并捕获临时域名
# ---------------------------
TMP_LOG="$WORKDIR/cloudflared-tmp.log"
TUNNEL_DOMAIN=""

if [ -n "$CERT" ]; then
  echo "[cloudflared] cert.pem found, starting temporary tunnel (background)..."
  # 启动临时隧道并把输出写入临时日志
  # Use nohup so it survives interactive shell exit; keep process in background
  nohup "$CLOUDFLARED_BIN" tunnel --url "http://127.0.0.1:$PORT" run > "$TMP_LOG" 2>&1 &
  # give it a few seconds and try to extract domain
  for i in $(seq 1 30); do
    sleep 1
    TUNNEL_DOMAIN=$(grep -oE 'https?://[a-z0-9.-]+\.trycloudflare\.com' "$TMP_LOG" | head -1 || true)
    # sometimes cloudflared prints domain without https, try generic domain patterns
    if [ -z "$TUNNEL_DOMAIN" ]; then
      TUNNEL_DOMAIN=$(grep -oE '[a-z0-9-]+\.trycloudflare\.com' "$TMP_LOG" | head -1 || true)
      if [ -n "$TUNNEL_DOMAIN" ]; then
        TUNNEL_DOMAIN="https://$TUNNEL_DOMAIN"
      fi
    fi
    # also try cfargotunnel fallback
    if [ -z "$TUNNEL_DOMAIN" ]; then
      TUNNEL_DOMAIN=$(grep -oE 'https?://[a-z0-9.-]+\.cfargotunnel\.com' "$TMP_LOG" | head -1 || true)
      if [ -z "$TUNNEL_DOMAIN" ]; then
        TUNNEL_DOMAIN=$(grep -oE '[a-z0-9-]+\.cfargotunnel\.com' "$TMP_LOG" | head -1 || true)
        [ -n "$TUNNEL_DOMAIN" ] && TUNNEL_DOMAIN="https://$TUNNEL_DOMAIN"
      fi
    fi
    [ -n "$TUNNEL_DOMAIN" ] && break
  done

  if [ -z "$TUNNEL_DOMAIN" ]; then
    echo "[cloudflared] warning: could not extract trycloudflare domain from log; check $TMP_LOG"
    TUNNEL_DOMAIN="$DOMAIN"
  fi
else
  echo "[cloudflared] cert.pem not found; skipping automatic tunnel start. You must provide cert.pem to $CLOUDFLARED_DIR or run cloudflared login interactively."
  TUNNEL_DOMAIN="$DOMAIN"
fi

# Normalize TUNNEL_DOMAIN to host only (no https://)
TUNNEL_HOST="$(echo "$TUNNEL_DOMAIN" | sed -E 's~https?://~~; s~/$~~')"

# ---------------------------
# 生成并写入 node.txt（VLESS 使用临时隧道:443; HY2 直连容器端口）
# ---------------------------
ENC_PATH="$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$WS_PATH")"
ENC_PWD="$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$HY2_PASSWORD")"

VLESS_URL="vless://${UUID}@${TUNNEL_HOST}:443?encryption=none&security=tls&type=ws&host=${TUNNEL_HOST}&path=${ENC_PATH}&sni=${TUNNEL_HOST}#lunes-ws-tls"
HY2_URL="hysteria2://${ENC_PWD}@${DOMAIN}:${PORT}?insecure=1#lunes-hy2"

echo "$VLESS_URL" > "$WORKDIR/node.txt"
echo "$HY2_URL" >> "$WORKDIR/node.txt"

# ---------------------------
# 输出信息
# ---------------------------
echo "============================================================"
echo "🚀 VLESS WS+TLS (via Cloudflared temporary tunnel) & HY2 (direct) Node Info"
echo
echo "VLESS (via tunnel, port 443):"
echo "$VLESS_URL"
echo
echo "HY2 (direct to container):"
echo "$HY2_URL"
echo
echo "Temporary tunnel domain (extracted): $TUNNEL_HOST"
echo "Cloudflared log: $TMP_LOG"
echo "============================================================"
echo "✅ install.sh finished. Start server with: node $WORKDIR/app.js"
