#!/usr/bin/env sh

set -eu

# ---------------------------
# 配置变量（可通过环境变量覆盖）
# ---------------------------
DOMAIN="${DOMAIN:-$(hostname -f)}"
PORT="${PORT:-10008}"
UUID="${UUID:-2584b733-2b32-4036-8e26-df7b984f7f9e}"
HY2_PASSWORD="${HY2_PASSWORD:-vevc.HY2.Password}"
WS_PATH="${WS_PATH:-/wspath}"
WORKDIR="${WORKDIR:-/home/container}"

# ---------------------------
# 下载 app.js 和 package.json
# ---------------------------
echo "[node] downloading app.js and package.json ..."
curl -sSL -o "$WORKDIR/app.js" https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/app.js
curl -sSL -o "$WORKDIR/package.json" https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/package.json

# ---------------------------
# Xray (xy) VLESS+WS 配置（使用 TLS:none）
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

# 不需要在 Xray 端生成 TLS 证书，Cloudflare 隧道提供 TLS

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
# Hysteria2 (h2) 配置
# ---------------------------
mkdir -p "$WORKDIR/h2"
cd "$WORKDIR/h2"
curl -sSL -o h2 https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.2/hysteria-linux-amd64
curl -sSL -o config.yaml https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/hysteria-config.yaml
# 生成自签证书供 Hysteria 使用（启用 TLS）
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout key.pem -out cert.pem -subj "/CN=$DOMAIN"
chmod +x h2
sed -i "s/10008/$PORT/g" config.yaml
sed -i "s/HY2_PASSWORD/$HY2_PASSWORD/g" config.yaml

# ---------------------------
# Cloudflared 临时隧道
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

# 等待 cert.pem
WAIT=0 MAX=300 SLEEP=5
while [ $WAIT -lt $MAX ]; do
    if [ -f "$CLOUDFLARED_DIR/cert.pem" ]; then
        break
    fi
    echo "[cloudflared] waiting for cert.pem $WAIT/$MAX"
    sleep $SLEEP
    WAIT=$((WAIT + SLEEP))
done

if [ ! -f "$CLOUDFLARED_DIR/cert.pem" ]; then
    echo "[cloudflared] cert.pem not found. 请放置 cert.pem 到 $CLOUDFLARED_DIR 或手动 login"
    # 不退出，继续尝试启动隧道
fi

echo "[cloudflared] starting temporary tunnel..."
# 将输出重定向到日志文件，稍后从中提取域名
"$CLOUDFLARED_BIN" tunnel --url "http://localhost:$PORT" --no-autoupdate run > "$WORKDIR/cloudflared.log" 2>&1 &
# 等待隧道启动并打印域名
TUNNEL_DOMAIN=""
for i in $(seq 1 10); do
    # 提取 trycloudflare 子域名（示例输出见:contentReference[oaicite:5]{index=5}）
    TUNNEL_DOMAIN=$(grep -o "https://[A-Za-z0-9-]*\\.trycloudflare\\.com" "$WORKDIR/cloudflared.log" | head -n1 | sed 's|https://||')
    if [ -n "$TUNNEL_DOMAIN" ]; then
        break
    fi
    sleep 1
done

if [ -z "$TUNNEL_DOMAIN" ]; then
    echo "[cloudflared] 隧道域名提取失败，请检查 cloudflared 日志。"
else
    echo "[cloudflared] 隧道域名：$TUNNEL_DOMAIN"
fi

# ---------------------------
# 构建 VLESS 和 Hysteria2 链接
# ---------------------------
ENC_PATH=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$WS_PATH")
ENC_PWD=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$HY2_PASSWORD")

# VLESS 使用 Cloudflare 隧道域名（TLS），Hysteria2 使用容器域名和端口（TLS）
if [ -n "$TUNNEL_DOMAIN" ]; then
    VLESS_URL="vless://$UUID@$TUNNEL_DOMAIN:443?encryption=none&security=tls&type=ws&host=$TUNNEL_DOMAIN&path=${ENC_PATH}&sni=$TUNNEL_DOMAIN#lunes-ws-tls"
else
    # 如果隧道域名未获取，则回退到原域名
    VLESS_URL="vless://$UUID@$DOMAIN:443?encryption=none&security=tls&type=ws&host=$DOMAIN&path=${ENC_PATH}&sni=$DOMAIN#lunes-ws-tls"
fi
HY2_URL="hysteria2://$ENC_PWD@$DOMAIN:$PORT?insecure=1#lunes-hy2"

echo "$VLESS_URL" > "$WORKDIR/node.txt"
echo "$HY2_URL" >> "$WORKDIR/node.txt"

# ---------------------------
# 输出信息
# ---------------------------
echo "============================================================"
echo "🚀 VLESS WS+TLS & HY2 Node Info"
echo "$VLESS_URL"
echo "$HY2_URL"
echo "============================================================"
echo "✅ install.sh finished. You can start the server with: node $WORKDIR/app.js"
