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
mkdir -p /home/container/h2
cd /home/container/h2
curl -sSL -o h2 https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.2/hysteria-linux-amd64
curl -sSL -o config.yaml https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/hysteria-config.yaml
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout key.pem -out cert.pem -subj "/CN=$DOMAIN"
chmod +x h2
sed -i "s/10008/$PORT/g" config.yaml
sed -i "s/HY2_PASSWORD/$HY2_PASSWORD/g" config.yaml
# 注意：此处的 hy2Url 是用于写入 node.txt 的，使用 $PORT，保持不变
encodedHy2Pwd=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$HY2_PASSWORD")
hy2Url="hysteria2://$encodedHy2Pwd@$DOMAIN:$PORT?insecure=1#lunes-hy2"
echo $hy2Url >> /home/container/node.txt

# ---------------------------
# Cloudflare Tunnel 交互式登录 + tunnel 创建
# ---------------------------
CLOUDFLARED_BIN="$WORKDIR/cloudflared"
CLOUDFLARED_DIR="$WORKDIR/.cloudflared"
mkdir -p "$CLOUDFLARED_DIR"

if [ ! -x "$CLOUDFLARED_BIN" ]; then
    echo "[cloudflared] downloading cloudflared ..."
    curl -fsSL -o "$CLOUDFLARED_BIN" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
    chmod +x "$CLOUDFLARED_BIN"
fi

echo "-------- Cloudflared interactive login --------"
set +e
"$CLOUDFLARED_BIN" login
set -e

WAIT=0 MAX=300 SLEEP=5 CERT=""
while [ $WAIT -lt $MAX ]; do
    if [ -f "$CLOUDFLARED_DIR/cert.pem" ]; then
        CERT="$CLOUDFLARED_DIR/cert.pem"
        break
    fi
    echo "[cloudflared] waiting for cert.pem $WAIT/$MAX"
    sleep $SLEEP
    WAIT=$((WAIT + SLEEP))
done

if [ -z "$CERT" ]; then
    echo "[cloudflared] cert.pem not found. 请放置 cert.pem 到 $CLOUDFLARED_DIR 或手动 login"
else
    echo "[cloudflared] found cert.pem, creating tunnel ..."
    set +e
    "$CLOUDFLARED_BIN" tunnel create "$TUNNEL_NAME" --credentials-file "$CLOUDFLARED_DIR/$TUNNEL_NAME.json" 2>&1 || true
    "$CLOUDFLARED_BIN" tunnel route dns "$TUNNEL_NAME" "$DOMAIN" 2>&1 || true
    set -e
    echo "[cloudflared] initialization done."
fi

# ---------------------------
# 构建 VLESS 和 HY2 链接
# ---------------------------
ENC_PATH=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$WS_PATH")
ENC_PWD=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$HY2_PASSWORD")

# VLESS-WS 使用 443 端口 (Cloudflare Tunnel)
VLESS_URL="vless://$UUID@$DOMAIN:443?encryption=none&security=tls&type=ws&host=$DOMAIN&path=${ENC_PATH}&sni=$DOMAIN#lunes-ws-tls"

# HY2 使用 $PORT 端口 (直连)
HY2_URL="hysteria2://$ENC_PWD@$DOMAIN:$PORT?insecure=1#lunes-hy2"

echo "$VLESS_URL" > "$WORKDIR/node.txt"
echo "$HY2_URL" >> "$WORKDIR/node.txt"

# ---------------------------
# 输出信息
# ---------------------------
echo "============================================================"
echo "🚀 VLESS WS+TLS & HY2 Node Info"
echo "--- VLESS (Cloudflare Tunnel 443) ---"
echo "$VLESS_URL"
echo "--- HY2 (Direct Connection $PORT) ---"
echo "$HY2_URL"
echo "============================================================"
echo "✅ install.sh finished. You can start the server with: node $WORKDIR/app.js"
