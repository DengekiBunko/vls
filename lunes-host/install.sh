#!/usr/bin/env sh
set -eu

# ---------------------------
# 配置变量
# ---------------------------
DOMAIN="${DOMAIN:-node68.lunes.host}"
PORT="${PORT:-10008}"
UUID="${UUID:-2584b733-2b32-4036-8e26-df7b984f7f9e}"
HY2_PASSWORD="${HY2_PASSWORD:-vevc.HY2.Password}"
WS_PATH="${WS_PATH:-/wspath}"
TUNNEL_NAME="${TUNNEL_NAME:-mytunnel}"
WORKDIR="${WORKDIR:-/home/container}"

# ---------------------------
# 下载 app.js 和 package.json
# ---------------------------
echo "[node] downloading app.js and package.json ..."
curl -sSL -o "$WORKDIR/app.js" https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/app.js
curl -sSL -o "$WORKDIR/package.json" https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/package.json

# ---------------------------
# Xray (xy) VLESS+WS+TLS 配置
# ---------------------------
mkdir -p "$WORKDIR/xy"
cd "$WORKDIR/xy"
curl -sSL -o Xray-linux-64.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
if command -v unzip >/dev/null 2>&1; then
    unzip -o Xray-linux-64.zip >/dev/null 2>&1 || true
fi
rm -f Xray-linux-64.zip
[ -f xray ] && mv -f xray xy || true
[ -f Xray ] && mv -f Xray xy || true
chmod +x xy
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout key.pem -out cert.pem -subj "/CN=$DOMAIN"
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
# Hysteria2 (h2) 配置
# ---------------------------
mkdir -p "$WORKDIR/h2"
cd "$WORKDIR/h2"
curl -sSL -o h2 https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.2/hysteria-linux-amd64
curl -sSL -o config.yaml https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/hysteria-config.yaml
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout key.pem -out cert.pem -subj "/CN=$DOMAIN"
chmod +x h2
sed -i "s/10008/$PORT/g" config.yaml
sed -i "s/HY2_PASSWORD/$HY2_PASSWORD/g" config.yaml
encodedHy2Pwd=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$HY2_PASSWORD")
hy2Url="hysteria2://$encodedHy2Pwd@$DOMAIN:$PORT?insecure=1#lunes-hy2"

# ---------------------------
# Cloudflare Tunnel 临时隧道
# ---------------------------
CLOUDFLARED_BIN="$WORKDIR/cloudflared"
CLOUDFLARED_DIR="$WORKDIR/.cloudflared"
mkdir -p "$CLOUDFLARED_DIR"

if [ ! -x "$CLOUDFLARED_BIN" ]; then
    echo "[cloudflared] downloading cloudflared ..."
    curl -fsSL -o "$CLOUDFLARED_BIN" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
    chmod +x "$CLOUDFLARED_BIN"
fi

# 启动临时隧道并抓取生成的 trycloudflare 域名
TEMP_DOMAIN=""
echo "[cloudflared] starting temporary tunnel..."
(
  "$CLOUDFLARED_BIN" tunnel --url "http://127.0.0.1:$PORT" 2>&1 &
) | while IFS= read -r line; do
  echo "$line"
  # 捕获临时域名
  if echo "$line" | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' >/dev/null; then
    TEMP_DOMAIN=$(echo "$line" | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | head -n1 | sed 's|https://||')
    break
  fi
done

if [ -z "$TEMP_DOMAIN" ]; then
  echo "[cloudflared] failed to detect temporary tunnel domain. Defaulting to localhost."
  TEMP_DOMAIN="localhost"
fi

echo "[cloudflared] temporary tunnel domain: $TEMP_DOMAIN"

# ---------------------------
# 构建节点信息
# ---------------------------
ENC_PATH=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$WS_PATH")
ENC_PWD=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$HY2_PASSWORD")
VLESS_URL="vless://$UUID@$TEMP_DOMAIN:443?encryption=none&security=tls&type=ws&host=$TEMP_DOMAIN&path=${ENC_PATH}&sni=$TEMP_DOMAIN#lunes-ws-tls"
HY2_URL="hysteria2://$ENC_PWD@$DOMAIN:$PORT?insecure=1#lunes-hy2"

echo "$VLESS_URL" > "$WORKDIR/node.txt"
echo "$HY2_URL" >> "$WORKDIR/node.txt"

# ---------------------------
# 输出信息
# ---------------------------
echo "============================================================"
echo "🚀 VLESS WS+TLS & HY2 Node Info"
echo "$VLESS_URL"
echo "$HY2_URL"
echo "============================================================"
echo "✅ install.sh finished. You can start the server with: node $WORKDIR/app.js"
