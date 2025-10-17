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

mkdir -p "$WORKDIR"

# ---------------------------
# 下载 app.js 和 package.json
# ---------------------------
echo "[node] downloading app.js and package.json ..."
curl -sSL -o "$WORKDIR/app.js" https://raw.githubusercontent.com/DengekiBunko/vls/refs/heads/main/lunes-host/app-temp-tunnel.js
curl -sSL -o "$WORKDIR/package.json" https://raw.githubusercontent.com/DengekiBunko/vls/refs/heads/main/lunes-host/package.json

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
# Hysteria2 配置
# ---------------------------
mkdir -p "$WORKDIR/h2"
cd "$WORKDIR/h2"
curl -sSL -o h2 https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.2/hysteria-linux-amd64
curl -sSL -o config.yaml https://raw.githubusercontent.com/DengekiBunko/vls/refs/heads/main/lunes-host/hysteria-config.yaml
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout key.pem -out cert.pem -subj "/CN=$DOMAIN"
chmod +x h2
sed -i "s/10008/$PORT/g" config.yaml
sed -i "s/HY2_PASSWORD/$HY2_PASSWORD/g" config.yaml

# ---------------------------
# 输出安装完成信息
# ---------------------------
echo "============================================================"
echo "✅ install.sh finished. You can start the server with: node $WORKDIR/app.js"
