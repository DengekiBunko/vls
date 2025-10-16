#!/usr/bin/env sh
set -eu

# === Usage:
# DOMAIN=... PORT=... UUID=... HY2_PASSWORD=... TUNNEL_NAME=... bash /home/container/install.sh
#
# This script performs ONE-TIME initialization:
# - downloads cloudflared, xray, hysteria binaries
# - creates xray/hysteria configs and self-signed certs
# - runs `cloudflared login` interactively (prints URL you must open)
# - attempts to create a tunnel with TUNNEL_NAME (writes credentials into /home/container/.cloudflared)
# It DOES NOT run the tunnel long-term. app.js will attempt to run the tunnel at startup.
# ===

DOMAIN="${DOMAIN:-example.com}"
PORT="${PORT:-3460}"
UUID="${UUID:-your-uuid}"
HY2_PASSWORD="${HY2_PASSWORD:-your-hy2-password}"
WS_PATH="${WS_PATH:-/wspath}"
TUNNEL_NAME="${TUNNEL_NAME:-mytunnel}"
WORKDIR="${WORKDIR:-/home/container}"

CLOUDFLARED_BIN="$WORKDIR/cloudflared"
CLOUDFLARED_DIR="$WORKDIR/.cloudflared"
XY_DIR="$WORKDIR/xy"
H2_DIR="$WORKDIR/h2"
LOGDIR="$WORKDIR/logs"
NODETXT="$WORKDIR/node.txt"

echo "===== install.sh starting (init only) ====="
echo "DOMAIN=$DOMAIN PORT=$PORT TUNNEL_NAME=$TUNNEL_NAME"

# Prepare directories
mkdir -p "$WORKDIR" "$CLOUDFLARED_DIR" "$XY_DIR" "$H2_DIR" "$LOGDIR"
cd "$WORKDIR"

# ---------------------------
# cloudflared binary
# ---------------------------
if [ ! -x "$CLOUDFLARED_BIN" ]; then
  echo "[cloudflared] downloading to $CLOUDFLARED_BIN ..."
  curl -fsSL -o "$CLOUDFLARED_BIN" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" || {
    echo "[cloudflared] download failed"; exit 1;
  }
  chmod +x "$CLOUDFLARED_BIN"
fi
echo "[cloudflared] ready: $CLOUDFLARED_BIN"
"$CLOUDFLARED_BIN" --version 2>/dev/null || true

# ---------------------------
# Xray (xy)
# ---------------------------
echo "[xray] downloading and preparing..."
cd "$XY_DIR"
curl -fsSL -o Xray-linux-64.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip" || true
if command -v unzip >/dev/null 2>&1 && [ -f Xray-linux-64.zip ]; then
  unzip -o Xray-linux-64.zip >/dev/null 2>&1 || true
  rm -f Xray-linux-64.zip
fi
# move binary to xy if present
[ -f xray ] && mv -f xray xy || true
[ -f Xray ] && mv -f Xray xy || true
[ -f "$XY_DIR/xy" ] && chmod +x "$XY_DIR/xy" || true

# gen self-signed cert for xray
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
  -keyout "$XY_DIR/key.pem" -out "$XY_DIR/cert.pem" -subj "/CN=$DOMAIN" >/dev/null 2>&1 || true
chmod 600 "$XY_DIR/key.pem" "$XY_DIR/cert.pem" || true

cat > "$XY_DIR/config.json" <<EOF
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

# ---------------------------
# Hysteria2 (h2)
# ---------------------------
echo "[h2] downloading and preparing..."
cd "$H2_DIR"
curl -fsSL -o h2 "https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.4/hysteria-linux-amd64" || true
chmod +x "$H2_DIR/h2" || true

# gen certs for h2
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
  -keyout "$H2_DIR/key.pem" -out "$H2_DIR/cert.pem" -subj "/CN=$DOMAIN" >/dev/null 2>&1 || true
chmod 600 "$H2_DIR/key.pem" "$H2_DIR/cert.pem" || true

cat > "$H2_DIR/config.yaml" <<EOF
listen: 0.0.0.0:$PORT
cert: $H2_DIR/cert.pem
key: $H2_DIR/key.pem
auth:
  type: password
  password: "$HY2_PASSWORD"
EOF

# ---------------------------
# cloudflared interactive login -> create tunnel (do not run tunnel long-term)
# ---------------------------
echo ""
echo "-------- Cloudflared interactive login --------"
echo "A browser URL will be printed. Open it and finish authorization."
echo "Script will wait up to 300s for cert.pem to appear."
echo ""

# Run login (prints URL). Some versions accept flags differently; we use plain 'login'
set +e
"$CLOUDFLARED_BIN" login
LOGIN_RC=$?
set -e
if [ $LOGIN_RC -ne 0 ]; then
  echo "[cloudflared] login returned non-zero; if you already logged in previously this can be okay."
fi

# Poll for cert.pem
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
  echo "[cloudflared] cert.pem not found. Place your cert.pem in $CLOUDFLARED_DIR or re-run login manually."
else
  echo "[cloudflared] found cert: $CERT_FOUND"
  if [ "$(dirname "$CERT_FOUND")" != "$CLOUDFLARED_DIR" ]; then
    echo "[cloudflared] copying cert files to $CLOUDFLARED_DIR"
    mkdir -p "$CLOUDFLARED_DIR"
    cp -a "$(dirname "$CERT_FOUND")"/* "$CLOUDFLARED_DIR"/ || true
    chmod 600 "$CLOUDFLARED_DIR"/* || true
  fi

  # Create tunnel if missing, else reuse
  echo "[cloudflared] attempting to create or reuse tunnel named '$TUNNEL_NAME' ..."
  set +e
  CREATE_OUT=$("$CLOUDFLARED_BIN" tunnel create "$TUNNEL_NAME" --credentials-file "$CLOUDFLARED_DIR/$TUNNEL_NAME.json" 2>&1 || true)
  CREATE_RC=$?
  set -e
  echo "$CREATE_OUT" | sed -n '1,120p' || true

  if [ $CREATE_RC -ne 0 ]; then
    echo "[cloudflared] tunnel create may have failed (maybe it exists). Attempting to list and pick a tunnel..."
    LIST_OUT=$("$CLOUDFLARED_BIN" tunnel list 2>/dev/null || true)
    echo "$LIST_OUT" | sed -n '1,200p' || true
  else
    echo "[cloudflared] tunnel created (credentials file placed under $CLOUDFLARED_DIR)"
  fi

  # Attempt to create route DNS (may require account permissions)
  set +e
  "$CLOUDFLARED_BIN" tunnel route dns "$TUNNEL_NAME" "$DOMAIN" 2>&1 | sed -n '1,120p' || true
  set -e

  echo "[cloudflared] initialization done. NOTE: this script does not run the tunnel long-term."
  echo "app.js will try to run the tunnel at container startup if credentials exist."
fi

# ---------------------------
# build node/hy2 urls for convenience
# ---------------------------
ENC_PATH="$WS_PATH"
if command -v node >/dev/null 2>&1; then
  ENC_PATH=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$WS_PATH")
fi
ENC_PWD="$HY2_PASSWORD"
if command -v node >/dev/null 2>&1; then
  ENC_PWD=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$HY2_PASSWORD")
fi

VLESS_URL="vless://$UUID@$DOMAIN:443?encryption=none&security=tls&type=ws&host=$DOMAIN&path=${ENC_PATH}&sni=$DOMAIN#lunes-ws-tls"
HY2_URL="hysteria2://$ENC_PWD@$DOMAIN:443?insecure=1#lunes-hy2"

echo "$VLESS_URL" > "$NODETXT"
echo "$HY2_URL" >> "$NODETXT"

echo ""
echo "install.sh finished. node links written to $NODETXT"
echo "You can start the server with: node /home/container/app.js"
