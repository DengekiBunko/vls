#!/usr/bin/env sh
set -eu

# ========================
# Interactive Install + Cloudflared login + Tunnel create/run
# ========================
# Environment variables (override when running)
DOMAIN="${DOMAIN:-example.com}"
PORT="${PORT:-3460}"
UUID="${UUID:-your-uuid}"
HY2_PASSWORD="${HY2_PASSWORD:-your-hy2-password}"
WS_PATH="${WS_PATH:-/wspath}"
TUNNEL_NAME="${TUNNEL_NAME:-mytunnel}"
WORKDIR="${WORKDIR:-/home/container}"

# Derived paths
CLOUDFLARED_BIN="$WORKDIR/cloudflared"
CLOUDFLARED_DIR="$WORKDIR/.cloudflared"
XY_DIR="$WORKDIR/xy"
H2_DIR="$WORKDIR/h2"
LOGDIR="$WORKDIR/logs"
NODETXT="$WORKDIR/node.txt"

echo "============================================================"
echo " Interactive install starting"
echo " DOMAIN=$DOMAIN"
echo " PORT=$PORT"
echo " UUID=$UUID"
echo " HY2_PASSWORD=${HY2_PASSWORD:+(set)}"
echo " WS_PATH=$WS_PATH"
echo " TUNNEL_NAME=$TUNNEL_NAME"
echo " WORKDIR=$WORKDIR"
echo "============================================================"

# create dirs
mkdir -p "$WORKDIR" "$CLOUDFLARED_DIR" "$XY_DIR" "$H2_DIR" "$LOGDIR"
cd "$WORKDIR"

# -------------------------------------------------------------------
# 1) download cloudflared binary (absolute path usage)
# -------------------------------------------------------------------
if [ ! -x "$CLOUDFLARED_BIN" ]; then
  echo "[cloudflared] downloading binary to $CLOUDFLARED_BIN ..."
  # download raw binary (no tar)
  curl -fsSL -o "$CLOUDFLARED_BIN" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" || {
    echo "[cloudflared] download failed"; exit 1;
  }
  chmod +x "$CLOUDFLARED_BIN"
fi
echo "[cloudflared] ready: $CLOUDFLARED_BIN"
# print version if possible
"$CLOUDFLARED_BIN" --version 2>/dev/null || true

# -------------------------------------------------------------------
# 2) download Xray (VLESS+WS+TLS) and write config (uses absolute paths)
# -------------------------------------------------------------------
echo "[xray] preparing..."
mkdir -p "$XY_DIR"
cd "$XY_DIR"
curl -fsSL -o Xray-linux-64.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip" || true
if command -v unzip >/dev/null 2>&1 && [ -f Xray-linux-64.zip ]; then
  unzip -o Xray-linux-64.zip >/dev/null 2>&1 || true
  rm -f Xray-linux-64.zip
fi
# move binary if present
if [ -f xray ]; then mv -f xray xy >/dev/null 2>&1 || true; fi
if [ -f Xray ]; then mv -f Xray xy >/dev/null 2>&1 || true; fi
if [ -f "$XY_DIR/xy" ]; then chmod +x "$XY_DIR/xy" || true; fi

# generate origin cert for xray
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
  -keyout "$XY_DIR/key.pem" -out "$XY_DIR/cert.pem" -subj "/CN=$DOMAIN" >/dev/null 2>&1 || true
chmod 600 "$XY_DIR/key.pem" "$XY_DIR/cert.pem" || true

# create xray config
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
          "certificates": [ { "certificateFile": "$XY_DIR/cert.pem", "keyFile": "$XY_DIR/key.pem" } ]
        },
        "wsSettings": { "path": "$WS_PATH" }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF

# -------------------------------------------------------------------
# 3) download hysteria and write config
# -------------------------------------------------------------------
echo "[h2] preparing..."
mkdir -p "$H2_DIR"
cd "$H2_DIR"
curl -fsSL -o h2 "https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.4/hysteria-linux-amd64" || true
chmod +x "$H2_DIR/h2" || true

# generate certs for h2
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

# -------------------------------------------------------------------
# 4) Interactive cloudflared login (prints URL); script will poll for cert
# -------------------------------------------------------------------
echo ""
echo "------------------------------------------------------------"
echo "[cloudflared] Starting interactive login. A URL will be printed — open it in your browser and complete login."
echo "If you already logged in previously on this container, skip the browser step."
echo "Waiting for cert to be created in $CLOUDFLARED_DIR (polling up to 300s)..."
echo "------------------------------------------------------------"
echo ""

# run login (use absolute binary)
# Note: some cloudflared versions accept --origincert, some don't; we use login without flags.
set +e
"$CLOUDFLARED_BIN" login
LOGIN_RC=$?
set -e
if [ $LOGIN_RC -ne 0 ]; then
  echo "[cloudflared] 'login' returned non-zero (this may still be fine if you already have credentials)."
fi

# Poll for cert file creation in common locations (prefer container dir)
SECONDS_WAITED=0
MAX_WAIT=300
SLEEP_INTERVAL=5
CERT_FOUND=""
while [ $SECONDS_WAITED -lt $MAX_WAIT ]; do
  # check common locations (order matters)
  for d in "$CLOUDFLARED_DIR" "$HOME/.cloudflared" "/root/.cloudflared" "/.cloudflared"; do
    if [ -f "$d/cert.pem" ]; then
      CERT_FOUND="$d/cert.pem"
      break 2
    fi
  done
  sleep $SLEEP_INTERVAL
  SECONDS_WAITED=$((SECONDS_WAITED + SLEEP_INTERVAL))
  echo "[cloudflared] waiting for login completion... $SECONDS_WAITED/$MAX_WAIT sec"
done

if [ -z "$CERT_FOUND" ]; then
  echo "[cloudflared] cert.pem not found after waiting $MAX_WAIT seconds."
  echo "[cloudflared] You must run '/home/container/cloudflared login' manually and complete browser auth, or place cert.pem into $CLOUDFLARED_DIR."
  echo "Proceeding, but tunnel create/run may fail."
else
  echo "[cloudflared] found cert: $CERT_FOUND"
  # if cert not in our container dir, copy it there for convenience
  if [ "$(dirname "$CERT_FOUND")" != "$CLOUDFLARED_DIR" ]; then
    echo "[cloudflared] copying cert files to $CLOUDFLARED_DIR"
    mkdir -p "$CLOUDFLARED_DIR"
    cp -a "$(dirname "$CERT_FOUND")"/* "$CLOUDFLARED_DIR"/ || true
    chmod 600 "$CLOUDFLARED_DIR"/* || true
  fi
fi

# -------------------------------------------------------------------
# 5) Create tunnel if missing, or reuse existing
# -------------------------------------------------------------------
echo "[cloudflared] checking existing tunnels..."
set +e
LIST_OUT=$("$CLOUDFLARED_BIN" tunnel list 2>/dev/null || true)
set -e

# try to parse for existing tunnel with same name
FOUND_NAME=""
if [ -n "$LIST_OUT" ]; then
  # loop through lines and look for exact tunnel name as first token (skip header)
  echo "$LIST_OUT" | sed -n '1,200p' >/tmp/cf_tunnel_list.txt 2>/dev/null || true
  # skip header lines, search for line containing our TUNNEL_NAME
  FOUND_NAME=$(echo "$LIST_OUT" | awk -v name="$TUNNEL_NAME" 'tolower($0) ~ tolower(name) { print $1; exit }' || true)
fi

if [ -n "$FOUND_NAME" ]; then
  echo "[cloudflared] found existing tunnel: $FOUND_NAME (will reuse)"
  TUNNEL_RUN_NAME="$FOUND_NAME"
else
  echo "[cloudflared] creating tunnel named '$TUNNEL_NAME' ..."
  set +e
  CREATE_OUT=$("$CLOUDFLARED_BIN" tunnel create "$TUNNEL_NAME" 2>&1 || true)
  CREATE_RC=$?
  set -e
  echo "$CREATE_OUT" | sed -n '1,120p'
  # If creation succeeded, use TUNNEL_NAME; otherwise attempt to parse ID from list again
  if [ $CREATE_RC -eq 0 ]; then
    TUNNEL_RUN_NAME="$TUNNEL_NAME"
  else
    echo "[cloudflared] tunnel create returned non-zero; trying to find any tunnel to run..."
    LIST_OUT=$("$CLOUDFLARED_BIN" tunnel list 2>/dev/null || true)
    FOUND_NAME=$(echo "$LIST_OUT" | awk -v name="$TUNNEL_NAME" 'tolower($0) ~ tolower(name) { print $1; exit }' || true)
    if [ -n "$FOUND_NAME" ]; then
      TUNNEL_RUN_NAME="$FOUND_NAME"
    else
      # fallback to first non-header line name if any
      FIRST_LINE_NAME=$(echo "$LIST_OUT" | awk 'NR>1{print $1; exit}' || true)
      if [ -n "$FIRST_LINE_NAME" ]; then
        TUNNEL_RUN_NAME="$FIRST_LINE_NAME"
        echo "[cloudflared] using first tunnel from list: $TUNNEL_RUN_NAME"
      else
        echo "[cloudflared] no tunnels available; tunnel run will likely fail."
        TUNNEL_RUN_NAME=""
      fi
    fi
  fi
fi

# -------------------------------------------------------------------
# 6) Attempt to route DNS -> may require account permissions
# -------------------------------------------------------------------
if [ -n "$TUNNEL_RUN_NAME" ]; then
  echo "[cloudflared] attempting to route DNS: $TUNNEL_RUN_NAME -> $DOMAIN (may require account privileges)"
  set +e
  "$CLOUDFLARED_BIN" tunnel route dns "$TUNNEL_RUN_NAME" "$DOMAIN" 2>&1 | sed -n '1,200p' || true
  set -e
else
  echo "[cloudflared] skipping DNS route because no tunnel name available"
fi

# -------------------------------------------------------------------
# 7) Start tunnel (background) and start services
# -------------------------------------------------------------------
if [ -n "$TUNNEL_RUN_NAME" ]; then
  echo "[cloudflared] starting tunnel in background (logs -> $LOGDIR/cloudflared.log) ..."
  nohup "$CLOUDFLARED_BIN" tunnel run "$TUNNEL_RUN_NAME" --credentials-file "$CLOUDFLARED_DIR/$TUNNEL_RUN_NAME.json" >"$LOGDIR/cloudflared.log" 2>&1 &
  sleep 2
else
  echo "[cloudflared] tunnel name empty; skipping tunnel run"
fi

# start xray
if [ -x "$XY_DIR/xy" ]; then
  echo "[xray] starting background (log -> $LOGDIR/xray.log)"
  nohup "$XY_DIR/xy" -c "$XY_DIR/config.json" >"$LOGDIR/xray.log" 2>&1 &
else
  echo "[xray] binary not present at $XY_DIR/xy; not started"
fi

# start h2
if [ -x "$H2_DIR/h2" ]; then
  echo "[h2] starting background (log -> $LOGDIR/h2.log)"
  nohup "$H2_DIR/h2" server -c "$H2_DIR/config.yaml" >"$LOGDIR/h2.log" 2>&1 &
else
  echo "[h2] binary not present at $H2_DIR/h2; not started"
fi

# -------------------------------------------------------------------
# 8) write node links (prefer 443 + domain)
# -------------------------------------------------------------------
# Use node to url-encode path and password (if node available); fallback crude encoding
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

# print summary and tail cloudflared log
echo ""
echo "============================================================"
echo "Setup completed (background processes may be running)."
echo "Node links written to $NODETXT:"
echo "$VLESS_URL"
echo "$HY2_URL"
echo ""
echo "Logs:"
echo " - cloudflared: $LOGDIR/cloudflared.log"
echo " - xray:       $LOGDIR/xray.log"
echo " - h2:         $LOGDIR/h2.log"
echo "============================================================"
echo ""
echo "Tail cloudflared log (if exists):"
if [ -f "$LOGDIR/cloudflared.log" ]; then
  tail -n 40 "$LOGDIR/cloudflared.log" || true
else
  echo "(no cloudflared log yet)"
fi

# done
echo "install.sh finished."
