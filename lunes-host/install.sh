#!/usr/bin/env sh
set -eu

# ---------------------------
# 基础变量
# ---------------------------
DOMAIN="${DOMAIN:-node68.lunes.host}"
PORT="${PORT:-10008}"
UUID="${UUID:-2584b733-2b32-4036-8e26-df7b984f7f9e}"
HY2_PASSWORD="${HY2_PASSWORD:-vevc.HY2.Password}"
WS_PATH="${WS_PATH:-/wspath}"
WORKDIR="${WORKDIR:-/home/container}"

echo "[init] DOMAIN=$DOMAIN PORT=$PORT UUID=$UUID"

# ---------------------------
# 下载 app.js / package.json
# ---------------------------
echo "[node] downloading app.js and package.json ..."
curl -sSL -o "$WORKDIR/app.js" https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/app.js
curl -sSL -o "$WORKDIR/package.json" https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/package.json

# ---------------------------
# 准备 Xray (xy)
# ---------------------------
mkdir -p "$WORKDIR/xy"
cd "$WORKDIR/xy"

curl -sSL -o Xray-linux-64.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
if command -v unzip >/dev/null 2>&1; then unzip -o Xray-linux-64.zip >/dev/null 2>&1 || true; fi
rm -f Xray-linux-64.zip
[ -f xray ] && mv -f xray xy || true
[ -f Xray ] && mv -f Xray xy || true
chmod +x xy

# 先生成本地自签证书
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
  -keyout key.pem -out cert.pem -subj "/CN=$DOMAIN"

# 先写一个“占位配置”，之后再更新域名
cat > config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": $PORT,
    "protocol": "vless",
    "settings": { "clients": [{ "id": "$UUID", "email": "lunes-ws-tls" }], "decryption": "none" },
    "streamSettings": {
      "network": "ws",
      "security": "tls",
      "tlsSettings": { "certificates": [{ "certificateFile": "$WORKDIR/xy/cert.pem", "keyFile": "$WORKDIR/xy/key.pem" }] },
      "wsSettings": { "path": "$WS_PATH" }
    }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

# ---------------------------
# 准备 HY2（直连）
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
HY2_URL="hysteria2://$encodedHy2Pwd@$DOMAIN:$PORT?insecure=1#lunes-hy2"

# ---------------------------
# 启动 cloudflared 临时隧道
# ---------------------------
CLOUDFLARED_BIN="$WORKDIR/cloudflared"
if [ ! -x "$CLOUDFLARED_BIN" ]; then
  echo "[cloudflared] downloading cloudflared ..."
  curl -fsSL -o "$CLOUDFLARED_BIN" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
  chmod +x "$CLOUDFLARED_BIN"
fi

echo "[cloudflared] starting temporary tunnel for local Xray ..."
TUNNEL_LOG="$WORKDIR/tunnel.log"
"$CLOUDFLARED_BIN" tunnel --url "http://127.0.0.1:$PORT" > "$TUNNEL_LOG" 2>&1 &

# 等 Cloudflare 输出 trycloudflare 域名
TEMP_DOMAIN=""
for i in $(seq 1 90); do
  if grep -q "trycloudflare.com" "$TUNNEL_LOG"; then
    TEMP_DOMAIN=$(grep -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\.com" "$TUNNEL_LOG" | head -n 1 | sed 's|https://||')
    break
  fi
  echo "[cloudflared] waiting for temporary domain ($i/90)..."
  sleep 2
done

if [ -z "$TEMP_DOMAIN" ]; then
  echo "[ERROR] Cloudflare temporary tunnel domain not detected!"
  TEMP_DOMAIN="localhost"
else
  echo "[OK] Temporary tunnel established at: $TEMP_DOMAIN"
fi

# ---------------------------
# 更新 Xray 配置（注入正确域名/SNI）
# ---------------------------
cd "$WORKDIR/xy"
jq --arg sni "$TEMP_DOMAIN" --arg path "$WS_PATH" '
  .inbounds[0].streamSettings.tlsSettings.serverName = $sni |
  .inbounds[0].streamSettings.wsSettings.path = $path
' config.json > config.tmp.json && mv config.tmp.json config.json

# ---------------------------
# 生成 VLESS 链接
# ---------------------------
ENC_PATH=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$WS_PATH")
VLESS_URL="vless://$UUID@$TEMP_DOMAIN:443?encryption=none&security=tls&type=ws&host=$TEMP_DOMAIN&path=${ENC_PATH}&sni=$TEMP_DOMAIN#lunes-ws-tls"

echo "$VLESS_URL" > "$WORKDIR/node.txt"
echo "$HY2_URL" >> "$WORKDIR/node.txt"

# ---------------------------
# 输出信息
# ---------------------------
echo "============================================================"
echo "🚀 Node Info"
echo "VLESS (via temporary tunnel):"
echo "$VLESS_URL"
echo "HY2 (direct):"
echo "$HY2_URL"
echo "============================================================"
echo "✅ install.sh finished. You can start the server with: node $WORKDIR/app.js"
