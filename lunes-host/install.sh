#!/usr/bin/env sh
set -eu

# -------------------------
# 配置（可由环境变量覆盖）
# -------------------------
DOMAIN="${DOMAIN:-node24.lunes.host}"
PORT="${PORT:-3460}"
UUID="${UUID:-2584b733-9095-4bec-a7d5-62b473540f7a}"
HY2_PASSWORD="${HY2_PASSWORD:-vevc.HY2.Password}"
WS_PATH="${WS_PATH:-/wspath}"
CFTUNNEL_TOKEN="${CFTUNNEL_TOKEN:-}"        # 可选：Cloudflare 隧道 token（建议通过 Pterodactyl Environment 注入）
PUBLIC_HOSTNAME="${PUBLIC_HOSTNAME:-}"       # 可选：Cloudflare Public Hostname（若使用 cloudflared/CF，填入）
# -------------------------

echo "[install.sh] start"

cd /home/container || exit 1

# 保证目录
mkdir -p /home/container/xy /home/container/h2 /home/container/.cloudflared

# -------------------------
# Download app.js & package.json (from original repo)
# -------------------------
curl -sSL -o /home/container/app.js https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/app.js || true
curl -sSL -o /home/container/package.json https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/package.json || true
chmod +x /home/container/app.js || true

# -------------------------
# Xray (xy) - download & config
# -------------------------
cd /home/container/xy
echo "[install.sh] Downloading Xray..."
curl -sSL -o Xray-linux-64.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip" || true
if command -v unzip >/dev/null 2>&1; then
  unzip -o Xray-linux-64.zip || true
  rm -f Xray-linux-64.zip
else
  echo "[install.sh][warn] unzip not found; ensure xray binary exists in /home/container/xy"
fi

# normalize binary name
if [ -f xray ]; then mv -f xray xy || true; fi
if [ -f Xray ]; then mv -f Xray xy || true; fi
chmod +x /home/container/xy/xy || true

# create xray config (same structure as your original)
cat > /home/container/xy/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": 10008,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "YOUR_UUID",
            "email": "lunes-ws-tls"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "/home/container/xy/cert.pem",
              "keyFile": "/home/container/xy/key.pem"
            }
          ]
        },
        "wsSettings": {
          "path": "YOUR_WS_PATH"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF

# generate origin TLS certs for xray (in xy directory) - uses DOMAIN as CN
echo "[install.sh] Generating Xray origin cert..."
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout /home/container/xy/key.pem -out /home/container/xy/cert.pem -subj "/CN=${DOMAIN}" || true
chmod 600 /home/container/xy/key.pem /home/container/xy/cert.pem || true

# replace placeholders in xray config (match your original replacements)
sed -i "s/10008/$PORT/g" /home/container/xy/config.json
sed -i "s/YOUR_UUID/$UUID/g" /home/container/xy/config.json
case "$WS_PATH" in
  /*) ;;
  *) WS_PATH="/$WS_PATH" ;;
esac
sed -i "s|YOUR_WS_PATH|$WS_PATH|g" /home/container/xy/config.json

# build vless URL using DOMAIN:PORT (same behavior as your original)
ENC_PATH=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$WS_PATH" 2>/dev/null || printf "%2Fwspath")
VLESS_URL="vless://$UUID@$DOMAIN:$PORT?encryption=none&security=tls&type=ws&host=$DOMAIN&path=$ENC_PATH&sni=$DOMAIN#lunes-ws-tls"

# -------------------------
# Hysteria2 (h2) - ORIGINAL SECTION MOVED HERE (unchanged)
# -------------------------
mkdir -p /home/container/h2
cd /home/container/h2

echo "[install.sh] Downloading Hysteria binary..."
curl -sSL -o h2 "https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.2/hysteria-linux-amd64" || true
chmod +x /home/container/h2/h2 || true

# fetch original config.yaml from your repo (exact as original)
curl -sSL -o /home/container/h2/config.yaml https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/hysteria-config.yaml || true

# generate cert/key for h2 in its directory (same as your original)
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout /home/container/h2/key.pem -out /home/container/h2/cert.pem -subj "/CN=${DOMAIN}" || true
chmod 600 /home/container/h2/key.pem /home/container/h2/cert.pem || true

# make h2 executable
chmod +x /home/container/h2/h2 || true

# replace placeholders in the fetched config.yaml (same as original behavior)
sed -i "s/10008/$PORT/g" /home/container/h2/config.yaml || true
sed -i "s/HY2_PASSWORD/$HY2_PASSWORD/g" /home/container/h2/config.yaml || true

# build hysteria2 URL using DOMAIN:PORT (same as your original)
ENCODED_HY2_PWD=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$HY2_PASSWORD" 2>/dev/null || printf "password")
HY2_URL="hysteria2://$ENCODED_HY2_PWD@$DOMAIN:$PORT?insecure=1#lunes-hy2"

# -------------------------
# cloudflared (optional) - download binary
# -------------------------
cd /home/container
echo "[install.sh] Downloading cloudflared binary..."
curl -L -o /home/container/cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" || true
chmod +x /home/container/cloudflared || true
if [ -x /home/container/cloudflared ]; then /home/container/cloudflared --version || true; fi

# if token provided, save to .cloudflared/token.txt (recommend using panel env instead)
if [ -n "$CFTUNNEL_TOKEN" ]; then
  printf '%s' "$CFTUNNEL_TOKEN" > /home/container/.cloudflared/token.txt
  chmod 600 /home/container/.cloudflared/token.txt || true
  echo "[install.sh] CFTUNNEL_TOKEN written to /home/container/.cloudflared/token.txt"
fi

# -------------------------
# write node links (same as original)
# -------------------------
echo "$VLESS_URL" > /home/container/node.txt
echo "$HY2_URL" >> /home/container/node.txt

# -------------------------
# final info
# -------------------------
echo "============================================================"
echo "[install.sh] Setup complete."
echo " - Xray config: /home/container/xy/config.json"
echo " - Xray cert/key: /home/container/xy/cert.pem /home/container/xy/key.pem"
echo " - Hysteria config: /home/container/h2/config.yaml"
echo " - Hysteria cert/key: /home/container/h2/cert.pem /home/container/h2/key.pem"
echo " - node links: /home/container/node.txt"
echo " - cloudflared binary: /home/container/cloudflared"
echo "============================================================"
