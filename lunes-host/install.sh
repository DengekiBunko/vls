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
# Xray (xy) VLESS+WS+TLS 配置
# ---------------------------
mkdir -p "$WORKDIR/xy"
cd "$WORKDIR/xy"

# 下载 Xray
curl -sSL -o Xray-linux-64.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
unzip -o Xray-linux-64.zip >/dev/null 2>&1 || true
rm -f Xray-linux-64.zip
[ -f xray ] && mv -f xray xy || true
[ -f Xray ] && mv -f Xray xy || true
chmod +x xy

# 生成自签 TLS
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout key.pem -out cert.pem -subj "/CN=$DOMAIN"

# 生成 config.json
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

# 下载 cloudflared
if [ ! -x "$CLOUDFLARED_BIN" ]; then
    curl -fsSL -o "$CLOUDFLARED_BIN" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
    chmod +x "$CLOUDFLARED_BIN"
fi

echo "-------- Cloudflared interactive login --------"
set +e
"$CLOUDFLARED_BIN" login
set -e

# 等待 cert.pem
WAIT=0 MAX=300 SLEEP=5
while [ $WAIT -lt $MAX ]; do
    if [ -f "$CLOUDFLARED_DIR/cert.pem" ]; then
        break
    fi
    echo "[cloudflared] waiting for cert.pem $WAIT/$MAX"
    sleep $SLEEP
    WAIT=$((WAIT + SLEEP))
done

# 创建临时隧道并获取域名
TEMP_TUNNEL_DOMAIN=$("$CLOUDFLARED_BIN" tunnel --url "http://localhost:$PORT" 2>&1 | grep -oE 'https://[a-z0-9.-]+\.trycloudflare\.com' | head -n1)
if [ -z "$TEMP_TUNNEL_DOMAIN" ]; then
    echo "[cloudflared] 临时隧道创建失败，请网页认证后重试"
    TEMP_TUNNEL_DOMAIN="localhost"
fi

# ---------------------------
# 输出节点信息
# ---------------------------
ENC_PATH=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$WS_PATH")
ENC_PWD=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$HY2_PASSWORD")

VLESS_URL="vless://$UUID@$TEMP_TUNNEL_DOMAIN:443?encryption=none&security=tls&type=ws&host=$TEMP_TUNNEL_DOMAIN&path=${ENC_PATH}&sni=$TEMP_TUNNEL_DOMAIN#lunes-ws-tls"
HY2_URL="hysteria2://$ENC_PWD@$DOMAIN:$PORT?insecure=1#lunes-hy2"

echo "$VLESS_URL" > "$WORKDIR/node.txt"
echo "$HY2_URL" >> "$WORKDIR/node.txt"

echo "============================================================"
echo "🚀 VLESS WS+TLS & HY2 Node Info"
echo "$VLESS_URL"
echo "$HY2_URL"
echo "============================================================"
echo "✅ install.sh finished. You can start the server with: node $WORKDIR/app.js"
