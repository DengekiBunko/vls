#!/usr/bin/env sh
set -eu

WORKDIR="/home/container"
DOMAIN="${DOMAIN:-node68.lunes.host}"
PORT="${PORT:-10008}"
UUID="${UUID:-2584b733-2b32-4036-8e26-df7b984f7f9e}"
HY2_PASSWORD="${HY2_PASSWORD:-vevc.HY2.Password}"
WS_PATH="${WS_PATH:-/wspath}"

mkdir -p "$WORKDIR"
cd "$WORKDIR"

echo "[install] Installing dependencies..."

# Xray
mkdir -p xy
cd xy
if [ ! -x xy ]; then
  curl -sSL -o Xray.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
  unzip -o Xray.zip >/dev/null 2>&1
  mv Xray xy
  chmod +x xy
  rm -f Xray.zip
fi
if [ ! -f cert.pem ]; then
  openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout key.pem -out cert.pem -subj "/CN=$DOMAIN" >/dev/null 2>&1
fi
cat > config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": $PORT,
    "protocol": "vless",
    "settings": { "clients": [{ "id": "$UUID" }], "decryption": "none" },
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
cd ..

# Hysteria2
mkdir -p h2
cd h2
if [ ! -x h2 ]; then
  curl -sSL -o h2 "https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.2/hysteria-linux-amd64"
  chmod +x h2
fi
cat > config.yaml <<EOF
listen: :$PORT
auth:
  type: password
  password: $HY2_PASSWORD
tls:
  cert: $WORKDIR/h2/cert.pem
  key: $WORKDIR/h2/key.pem
quic:
  disablePathMTUDiscovery: true
  maxIdleTimeout: 30s
  maxIncomingStreams: 128
EOF
if [ ! -f cert.pem ]; then
  openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout key.pem -out cert.pem -subj "/CN=$DOMAIN" >/dev/null 2>&1
fi
cd ..

# cloudflared
if [ ! -x "$WORKDIR/cloudflared" ]; then
  curl -fsSL -o "$WORKDIR/cloudflared" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
  chmod +x "$WORKDIR/cloudflared"
fi

echo "============================================================"
echo "✅ install.sh completed."
echo "You can now start server with: node /home/container/app.js"
echo "============================================================"
