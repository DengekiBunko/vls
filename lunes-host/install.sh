#!/usr/bin/env sh
set -eu

# ---------------------------
# 配置变量（可通过环境变量覆盖）
# ---------------------------
WORKDIR="${WORKDIR:-/home/container}"
DOMAIN="${DOMAIN:-node68.lunes.host}"   # 你部署时传入的容器地址（外部可访问域名/面板分配域名）
PORT="${PORT:-10008}"                   # 你部署时传入的容器外部端口映射
UUID="${UUID:-2584b733-2b32-4036-8e26-df7b984f7f9e}"
HY2_PASSWORD="${HY2_PASSWORD:-vevc.HY2.Password}"
WS_PATH="${WS_PATH:-/wspath}"

mkdir -p "$WORKDIR"
cd "$WORKDIR"

echo "[node] downloading app.js and package.json ..."
# 注意：如果你想使用自定义 app.js，可改为不覆盖
curl -sSL -o "$WORKDIR/app.js" https://raw.githubusercontent.com/DengekiBunko/vls/refs/heads/main/lunes-host/app.js || true
curl -sSL -o "$WORKDIR/package.json" https://raw.githubusercontent.com/DengekiBunko/vls/refs/heads/main/lunes-host/package.json || true

# ---------------------------
# Xray (VLESS WS+TLS) 安装
# ---------------------------
mkdir -p "$WORKDIR/xy"
cd "$WORKDIR/xy"
echo "[Xray] downloading..."
curl -sSL -o Xray-linux-64.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip" || true
if command -v unzip >/dev/null 2>&1; then
  unzip -o Xray-linux-64.zip >/dev/null 2>&1 || true
fi
rm -f Xray-linux-64.zip
[ -f xray ] && mv -f xray xy || true
[ -f Xray ] && mv -f Xray xy || true
chmod +x xy || true

# 生成自签证书（用于 origin TLS）
if [ ! -f cert.pem ] || [ ! -f key.pem ]; then
  openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout key.pem -out cert.pem -subj "/CN=$DOMAIN" >/dev/null 2>&1 || true
fi

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
# Hysteria2 安装（直连）
# ---------------------------
mkdir -p "$WORKDIR/h2"
cd "$WORKDIR/h2"
echo "[h2] downloading..."
curl -sSL -o h2 "https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.2/hysteria-linux-amd64" || true
curl -sSL -o config.yaml "https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/hysteria-config.yaml" || true
chmod +x h2 || true

# 如果 config.yaml 存在则替换端口与密码
if [ -f config.yaml ]; then
  sed -i "s/10008/$PORT/g" config.yaml || true
  sed -i "s/HY2_PASSWORD/$HY2_PASSWORD/g" config.yaml || true
fi

# 确保 hysteria 证书文件存在：如果不存在则创建（保持原有 config 不变）
if [ ! -f cert.pem ] || [ ! -f key.pem ]; then
  openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout key.pem -out cert.pem -subj "/CN=$DOMAIN" >/dev/null 2>&1 || true
fi

# prepare hysteria url (direct)
ENC_PWD="$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$HY2_PASSWORD")"
HY2_URL="hysteria2://${ENC_PWD}@${DOMAIN}:${PORT}?insecure=1#lunes-hy2"

# ---------------------------
# Cloudflared: 下载 & login
# ---------------------------
CLOUDFLARED_BIN="$WORKDIR/cloudflared"
CLOUDFLARED_DIR="$WORKDIR/.cloudflared"
mkdir -p "$CLOUDFLARED_DIR"

if [ ! -x "$CLOUDFLARED_BIN" ]; then
  echo "[cloudflared] downloading cloudflared..."
  curl -fsSL -o "$CLOUDFLARED_BIN" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" || true
  chmod +x "$CLOUDFLARED_BIN" || true
fi

echo "-------- Cloudflared interactive login (if required) --------"
# 交互认证：若运行环境可打开浏览器，会提示 URL。若非交互，请手动把 cert.pem 放到 $CLOUDFLARED_DIR
set +e
"$CLOUDFLARED_BIN" login || true
set -e

# 等待 cert.pem（最多 120 秒）
WAIT=0
MAX_WAIT=120
SLEEP=1
CERT=""
while [ $WAIT -lt $MAX_WAIT ]; do
  if [ -f "$CLOUDFLARED_DIR/cert.pem" ]; then
    CERT="$CLOUDFLARED_DIR/cert.pem"
    break
  fi
  echo "[cloudflared] waiting for cert.pem ($WAIT/$MAX_WAIT)..."
  sleep $SLEEP
  WAIT=$((WAIT + SLEEP))
done

# ---------------------------
# 启动临时隧道并尝试提取临时域名（优先）
# ---------------------------
TMP_LOG="$WORKDIR/cloudflared-tmp.log"
rm -f "$TMP_LOG"
TUNNEL_HOST=""

if [ -n "$CERT" ]; then
  echo "[cloudflared] cert.pem found, starting temporary tunnel in background..."
  # 启动临时隧道（后台），把输出写入日志
  nohup "$CLOUDFLARED_BIN" tunnel --url "http://127.0.0.1:$PORT" run > "$TMP_LOG" 2>&1 &
  # 等待并从日志中提取域名（trycloudflare 或 cfargotunnel）
  for i in $(seq 1 30); do
    sleep 1
    # 先找带 scheme 的 trycloudflare
    TUNNEL_HOST=$(grep -oE 'https?://[a-z0-9.-]+\.trycloudflare\.com' "$TMP_LOG" 2>/dev/null | head -1 || true)
    if [ -n "$TUNNEL_HOST" ]; then
      TUNNEL_HOST=$(echo "$TUNNEL_HOST" | sed -E 's~https?://~~; s~/$~~')
      break
    fi
    # 再找不带 scheme 的 trycloudflare
    TUNNEL_HOST=$(grep -oE '[a-z0-9-]+\.trycloudflare\.com' "$TMP_LOG" 2>/dev/null | head -1 || true)
    if [ -n "$TUNNEL_HOST" ]; then
      break
    fi
    # 尝试 cfargotunnel 域名
    TUNNEL_HOST=$(grep -oE 'https?://[a-z0-9.-]+\.cfargotunnel\.com' "$TMP_LOG" 2>/dev/null | head -1 || true)
    if [ -n "$TUNNEL_HOST" ]; then
      TUNNEL_HOST=$(echo "$TUNNEL_HOST" | sed -E 's~https?://~~; s~/$~~')
      break
    fi
    TUNNEL_HOST=$(grep -oE '[a-z0-9-]+\.cfargotunnel\.com' "$TMP_LOG" 2>/dev/null | head -1 || true)
    if [ -n "$TUNNEL_HOST" ]; then
      break
    fi
  done

  if [ -z "$TUNNEL_HOST" ]; then
    echo "[cloudflared] warning: could not extract temporary tunnel host from $TMP_LOG; fallback to container DOMAIN: $DOMAIN"
    TUNNEL_HOST="$DOMAIN"
  fi
else
  echo "[cloudflared] cert.pem not found; skipping automatic temporary tunnel start. You must provide cert.pem in $CLOUDFLARED_DIR or run cloudflared login interactively."
  TUNNEL_HOST="$DOMAIN"
fi

# ---------------------------
# 如果存在 credentials json，生成 config.yml 供 later app.js 使用（使 cloudflared --config run 可用）
# ---------------------------
CRED_JSON=$(ls -1 "$CLOUDFLARED_DIR"/*.json 2>/dev/null | head -n1 || true)
if [ -n "$CRED_JSON" ]; then
  TUNNEL_ID=$(basename "$CRED_JSON" .json)
  cat > "$CLOUDFLARED_DIR/config.yml" <<EOF
tunnel: $TUNNEL_ID
credentials-file: $CRED_JSON
ingress:
  - hostname: $DOMAIN
    service: http://localhost:$PORT
  - service: http_status:404
EOF
  echo "[cloudflared] config.yml created pointing to credentials: $CRED_JSON"
fi

# ---------------------------
# 生成节点链接写入 node.txt（VLESS 使用临时隧道:443；HY2 使用部署时的 DOMAIN:PORT 直连）
# ---------------------------
ENC_PATH="$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$WS_PATH")"
ENC_PWD="$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$HY2_PASSWORD")"

VLESS_URL="vless://${UUID}@${TUNNEL_HOST}:443?encryption=none&security=tls&type=ws&host=${TUNNEL_HOST}&path=${ENC_PATH}&sni=${TUNNEL_HOST}#lunes-ws-tls"
HY2_URL="hysteria2://${ENC_PWD}@${DOMAIN}:${PORT}?insecure=1#lunes-hy2"

echo "$VLESS_URL" > "$WORKDIR/node.txt"
echo "$HY2_URL" >> "$WORKDIR/node.txt"

# ---------------------------
# 输出信息
# ---------------------------
echo "============================================================"
echo "🚀 VLESS WS (via cloudflared temporary tunnel) & HY2 (direct) Node Info"
echo
echo "VLESS (via tunnel, port 443):"
echo "$VLESS_URL"
echo
echo "HY2 (direct to container):"
echo "$HY2_URL"
echo
echo "Extracted temporary tunnel host: $TUNNEL_HOST"
echo "Cloudflared log: $TMP_LOG"
echo "Cloudflared credentials dir: $CLOUDFLARED_DIR"
echo "============================================================"
echo "✅ install.sh finished. Start server with: node $WORKDIR/app.js"
