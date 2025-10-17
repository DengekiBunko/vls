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
WORKDIR="${WORKDIR:-/home/container}"

echo "[init] DOMAIN=$DOMAIN PORT=$PORT UUID=$UUID"

# ---------------------------
# 下载 app.js 和 package.json
# ---------------------------
echo "[node] downloading app.js and package.json ..."
curl -sSL -o "$WORKDIR/app.js" https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/app.js
curl -sSL -o "$WORKDIR/package.json" https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/package.json

# ---------------------------
# Xray VLESS+WS+TLS 配置
# ---------------------------
mkdir -p "$WORKDIR/xy"
cd "$WORKDIR/xy"

curl -sSL -o Xray-linux-64.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
if command -v unzip >/dev/null 2>&1; then unzip -o Xray-linux-64.zip >/dev/null 2>&1 || true; fi
rm -f Xray-linux-64.zip
[ -f xray ] && mv -f xray xy || true
[ -f Xray ] && mv -f Xray xy || true
chmod +x xy

openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
  -keyout key.pem -out cert.pem -subj "/CN=$DOMAIN"

cat > config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [ {
    "port": $PORT,
    "protocol": "vless",
    "settings": { "clients": [ { "id": "$UUID", "email": "lunes-ws-tls" } ], "decryption": "none" },
    "streamSettings": {
      "network": "ws",
      "security": "tls",
      "tlsSettings": { "certificates": [ { "certificateFile": "$WORKDIR/xy/cert.pem", "keyFile": "$WORKDIR/xy/key.pem" } ] },
      "wsSettings": { "path": "$WS_PATH" }
    }
  } ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF

# ---------------------------
# Hysteria2 (h2) 配置（直连）
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
# 启动 node 服务
# ---------------------------
echo "[node] starting node app..."
nohup node "$WORKDIR/app.js" > "$WORKDIR/node.log" 2>&1 &
sleep 5  # 等待服务就绪

# ---------------------------
# 启动 Cloudflared 临时隧道
# ---------------------------
CLOUDFLARED_BIN="$WORKDIR/cloudflared"
if [ ! -x "$CLOUDFLARED_BIN" ]; then
  echo "[cloudflared] downloading cloudflared ..."
  curl -fsSL -o "$CLOUDFLARED_BIN" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
  chmod +x "$CLOUDFLARED_BIN"
fi

echo "[cloudflared] starting temporary tunnel ..."
TUNNEL_LOG="$WORKDIR/tunnel.log"
"$CLOUDFLARED_BIN" tunnel --metrics localhost:3001 --url "http://127.0.0.1:$PORT" > "$TUNNEL_LOG" 2>&1 &
sleep 5  # 等待 cloudflared 启动

# ---------------------------
# 获取临时域名
# ---------------------------
TEMP_DOMAIN=""
if command -v curl >/dev/null 2>&1; then
  TEMP_DOMAIN=$(curl -s http://127.0.0.1:3001/quicktunnel | grep -oE '"hostname":"[^"]+"' | cut -d':' -f2 | tr -d '"')
fi

if [ -z "$TEMP_DOMAIN" ]; then
  echo "[ERROR] Temporary tunnel domain not found! Using localhost instead."
  TEMP_DOMAIN="localhost"
else
  echo "[cloudflared] temporary tunnel established: $TEMP_DOMAIN"
fi

# ---------------------------
# 构建 VLESS 链接
# ---------------------------
ENC_PATH=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$WS_PATH")
VLESS_URL="vless://$UUID@$TEMP_DOMAIN:443?encryption=none&security=tls&type=ws&host=$TEMP_DOMAIN&path=${ENC_PATH}&sni=$TEMP_DOMAIN#lunes-ws-tls"

# ---------------------------
# 写入 node.txt
# ---------------------------
echo "$VLESS_URL" > "$WORKDIR/node.txt"
echo "$hy2Url" >> "$WORKDIR/node.txt"

# ---------------------------
# 输出信息
# ---------------------------
echo "============================================================"
echo "🚀 Node Info"
echo "VLESS (via temporary tunnel):"
echo "$VLESS_URL"
echo "HY2 (direct):"
echo "$hy2Url"
echo "============================================================"
echo "✅ install.sh finished. You can start the server with: node $WORKDIR/app.js"
