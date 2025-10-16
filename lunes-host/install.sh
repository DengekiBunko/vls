#!/usr/bin/env sh
set -eu

# ----------------------
# 环境变量（部署时传入）
# ----------------------
DOMAIN="${DOMAIN:-luneshost01.xdzw.dpdns.org}"
PORT="${PORT:-3460}"
UUID="${UUID:-your-uuid}"
HY2_PASSWORD="${HY2_PASSWORD:-your-hy2-password}"
WS_PATH="${WS_PATH:-/wspath}"
TUNNEL_NAME="${TUNNEL_NAME:-mytunnel}"     # 隧道名（如果已存在请填已有隧道名）
WORKDIR="/home/container"
CLOUDFLARED_BIN="$WORKDIR/cloudflared"
CLOUDFLARED_DIR="$WORKDIR/.cloudflared"
LOGDIR="$WORKDIR/logs"

echo "===== install.sh starting ====="
echo "DOMAIN=$DOMAIN PORT=$PORT UUID=$UUID TUNNEL_NAME=$TUNNEL_NAME"

# ----------------------
# 目录准备
# ----------------------
mkdir -p "$WORKDIR" "$WORKDIR/xy" "$WORKDIR/h2" "$CLOUDFLARED_DIR" "$LOGDIR"
cd "$WORKDIR"

# ----------------------
# 下载 cloudflared（二进制，使用绝对路径）
# ----------------------
if [ ! -x "$CLOUDFLARED_BIN" ]; then
  echo "[cloudflared] downloading binary..."
  curl -fsSL -o "$CLOUDFLARED_BIN" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" || {
    echo "[cloudflared] download failed"; exit 1;
  }
  chmod +x "$CLOUDFLARED_BIN"
fi
echo "[cloudflared] binary ready at $CLOUDFLARED_BIN"

# ----------------------
# 下载并准备 Xray
# ----------------------
cd "$WORKDIR/xy"
echo "[xray] downloading..."
curl -fsSL -o Xray-linux-64.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip" || true
if command -v unzip >/dev/null 2>&1 && [ -f Xray-linux-64.zip ]; then
  unzip -o Xray-linux-64.zip || true
  rm -f Xray-linux-64.zip
fi
# attempt common binary names
if [ -f xray ]; then mv -f xray xy || true; fi
if [ -f Xray ]; then mv -f Xray xy || true; fi
# if xy binary exists, make executable
if [ -f "$WORKDIR/xy/xy" ]; then chmod +x "$WORKDIR/xy/xy"; fi

# generate self-signed cert for xray (origin TLS)
echo "[xray] generating self-signed cert..."
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
  -keyout "$WORKDIR/xy/key.pem" -out "$WORKDIR/xy/cert.pem" -subj "/CN=$DOMAIN" >/dev/null 2>&1 || true
chmod 600 "$WORKDIR/xy/key.pem" "$WORKDIR/xy/cert.pem" || true

# write xray config (absolute cert paths)
cat > "$WORKDIR/xy/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": { "clients": [ { "id": "$UUID", "email": "lunes-ws-tls" } ], "decryption": "none" },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "certificates": [ { "certificateFile": "$WORKDIR/xy/cert.pem", "keyFile": "$WORKDIR/xy/key.pem" } ]
        },
        "wsSettings": { "path": "$WS_PATH" }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF

# ----------------------
# 下载并准备 Hysteria2（hy2）
# ----------------------
cd "$WORKDIR/h2"
echo "[h2] downloading hysteria..."
curl -fsSL -o h2 "https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.4/hysteria-linux-amd64" || true
chmod +x "$WORKDIR/h2/h2" || true

# generate cert for h2
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
  -keyout "$WORKDIR/h2/key.pem" -out "$WORKDIR/h2/cert.pem" -subj "/CN=$DOMAIN" >/dev/null 2>&1 || true
chmod 600 "$WORKDIR/h2/key.pem" "$WORKDIR/h2/cert.pem" || true

# write hysteria config (use absolute cert paths)
cat > "$WORKDIR/h2/config.yaml" <<EOF
listen: 0.0.0.0:$PORT
cert: $WORKDIR/h2/cert.pem
key: $WORKDIR/h2/key.pem
# keep obfs/auth in format expected by your hysteria build; example password auth:
auth:
  type: password
  password: "$HY2_PASSWORD"
# salamander obfs example (uncomment if desired)
# obfs:
#   type: salamander
#   salamander:
#     password: "$HY2_PASSWORD"
EOF

# ----------------------
# Cloudflared login flow (use absolute path)
# ----------------------
echo ""
echo "====== Cloudflared login flow ======"
echo "If this is the first time, you'll be asked to open the URL printed below in your browser."
echo "After approving, cloudflared will write a cert file to $CLOUDFLARED_DIR and we will create the tunnel."
echo ""

# ensure directory exists
mkdir -p "$CLOUDFLARED_DIR"

# run login (this prints URL for browser); use absolute binary
# note: use --origincert to write cert file to the specified path
echo "[cloudflared] running login (open the URL shown in your browser and complete authentication)..."
"$CLOUDFLARED_BIN" login --origincert "$CLOUDFLARED_DIR/cert.pem" || {
  echo "[cloudflared] login command returned non-zero (if you already logged in earlier this may be fine)"
}

echo ""
echo "[cloudflared] If login printed a URL, open it in your browser now and complete authentication."
echo "Waiting 10s for you to finish login..."
sleep 10

# After login, create tunnel (this will create credentials file $CLOUDFLARED_DIR/<tunnel>.json)
echo "[cloudflared] creating tunnel named '$TUNNEL_NAME' (credentials will be saved to $CLOUDFLARED_DIR)..."
# If tunnel already exists, this command may fail — that's acceptable; we'll try to proceed.
set +e
"$CLOUDFLARED_BIN" tunnel create "$TUNNEL_NAME" --credentials-file "$CLOUDFLARED_DIR/$TUNNEL_NAME.json"
CREATE_RC=$?
set -e
if [ "$CREATE_RC" -ne 0 ]; then
  echo "[cloudflared] tunnel create returned non-zero (maybe tunnel exists). Attempting to continue."
fi

# route DNS (register public hostname). This may fail if you don't have permissions; that's okay.
echo "[cloudflared] attempting to create DNS route $TUNNEL_NAME -> $DOMAIN (may require Cloudflare account permissions)..."
set +e
"$CLOUDFLARED_BIN" tunnel route dns "$TUNNEL_NAME" "$DOMAIN"
ROUTE_RC=$?
set -e
if [ "$ROUTE_RC" -ne 0 ]; then
  echo "[cloudflared] tunnel route dns returned non-zero (it may require Cloudflare account privileges). Continue anyway."
fi

# run the tunnel (background)
echo "[cloudflared] starting tunnel (background)... logs -> $LOGDIR/cloudflared.log"
nohup "$CLOUDFLARED_BIN" tunnel run "$TUNNEL_NAME" --credentials-file "$CLOUDFLARED_DIR/$TUNNEL_NAME.json" >"$LOGDIR/cloudflared.log" 2>&1 &

# give cloudflared some seconds to initialize
sleep 4

# ----------------------
# 启动 Xray 与 Hysteria2（后台，日志到 logs）
# ----------------------
# start xray if binary exists
if [ -x "$WORKDIR/xy/xy" ]; then
  echo "[xray] starting (background) -> $LOGDIR/xray.log"
  nohup "$WORKDIR/xy/xy" -c "$WORKDIR/xy/config.json" >"$LOGDIR/xray.log" 2>&1 &
else
  echo "[xray] binary not found at $WORKDIR/xy/xy — please check Xray binary"
fi

# start h2 if binary exists
if [ -x "$WORKDIR/h2/h2" ]; then
  echo "[h2] starting (background) -> $LOGDIR/h2.log"
  nohup "$WORKDIR/h2/h2" server -c "$WORKDIR/h2/config.yaml" >"$LOGDIR/h2.log" 2>&1 &
else
  echo "[h2] binary not found at $WORKDIR/h2/h2 — please check hysteria binary"
fi

# ----------------------
# 输出节点信息（优先使用 Cloudflare 公网域名 + 443 作为访问地址）
# ----------------------
ENC_PATH=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$WS_PATH" 2>/dev/null || printf "%2Fwspath")
VLESS_URL="vless://$UUID@$DOMAIN:443?encryption=none&security=tls&type=ws&host=$DOMAIN&path=${ENC_PATH}&sni=$DOMAIN#lunes-ws-tls"
HY2_ENC=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$HY2_PASSWORD" 2>/dev/null || printf "pwd")
HY2_URL="hysteria2://$HY2_ENC@$DOMAIN:443?insecure=1#lunes-hy2"

echo ""
echo "============================================================"
echo "Setup finished (background processes started). Logs:"
echo " - cloudflared: $LOGDIR/cloudflared.log"
echo " - xray:       $LOGDIR/xray.log"
echo " - h2:         $LOGDIR/h2.log"
echo ""
echo "Node links (written to $WORKDIR/node.txt):"
echo "$VLESS_URL"
echo "$HY2_URL"
echo "============================================================"

echo "$VLESS_URL" > "$WORKDIR/node.txt"
echo "$HY2_URL" >> "$WORKDIR/node.txt"

# show small tail of cloudflared log for quick check
sleep 1
echo ""
echo "----- recent cloudflared log -----"
if [ -f "$LOGDIR/cloudflared.log" ]; then
  tail -n 30 "$LOGDIR/cloudflared.log" || true
else
  echo "(no cloudflared log yet)"
fi

# done
echo "install.sh completed."
