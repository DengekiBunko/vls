#!/usr/bin/env sh

set -eu

# ---------------------------
# 配置变量（可通过环境变量覆盖）
# ---------------------------
DOMAIN="${DOMAIN:-$(hostname -f)}"
PORT="${PORT:-10008}"                       # 容器服务端口（Xray 和 Hysteria 都使用这个端口）
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
# Xray (xy) VLESS+WS 配置（走 Cloudflared 隧道 -> backend 不做 TLS）
# ---------------------------
mkdir -p "$WORKDIR/xy"
cd "$WORKDIR/xy"

echo "[xy] downloading Xray binary ..."
curl -sSL -o Xray-linux-64.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
if command -v unzip >/dev/null 2>&1; then
    unzip -o Xray-linux-64.zip >/dev/null 2>&1 || true
fi
rm -f Xray-linux-64.zip
[ -f xray ] && mv -f xray xy || true
[ -f Xray ] && mv -f Xray xy || true
chmod +x xy

# Xray: 不在服务端做 TLS（由 Cloudflared 提供外部 TLS）
cat > config.json <<EOF
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
        "security": "none",
        "wsSettings": { "path": "$WS_PATH" }
      }
    }
  ],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

# ---------------------------
# Hysteria2 (h2) 配置（直连容器，启用 TLS）
# ---------------------------
mkdir -p "$WORKDIR/h2"
cd "$WORKDIR/h2"

echo "[h2] downloading Hysteria binary ..."
curl -sSL -o h2 https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.2/hysteria-linux-amd64
curl -sSL -o config.yaml https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/hysteria-config.yaml

# 生成自签证书（Hysteria 使用，启用 TLS）
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout key.pem -out cert.pem -subj "/CN=$DOMAIN"
chmod +x h2

# 将 hysteria-config.yaml 中的端口和密码替换为当前的 PORT/HY2_PASSWORD
# 注意：我们让 Hysteria 使用和 Xray 相同的 PORT（容器内同端口分流），确保 config.yaml 中的端口项能被替换
sed -i "s/10008/$PORT/g" config.yaml
sed -i "s/HY2_PASSWORD/$HY2_PASSWORD/g" config.yaml

# ---------------------------
# Cloudflared 临时隧道（Quick Tunnel）
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
WAIT=0 MAX=300 SLEEP=2
while [ $WAIT -lt $MAX ]; do
    if [ -f "$CLOUDFLARED_DIR/cert.pem" ]; then
        echo "[cloudflared] cert.pem found."
        break
    fi
    echo "[cloudflared] waiting for cert.pem $WAIT/$MAX"
    sleep $SLEEP
    WAIT=$((WAIT + SLEEP))
done

if [ ! -f "$CLOUDFLARED_DIR/cert.pem" ]; then
    echo "[cloudflared] cert.pem not found. 请放置 cert.pem 到 $CLOUDFLARED_DIR 或手动 login"
    # 仍然继续尝试启动隧道（如果用户已经完成 login，cert 会被写入）
fi

# 启动临时隧道并把输出写到日志，后台运行
CLOUDFLARED_LOG="$WORKDIR/cloudflared.log"
echo "[cloudflared] starting temporary tunnel..."
# 使用 --url 启动 quick tunnel（会在输出中显示 trycloudflare 的域名）
nohup "$CLOUDFLARED_BIN" tunnel --url "http://localhost:$PORT" --no-autoupdate > "$CLOUDFLARED_LOG" 2>&1 &

# 等待并从日志中提取 trycloudflare 域名（最多等待 60 秒）
TUNNEL_DOMAIN=""
WAIT2=0 MAX2=60
while [ $WAIT2 -lt $MAX2 ]; do
    if [ -f "$CLOUDFLARED_LOG" ]; then
        # 匹配形如 https://xxxx.trycloudflare.com
        TUNNEL_DOMAIN=$(grep -oE "https?://[A-Za-z0-9.-]+\\.trycloudflare\\.com" "$CLOUDFLARED_LOG" | head -n1 | sed -E 's|https?://||')
        if [ -n "$TUNNEL_DOMAIN" ]; then
            break
        fi
    fi
    sleep 1
    WAIT2=$((WAIT2 + 1))
done

if [ -n "$TUNNEL_DOMAIN" ]; then
    echo "[cloudflared] extracted tunnel domain: $TUNNEL_DOMAIN"
else
    echo "[cloudflared] 隧道域名提取失败，请检查 $CLOUDFLARED_LOG 手动确认域名。"
fi

# ---------------------------
# 构建 VLESS 和 Hysteria 链接
# ---------------------------
ENC_PATH=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$WS_PATH")
ENC_PWD=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$HY2_PASSWORD")

# VLESS 链接的 host/sni/域名使用临时隧道域名（优先），回退为容器 DOMAIN
if [ -n "$TUNNEL_DOMAIN" ]; then
    V_HOST="$TUNNEL_DOMAIN"
else
    V_HOST="$DOMAIN"
fi

VLESS_URL="vless://$UUID@$V_HOST:443?encryption=none&security=tls&type=ws&host=$V_HOST&path=${ENC_PATH}&sni=$V_HOST#lunes-ws-tls"
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
