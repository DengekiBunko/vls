#!/usr/bin/env sh
set -eu

# 默认值（可由环境变量覆盖）
DOMAIN="${DOMAIN:-node68.lunes.host}"
PORT="${PORT:-10008}"
UUID="${UUID:-2584b733-9095-4bec-a7d5-62b473540f7a}"
HY2_PASSWORD="${HY2_PASSWORD:-vevc.HY2.Password}"
WS_PATH="${WS_PATH:-/wspath}"
CFTUNNEL_TOKEN="${CFTUNNEL_TOKEN:-}"

cd /home/container || exit 1
mkdir -p /home/container/xy /home/container/h2

# 下载 app.js 和 package.json（如果需要）
curl -sSL -o /home/container/app.js https://raw.githubusercontent.com/DengekiBunko/vls/refs/heads/main/lunes-host/app.js || true
curl -sSL -o /home/container/package.json https://raw.githubusercontent.com/DengekiBunko/vls/refs/heads/main/lunes-host/package.json || true

# ---------- Xray ----------
cd /home/container/xy
echo "[install] Downloading Xray..."
curl -sSL -o Xray-linux-64.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip" || true
if command -v unzip >/dev/null 2>&1; then
  unzip -o Xray-linux-64.zip || true
  rm -f Xray-linux-64.zip
fi
# move binary if present
if [ -f xray ]; then mv -f xray xy || true; fi
if [ -f Xray ]; then mv -f Xray xy || true; fi
chmod +x /home/container/xy/xy || true

# write xy config (plain WS origin)
cat > /home/container/xy/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": 10008,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "YOUR_UUID", "email": "lunes-ws" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": { "path": "YOUR_WS_PATH" }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF

sed -i "s/10008/$PORT/g" /home/container/xy/config.json
sed -i "s/YOUR_UUID/$UUID/g" /home/container/xy/config.json
case "$WS_PATH" in
  /*) ;;
  *) WS_PATH="/$WS_PATH" ;;
esac
sed -i "s|YOUR_WS_PATH|$WS_PATH|g" /home/container/xy/config.json

# ---------- Hysteria2 ----------
cd /home/container/h2
echo "[install] Downloading Hysteria..."
curl -sSL -o h2 "https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.2/hysteria-linux-amd64" || true
chmod +x /home/container/h2/h2 || true

# Try to download example config; if missing, create a minimal config that uses the cert paths below
if ! curl -sSL -o /home/container/h2/config.yaml https://raw.githubusercontent.com/DengekiBunko/vls/refs/heads/main/lunes-host/hysteria-config.yaml; then
  cat > /home/container/h2/config.yaml <<EOF
listen: :$PORT
cert: /home/container/h2/cert.pem
key: /home/container/h2/key.pem
obfs: none
auth:
  - type: password
    password: "$HY2_PASSWORD"
EOF
fi

# Generate self-signed cert for h2 if not present
if [ ! -f /home/container/h2/cert.pem ] || [ ! -f /home/container/h2/key.pem ]; then
  echo "[install] Generating self-signed cert for hysteria2..."
  openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
    -keyout /home/container/h2/key.pem -out /home/container/h2/cert.pem \
    -subj "/CN=$DOMAIN"
  chmod 600 /home/container/h2/key.pem /home/container/h2/cert.pem || true
fi

# Replace placeholders in config.yaml if present
if [ -f /home/container/h2/config.yaml ]; then
  sed -i "s/10008/$PORT/g" /home/container/h2/config.yaml || true
  sed -i "s/HY2_PASSWORD/$HY2_PASSWORD/g" /home/container/h2/config.yaml || true
fi

# ---------- cloudflared binary ----------
cd /home/container
echo "[install] Downloading cloudflared binary (linux-amd64)..."
curl -L -o /home/container/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x /home/container/cloudflared || true
if [ -x /home/container/cloudflared ]; then /home/container/cloudflared --version || true; fi

# ---------- node links ----------
encoded_path=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$WS_PATH" 2>/dev/null || echo "%2Fwspath")
vlessUrl="vless://$UUID@$DOMAIN:443?encryption=none&security=tls&type=ws&host=$DOMAIN&path=$encoded_path&sni=$DOMAIN#lunes-ws"
echo "$vlessUrl" > /home/container/node.txt

encodedHy2Pwd=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$HY2_PASSWORD" 2>/dev/null || echo "vevc.HY2.Password")
hy2Url="hysteria2://$encodedHy2Pwd@$DOMAIN:$PORT?insecure=1#lunes-hy2"
echo "$hy2Url" >> /home/container/node.txt

chmod +x /home/container/app.js || true
chmod +x /home/container/cloudflared || true

echo "============================================================"
echo "Setup complete."
echo " - Xray config: /home/container/xy/config.json"
echo " - Hysteria config: /home/container/h2/config.yaml"
echo " - h2 cert: /home/container/h2/cert.pem"
echo " - node links: /home/container/node.txt"
if [ -n "$CFTUNNEL_TOKEN" ]; then
  echo "cloudflared token present; app.js will attempt to start cloudflared with the token."
else
  echo "No CFTUNNEL_TOKEN provided. If you want a fixed named tunnel, run with CFTUNNEL_TOKEN set."
fi
echo "Start processes: npm start  OR  node /home/container/app.js"
echo "============================================================"
