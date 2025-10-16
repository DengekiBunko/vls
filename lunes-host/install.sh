#!/usr/bin/env sh

# 严格模式：遇到错误即退出
set -eu

# ---------------------------
# 配置变量
# ---------------------------
DOMAIN="${DOMAIN:-node68.lunes.host}"
PORT="${PORT:-10008}"
UUID="${UUID:-2584b733-2b32-4036-8e26-df7b984f7f9e}"
HY2_PASSWORD="${HY2_PASSWORD:-vevc.HY2.Password}"
WS_PATH="${WS_PATH:-/wspath}"
TUNNEL_NAME="${TUNNEL_NAME:-mytunnel}"
WORKDIR="${WORKDIR:-/home/container}"

# ---------------------------
# 下载 app.js 和 package.json
# ---------------------------
echo "[node] downloading app.js and package.json ..."
# 确保使用您最新版本的 app.js
curl -sSL -o "$WORKDIR/app.js" https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/app.js || true
curl -sSL -o "$WORKDIR/package.json" https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/package.json

# ---------------------------
# Xray (xy) VLESS+WS 配置 (Cloudflared 终止 TLS)
# ---------------------------
mkdir -p "$WORKDIR/xy"
cd "$WORKDIR/xy"

echo "[Xray] downloading and installing Xray core..."
curl -sSL -o Xray-linux-64.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
if command -v unzip >/dev/null 2>&1; then
    unzip -o Xray-linux-64.zip >/dev/null 2>&1 || true
fi
rm -f Xray-linux-64.zip

# 检查解压后的文件是否存在并重命名，确保 'xy' 文件能被创建
if [ -f xray ]; then
    mv -f xray xy
elif [ -f Xray ]; then
    mv -f Xray xy
else
    echo "[Xray ERROR] Xray executable (xray or Xray) not found after extraction!"
    exit 1
fi

chmod +x xy

# 【重要修正】由于 Cloudflared 负责 TLS 终止，Xray 本地不再需要 TLS。
# 移除 tlsSettings 整个块。
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
        "security": "none", 
        "wsSettings": { "path": "$WS_PATH" }
      }
    }
  ],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

# ---------------------------
# Hysteria2 (h2) 配置 (保持不变)
# ---------------------------
mkdir -p /home/container/h2
cd /home/container/h2
curl -sSL -o h2 https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.2/hysteria-linux-amd64
curl -sSL -o config.yaml https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/hysteria-config.yaml
# Hysteria2 仍需自签证书
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout key.pem -out cert.pem -subj "/CN=$DOMAIN"
chmod +x h2
sed -i "s/10008/$PORT/g" config.yaml
sed -i "s/HY2_PASSWORD/$HY2_PASSWORD/g" config.yaml
encodedHy2Pwd=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$HY2_PASSWORD")
hy2Url="hysteria2://$encodedHy2Pwd@$DOMAIN:$PORT?insecure=1#lunes-hy2"
echo "$hy2Url" >> /home/container/node.txt

# ---------------------------
# Cloudflare Tunnel 交互式登录 + tunnel 创建
# ---------------------------
CLOUDFLARED_BIN="$WORKDIR/cloudflared"
CLOUDFLARED_DIR="$WORKDIR/.cloudflared"
mkdir -p "$CLOUDFLARED_DIR"

if [ ! -x "$CLOUDFLARED_BIN" ]; then
    echo "[cloudflared] downloading cloudflared ..."
    curl -fsSL -o "$CLOUDFLARED_BIN" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
    chmod +x "$CLOUDFLARED_BIN"
fi

echo "-------- Cloudflared interactive login --------"
set +e
"$CLOUDFLARED_BIN" login
set -e

WAIT=0 MAX=300 SLEEP=5 CERT=""
while [ $WAIT -lt $MAX ]; do
    if [ -f "$CLOUDFLARED_DIR/cert.pem" ]; then
        CERT="$CLOUDFLARED_DIR/cert.pem"
        break
    fi
    echo "[cloudflared] waiting for cert.pem $WAIT/$MAX"
    sleep $SLEEP
    WAIT=$((WAIT + SLEEP))
done

if [ -z "$CERT" ]; then
    echo "[cloudflared] cert.pem not found. 请放置 cert.pem 到 $CLOUDFLARED_DIR 或手动 login"
else
    echo "[cloudflared] found cert.pem, creating tunnel (if not exists) and routing DNS ..."
    set +e
    # 尝试创建隧道并捕获其 ID
    CREATE_OUTPUT=$("$CLOUDFLARED_BIN" tunnel create "$TUNNEL_NAME" 2>&1)
    echo "$CREATE_OUTPUT"
    # 从输出中提取 Tunnel ID (仅在隧道新创建时)
    TUNNEL_ID=$(echo "$CREATE_OUTPUT" | grep 'Created tunnel' | awk '{print $NF}')
    # 如果 ID 未从创建输出中提取 (隧道已存在)，尝试通过 list 命令获取
    if [ -z "$TUNNEL_ID" ]; then
        echo "[cloudflared] Tunnel already exists or ID not in output. Attempting to get ID from list."
        # 从 list 命令中获取 ID
        TUNNEL_ID=$("$CLOUDFLARED_BIN" tunnel list | grep -w "$TUNNEL_NAME" | awk '{print $NF}' | head -n 1)
    fi

    "$CLOUDFLARED_BIN" tunnel route dns "$TUNNEL_NAME" "$DOMAIN" 2>&1 || true
    set -e
    
    # ---------------------------------
    # 【关键】生成 config.yml
    # ---------------------------------
    if [ -z "$TUNNEL_ID" ]; then
        echo "[cloudflared ERROR] Could not determine TUNNEL_ID. Cloudflared launch will likely fail."
    else
        echo "[cloudflared] generating config.yml (ID: $TUNNEL_ID)..."
        cat > "$CLOUDFLARED_DIR/config.yml" <<EOF
tunnel: $TUNNEL_NAME
credentials-file: $CLOUDFLARED_DIR/$TUNNEL_ID.json
ingress:
  - hostname: $DOMAIN
    service: http://localhost:$PORT
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
    fi

    echo "[cloudflared] initialization done."
fi

# ---------------------------
# 构建 VLESS 和 HY2 链接
# ---------------------------
ENC_PATH=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$WS_PATH")
ENC_PWD=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$HY2_PASSWORD")

# VLESS-WS 使用 443 端口 (Cloudflare Tunnel)
VLESS_URL="vless://$UUID@$DOMAIN:443?encryption=none&security=tls&type=ws&host=$DOMAIN&path=${ENC_PATH}&sni=$DOMAIN#lunes-ws-tls"

# HY2 使用 $PORT 端口 (直连)
HY2_URL="hysteria2://$ENC_PWD@$DOMAIN:$PORT?insecure=1#lunes-hy2"

echo "$VLESS_URL" > "$WORKDIR/node.txt"
echo "$HY2_URL" >> "$WORKDIR/node.txt"

# ---------------------------
# 输出信息
# ---------------------------
echo "============================================================"
echo "🚀 VLESS WS+TLS & HY2 Node Info"
echo "--- VLESS (Cloudflare Tunnel 443) ---"
echo "$VLESS_URL"
echo "--- HY2 (Direct Connection $PORT) ---"
echo "$HY2_URL"
echo "============================================================"
echo "✅ install.sh finished. You can start the server with: node $WORKDIR/app.js"
