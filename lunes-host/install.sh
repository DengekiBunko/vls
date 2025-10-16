#!/usr/bin/env sh
set -eu

# === 用户可覆盖的环境变量 ===
DOMAIN="${DOMAIN:-node68.lunes.host}"
PORT="${PORT:-10008}"
UUID="${UUID:-2584b733-9095-4bec-a7d5-62b473540f7a}"
HY2_PASSWORD="${HY2_PASSWORD:-vevc.HY2.Password}"
WS_PATH="${WS_PATH:-/wspath}"
TUNNEL_NAME="${TUNNEL_NAME:-lunes01}"
WORKDIR="${WORKDIR:-/home/container}"

CLOUDFLARED_BIN="$WORKDIR/cloudflared"
CLOUDFLARED_DIR="$WORKDIR/.cloudflared"
XY_DIR="$WORKDIR/xy"
H2_DIR="$WORKDIR/h2"
LOGDIR="$WORKDIR/logs"
NODETXT="$WORKDIR/node.txt"

echo "===== install.sh starting (init only) ====="
echo "DOMAIN=$DOMAIN PORT=$PORT TUNNEL_NAME=$TUNNEL_NAME"

mkdir -p "$WORKDIR" "$CLOUDFLARED_DIR" "$XY_DIR" "$H2_DIR" "$LOGDIR"
cd "$WORKDIR"

# ---------------------------
# 1️⃣ 保留原下载 app.js/package.json 步骤
# ---------------------------
echo "[node] downloading app.js and package.json ..."
curl -sSL -o app.js https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/app.js
curl -sSL -o package.json https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/package.json

# ---------------------------
# 2️⃣ cloudflared 二进制下载
# ---------------------------
if [ ! -x "$CLOUDFLARED_BIN" ]; then
  echo "[cloudflared] downloading to $CLOUDFLARED_BIN ..."
  curl -fsSL -o "$CLOUDFLARED_BIN" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
  chmod +x "$CLOUDFLARED_BIN"
fi
"$CLOUDFLARED_BIN" --version || true

# ---------------------------
# 3️⃣ Xray (xy) 下载+配置+证书
# ---------------------------
mkdir -p "$XY_DIR"
cd "$XY_DIR"
curl -fsSL -o Xray-linux-64.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip" || true
command -v unzip >/dev/null 2>&1 && [ -f Xray-linux-64.zip ] && unzip -o Xray-linux-64.zip >/dev/null 2>&1 && rm -f Xray-linux-64.zip
[ -f xray ] && mv -f xray xy || true
[ -f Xray ] && mv -f Xray xy || true
[ -f "$XY_DIR/xy" ] && chmod +x "$XY_DIR/xy"

openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
  -keyout "$XY_DIR/key.pem" -out "$XY_DIR/cert.pem" -subj "/CN=$DOMAIN"
chmod 600 "$XY_DIR/key.pem" "$XY_DIR/cert.pem"

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
        "tlsSettings": { "certificates": [{ "certificateFile": "$XY_DIR/cert.pem","keyFile": "$XY_DIR/key.pem" }] },
        "wsSettings": { "path": "$WS_PATH" }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF

# ---------------------------
# 4️⃣ Hysteria2 下载+配置+证书
# ---------------------------
mkdir -p "$H2_DIR"
cd "$H2_DIR"
curl -fsSL -o h2 "https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.4/hysteria-linux-amd64"
chmod +x "$H2_DIR/h2"
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
  -keyout "$H2_DIR/key.pem" -out "$H2_DIR/cert.pem" -subj "/CN=$DOMAIN"
chmod 600 "$H2_DIR/key.pem" "$H2_DIR/cert.pem"

cat > "$H2_DIR/config.yaml" <<EOF
listen: 0.0.0.0:$PORT
cert: $H2_DIR/cert.pem
key: $H2_DIR/key.pem
auth:
  type: password
  password: "$HY2_PASSWORD"
EOF

# ---------------------------
# 5️⃣ Cloudflared interactive login (生成 tunnel，不运行)
# ---------------------------
echo ""
echo "[cloudflared] interactive login (open URL in browser)..."
set +e
"$CLOUDFLARED_BIN" login
LOGIN_RC=$?
set -e
[ $LOGIN_RC -ne 0 ] && echo "[cloudflared] login returned non-zero, may be okay if already logged in"

# Poll cert.pem
WAIT=0; MAX=300; SLEEP=5; CERT_FOUND=""
while [ $WAIT -lt $MAX ]; do
  for d in "$CLOUDFLARED_DIR" "$HOME/.cloudflared" "/root/.cloudflared" "/.cloudflared"; do
    [ -f "$d/cert.pem" ] && { CERT_FOUND="$d/cert.pem"; break 2; }
  done
  echo "[cloudflared] waiting for cert.pem... $WAIT/$MAX"
  sleep $SLEEP
  WAIT=$((WAIT + SLEEP))
done

if [ -z "$CERT_FOUND" ]; then
  echo "[cloudflared] cert.pem not found. Place manually in $CLOUDFLARED_DIR"
else
  echo "[cloudflared] found cert: $CERT_FOUND"
  [ "$(dirname "$CERT_FOUND")" != "$CLOUDFLARED_DIR" ] && cp -a "$(dirname "$CERT_FOUND")"/* "$CLOUDFLARED_DIR"/ && chmod 600 "$CLOUDFLARED_DIR"/*
fi

echo "install.sh finished. Node.js app remains intact."
echo "Start the server with: node /home/container/app.js"
