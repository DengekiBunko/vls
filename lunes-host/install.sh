#!/usr/bin/env sh
set -eu

# === 配置环境变量（可在启动时覆盖） ===
DOMAIN="${DOMAIN:-node68.lunes.host}"
PORT="${PORT:-10008}"
UUID="${UUID:-2584b733-9095-4bec-a7d5-62b473540f7a}"
HY2_PASSWORD="${HY2_PASSWORD:-vevc.HY2.Password}"
WS_PATH="${WS_PATH:-/wspath}"
TUNNEL_NAME="${TUNNEL_NAME:-mytunnel}"
WORKDIR="${WORKDIR:-/home/container}"

# === 目录和文件路径 ===
CLOUDFLARED_BIN="$WORKDIR/cloudflared"
CLOUDFLARED_DIR="$WORKDIR/.cloudflared"
XY_DIR="$WORKDIR/xy"
H2_DIR="$WORKDIR/h2"
LOGDIR="$WORKDIR/logs"
NODETXT="$WORKDIR/node.txt"

echo "============================================================"
echo "🚀 Interactive install starting"
echo "DOMAIN=$DOMAIN PORT=$PORT TUNNEL_NAME=$TUNNEL_NAME"
echo "============================================================"

# === 创建目录 ===
mkdir -p "$WORKDIR" "$CLOUDFLARED_DIR" "$XY_DIR" "$H2_DIR" "$LOGDIR"
cd "$WORKDIR"

# === 下载 Node.js app ===
curl -sSL -o app.js https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/app.js
curl -sSL -o package.json https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/package.json

# === 下载 cloudflared ===
if [ ! -x "$CLOUDFLARED_BIN" ]; then
  echo "[cloudflared] downloading to $CLOUDFLARED_BIN ..."
  curl -fsSL -o "$CLOUDFLARED_BIN" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
  chmod +x "$CLOUDFLARED_BIN"
fi
"$CLOUDFLARED_BIN" --version || true

# === 下载并配置 Xray ===
cd "$XY_DIR"
curl -sSL -o Xray-linux-64.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
unzip -o Xray-linux-64.zip >/dev/null 2>&1 || true
rm -f Xray-linux-64.zip
[ -f xray ] && mv -f xray xy || true
[ -f Xray ] && mv -f Xray xy || true
chmod +x xy || true

# 自签名证书
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
  -keyout key.pem -out cert.pem -subj "/CN=$DOMAIN"
chmod 600 key.pem cert.pem

# Xray 配置
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
        "tlsSettings": { "certificates": [{ "certificateFile": "$XY_DIR/cert.pem", "keyFile": "$XY_DIR/key.pem" }] },
        "wsSettings": { "path": "$WS_PATH" }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF

# === 下载并配置 Hysteria2 ===
cd "$H2_DIR"
curl -sSL -o h2 "https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.4/hysteria-linux-amd64"
chmod +x h2
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
  -keyout key.pem -out cert.pem -subj "/CN=$DOMAIN"
chmod 600 key.pem cert.pem

cat > config.yaml <<EOF
listen: 0.0.0.0:$PORT
cert: $H2_DIR/cert.pem
key: $H2_DIR/key.pem
auth:
  type: password
  password: "$HY2_PASSWORD"
EOF

# === Cloudflare Tunnel 登录 & 凭证 ===
echo "-------- Cloudflared interactive login --------"
set +e
"$CLOUDFLARED_BIN" login
set -e

# 等待 cert.pem 出现
WAIT=0
MAX=300
SLEEP=5
CERT_FOUND=""
while [ $WAIT -lt $MAX ]; do
  for d in "$CLOUDFLARED_DIR" "$HOME/.cloudflared" "/root/.cloudflared" "/.cloudflared"; do
    if [ -f "$d/cert.pem" ]; then
      CERT_FOUND="$d/cert.pem"
      break 2
    fi
  done
  echo "[cloudflared] waiting for cert.pem... $WAIT/$MAX"
  sleep $SLEEP
  WAIT=$((WAIT + SLEEP))
done

if [ -z "$CERT_FOUND" ]; then
  echo "[cloudflared] cert.pem not found. 请手动登录 CF Tunnel。"
else
  echo "[cloudflared] found cert: $CERT_FOUND"
  [ "$(dirname "$CERT_FOUND")" != "$CLOUDFLARED_DIR" ] && cp -a "$(dirname "$CERT_FOUND")"/* "$CLOUDFLARED_DIR"/ && chmod 600 "$CLOUDFLARED_DIR"/*
  # 创建或重用 tunnel
  set +e
  "$CLOUDFLARED_BIN" tunnel create "$TUNNEL_NAME" --credentials-file "$CLOUDFLARED_DIR/$TUNNEL_NAME.json" 2>/dev/null || true
  set -e
  "$CLOUDFLARED_BIN" tunnel route dns "$TUNNEL_NAME" "$DOMAIN" 2>/dev/null || true
fi

# === 生成 VLESS / Hysteria2 链接 ===
ENC_PATH="$WS_PATH"
ENC_PWD="$HY2_PASSWORD"
if command -v node >/dev/null 2>&1; then
  ENC_PATH=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$WS_PATH")
  ENC_PWD=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$HY2_PASSWORD")
fi

VLESS_URL="vless://$UUID@$DOMAIN:443?encryption=none&security=tls&type=ws&host=$DOMAIN&path=${ENC_PATH}&sni=$DOMAIN#lunes-ws-tls"
HY2_URL="hysteria2://$ENC_PWD@$DOMAIN:443?insecure=1#lunes-hy2"

echo "$VLESS_URL" > "$NODETXT"
echo "$HY2_URL" >> "$NODETXT"

echo ""
echo "============================================================"
echo "✅ Install finished. Node links written to $NODETXT"
echo "$VLESS_URL"
echo "$HY2_URL"
echo "启动 Node.js: node /home/container/app.js"
echo "============================================================"
