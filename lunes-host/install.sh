#!/usr/bin/env sh
set -eu

# ---------------------------
# 配置变量（可通过环境变量覆盖）
# ---------------------------
WORKDIR="${WORKDIR:-/home/container}"
DOMAIN="${DOMAIN:-node68.lunes.host}"   # 容器外部域名
PORT="${PORT:-10008}"                   # 容器外部端口
UUID="${UUID:-2584b733-2b32-4036-8e26-df7b984f7f9e}"
HY2_PASSWORD="${HY2_PASSWORD:-vevc.HY2.Password}"
WS_PATH="${WS_PATH:-/wspath}"

mkdir -p "$WORKDIR"
cd "$WORKDIR"

# ---------------------------
# 下载 app.js 和 package.json
# ---------------------------
echo "[node] downloading app.js and package.json ..."
curl -sSL -o "$WORKDIR/app.js" https://raw.githubusercontent.com/DengekiBunko/vls/refs/heads/main/lunes-host/app.js || true
curl -sSL -o "$WORKDIR/package.json" https://raw.githubusercontent.com/DengekiBunko/vls/refs/heads/main/lunes-host/package.json || true

# ---------------------------
# Xray (VLESS WS+TLS) 安装
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
# Hysteria2 安装（直连）
# ---------------------------
mkdir -p "$WORKDIR/h2"
cd "$WORKDIR/h2"
echo "[h2] downloading..."
curl -sSL -o h2 "https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.2/hysteria-linux-amd64" || true
curl -sSL -o config.yaml "https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/hysteria-config.yaml" || true
chmod +x h2 || true
sed -i "s/10008/$PORT/g" config.yaml || true
sed -i "s/HY2_PASSWORD/$HY2_PASSWORD/g" config.yaml || true

# ---------------------------
# Cloudflared: 下载 & login
# ---------------------------
CLOUDFLARED_BIN="$WORKDIR/cloudflared"
CLOUDFLARED_DIR="$WORKDIR/.cloudflared"
mkdir -p "$CLOUDFLARED_DIR"

if [ ! -x "$CLOUDFLARED_BIN" ]; then
  echo "[cloudflared] downloading..."
  curl -fsSL -o "$CLOUDFLARED_BIN" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
  chmod +x "$CLOUDFLARED_BIN"
fi

echo "-------- Cloudflared interactive login --------"
set +e
"$CLOUDFLARED_BIN" login || true
set -e

# ---------------------------
# 启动临时隧道并捕获临时域名
# ---------------------------
TMP_LOG="$WORKDIR/cloudflared-tmp.log"
rm -f "$TMP_LOG"
nohup "$CLOUDFLARED_BIN" tunnel --url "http://127.0.0.1:$PORT" run > "$TMP_LOG" 2>&1 &
sleep 5

# 尝试从日志中获取临时域名
TUNNEL_HOST=$(grep -oE '[a-z0-9-]+\.trycloudflare\.com' "$TMP_LOG" | head -1 || true)
[ -z "$TUNNEL_HOST" ] && TUNNEL_HOST="$DOMAIN"

# ---------------------------
# 生成节点链接
# ---------------------------
ENC_PATH=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$WS_PATH")
ENC_PWD=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$HY2_PASSWORD")

VLESS_URL="vless://${UUID}@${TUNNEL_HOST}:443?encryption=none&security=tls&type=ws&host=${TUNNEL_HOST}&path=${ENC_PATH}&sni=${TUNNEL_HOST}#lunes-ws-tls"
HY2_URL="hysteria2://${ENC_PWD}@${DOMAIN}:${PORT}?insecure=1#lunes-hy2"

echo "$VLESS_URL" > "$WORKDIR/node.txt"
echo "$HY2_URL" >> "$WORKDIR/node.txt"

echo "============================================================"
echo "🚀 VLESS WS (via cloudflared) & HY2 (direct) Node Info"
echo "$VLESS_URL"
echo "$HY2_URL"
echo "============================================================"
echo "✅ install.sh finished. You can start the server with: node $WORKDIR/app.js"
