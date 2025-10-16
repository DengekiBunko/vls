#!/usr/bin/env sh
set -eu

# ========================
# 环境变量（可在运行时覆盖）
# ========================
DOMAIN="${DOMAIN:-node68.lunes.host}"
PORT="${PORT:-10008}"
UUID="${UUID:-2584b733-9095-4bec-a7d5-62b473540f7a}"
HY2_PASSWORD="${HY2_PASSWORD:-vevc.HY2.Password}"
WS_PATH="${WS_PATH:-/wspath}" # WebSocket 路径
WORKDIR="${WORKDIR:-/home/container}"

# 目录和文件
XY_DIR="$WORKDIR/xy"
H2_DIR="$WORKDIR/h2"
LOGDIR="$WORKDIR/logs"
NODETXT="$WORKDIR/node.txt"

echo "===== install.sh starting ====="
echo "DOMAIN=$DOMAIN PORT=$PORT"

# ========================
# 下载 Node.js 文件
# ========================
cd "$WORKDIR"
curl -sSL -o app.js https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/app.js
curl -sSL -o package.json https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/package.json

# ========================
# Xray (VLESS+WS+TLS)
# ========================
mkdir -p "$XY_DIR"
cd "$XY_DIR"
curl -sSL -o Xray-linux-64.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
unzip -o Xray-linux-64.zip >/dev/null 2>&1 || true
rm -f Xray-linux-64.zip
[ -f xray ] && mv -f xray xy || true
[ -f Xray ] && mv -f Xray xy || true
chmod +x xy

# 生成自签名 TLS
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
  -keyout key.pem -out cert.pem -subj "/CN=$DOMAIN"
chmod 600 key.pem cert.pem

# 生成 config.json
cat > config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$UUID", "email": "lunes-ws-tls" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            { "certificateFile": "$XY_DIR/cert.pem", "keyFile": "$XY_DIR/key.pem" }
          ]
        },
        "wsSettings": { "path": "$WS_PATH" }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF

# ========================
# Hysteria2 (修正 TLS 配置)
# ========================
mkdir -p "$H2_DIR"
cd "$H2_DIR"
curl -sSL -o h2 https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.4/hysteria-linux-amd64
chmod +x h2

openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
  -keyout key.pem -out cert.pem -subj "/CN=$DOMAIN"
chmod 600 key.pem cert.pem

cat > config.yaml <<EOF
listen: 0.0.0.0:$PORT
tls:
  cert: $H2_DIR/cert.pem
  key: $H2_DIR/key.pem
auth:
  type: password
  password: "$HY2_PASSWORD"
EOF

# ========================
# 生成 Node URL
# ========================
ENC_PATH="$WS_PATH"
ENC_PWD="$HY2_PASSWORD"
if command -v node >/dev/null 2>&1; then
  ENC_PATH=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$WS_PATH")
  ENC_PWD=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$HY2_PASSWORD")
fi

VLESS_URL="vless://$UUID@$DOMAIN:$PORT?encryption=none&security=tls&type=ws&host=$DOMAIN&path=${ENC_PATH}&sni=$DOMAIN#lunes-ws-tls"
HY2_URL="hysteria2://$ENC_PWD@$DOMAIN:$PORT?insecure=1#lunes-hy2"

echo "$VLESS_URL" > "$NODETXT"
echo "$HY2_URL" >> "$NODETXT"

# ========================
# 输出信息
# ========================
echo "============================================================"
echo "🚀 VLESS WS+TLS & HY2 Node Info"
echo "------------------------------------------------------------"
echo "$VLESS_URL"
echo "$HY2_URL"
echo "============================================================"
echo "✅ install.sh finished. You can start the server with:"
echo "   node $WORKDIR/app.js"
