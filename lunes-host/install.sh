#!/usr/bin/env sh
set -eu

# -------------------------
# Config via env (do not hardcode sensitive values here)
# -------------------------
DOMAIN="${DOMAIN:-node24.lunes.host}"
PORT="${PORT:-3460}"
UUID="${UUID:-2584b733-9095-4bec-a7d5-62b473540f7f9e}"
HY2_PASSWORD="${HY2_PASSWORD:-vevc.HY2.Password}"
WS_PATH="${WS_PATH:-/wspath}"
CFTUNNEL_TOKEN="${CFTUNNEL_TOKEN:-}"     # optional: put in Pterodactyl Environment
CFTUNNEL_NAME="${CFTUNNEL_NAME:-}"       # optional: tunnel name/ID if you have it
PUBLIC_HOSTNAME="${PUBLIC_HOSTNAME:-}"    # optional: e.g. luneshost01.xdzw.dpdns.org
# -------------------------

echo "[install.sh] starting"

cd /home/container || exit 1
mkdir -p /home/container/xy /home/container/h2 /home/container/.cloudflared

# --- download app.js & package.json (keeps original app.js if exists) ---
curl -sSL -o /home/container/app.js https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/app.js || true
curl -sSL -o /home/container/package.json https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/package.json || true
chmod +x /home/container/app.js || true

# --- Xray (xy) download & config (keeps structure of your original script) ---
cd /home/container/xy
echo "[install.sh] downloading xray..."
curl -sSL -o Xray-linux-64.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip" || true
if command -v unzip >/dev/null 2>&1; then
  unzip -o Xray-linux-64.zip || true
  rm -f Xray-linux-64.zip
fi
# normalize binary name
if [ -f xray ]; then mv -f xray xy || true; fi
if [ -f Xray ]; then mv -f Xray xy || true; fi
chmod +x /home/container/xy/xy || true

# Create Xray config using your original template structure
cat > /home/container/xy/config.json <<'EOF'
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

# generate origin certs for xray (use DOMAIN as CN - keeping original behavior)
echo "[install.sh] generating xray self-signed cert..."
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
  -keyout /home/container/xy/key.pem -out /home/container/xy/cert.pem -subj "/CN=${DOMAIN}" || true
chmod 600 /home/container/xy/key.pem /home/container/xy/cert.pem || true

# replace placeholders in xray config (keeps your original sed replacements)
sed -i "s/10008/$PORT/g" /home/container/xy/config.json
sed -i "s/YOUR_UUID/$UUID/g" /home/container/xy/config.json
case "$WS_PATH" in
  /*) ;;
  *) WS_PATH="/$WS_PATH" ;;
esac
sed -i "s|YOUR_WS_PATH|$WS_PATH|g" /home/container/xy/config.json

# Build VLESS URL — preserve original behavior but prefer PUBLIC_HOSTNAME if set
# If you provided PUBLIC_HOSTNAME, we will write node.txt using that (port 443)
if [ -n "$PUBLIC_HOSTNAME" ]; then
  ENC_PATH=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$WS_PATH" 2>/dev/null || printf '%s' "%2Fwspath")
  VLESS_URL="vless://$UUID@$PUBLIC_HOSTNAME:443?encryption=none&security=tls&type=ws&host=$PUBLIC_HOSTNAME&path=$ENC_PATH&sni=$PUBLIC_HOSTNAME#lunes-ws-tls"
else
  ENC_PATH=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$WS_PATH" 2>/dev/null || printf '%s' "%2Fwspath")
  VLESS_URL="vless://$UUID@$DOMAIN:$PORT?encryption=none&security=tls&type=ws&host=$DOMAIN&path=$ENC_PATH&sni=$DOMAIN#lunes-ws-tls"
fi

# --- Hysteria2 (h2) original section preserved (download + fetch config + cert) ---
cd /home/container/h2
echo "[install.sh] downloading hysteria binary..."
curl -sSL -o h2 "https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.2/hysteria-linux-amd64" || true
chmod +x /home/container/h2/h2 || true

# Fetch the original hysteria config from your repo (preserve your original content)
echo "[install.sh] fetching original hysteria-config.yaml..."
curl -sSL -o /home/container/h2/config.yaml https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/hysteria-config.yaml || true

# Generate cert & key in h2 directory as original script did
echo "[install.sh] generating h2 cert..."
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout /home/container/h2/key.pem -out /home/container/h2/cert.pem -subj "/CN=${DOMAIN}" || true
chmod 600 /home/container/h2/key.pem /home/container/h2/cert.pem || true

# make h2 executable
chmod +x /home/container/h2/h2 || true

# replace placeholders in fetched config.yaml (this is your original sed behavior)
sed -i "s/10008/$PORT/g" /home/container/h2/config.yaml || true
sed -i "s/HY2_PASSWORD/$HY2_PASSWORD/g" /home/container/h2/config.yaml || true

# Build HY2 URL — if PUBLIC_HOSTNAME set, use it with 443; else fallback to DOMAIN:PORT
if [ -n "$PUBLIC_HOSTNAME" ]; then
  ENC_HY2_PWD=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$HY2_PASSWORD" 2>/dev/null || printf '%s' "password")
  HY2_URL="hysteria2://$ENC_HY2_PWD@$PUBLIC_HOSTNAME:443?insecure=1#lunes-hy2"
else
  ENC_HY2_PWD=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$HY2_PASSWORD" 2>/dev/null || printf '%s' "password")
  HY2_URL="hysteria2://$ENC_HY2_PWD@$DOMAIN:$PORT?insecure=1#lunes-hy2"
fi

# --- cloudflared - download binary ---
cd /home/container
echo "[install.sh] downloading cloudflared..."
curl -L -o /home/container/cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" || true
chmod +x /home/container/cloudflared || true
if [ -x /home/container/cloudflared ]; then /home/container/cloudflared --version || true; fi

# If token provided, save it to .cloudflared/token.txt (prefer panel env)
if [ -n "$CFTUNNEL_TOKEN" ]; then
  printf '%s' "$CFTUNNEL_TOKEN" > /home/container/.cloudflared/token.txt
  chmod 600 /home/container/.cloudflared/token.txt || true
  echo "[install.sh] saved CFTUNNEL_TOKEN to /home/container/.cloudflared/token.txt"
fi

# Write node links
echo "$VLESS_URL" > /home/container/node.txt
echo "$HY2_URL" >> /home/container/node.txt

echo "============================================================"
echo "[install.sh] setup complete"
echo " - Xray config: /home/container/xy/config.json"
echo " - Hysteria config: /home/container/h2/config.yaml"
echo " - node links: /home/container/node.txt"
echo " - cloudflared binary: /home/container/cloudflared"
echo "============================================================"
