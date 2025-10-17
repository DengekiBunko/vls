#!/usr/bin/env sh

# 严格模式：遇到错误即退出
set -eu

# ---------------------------
# 配置变量
# ---------------------------
DOMAIN="${DOMAIN:-node68.lunes.host}" # 虽然不用，但保留以防其他地方依赖
PORT="${PORT:-10008}"
UUID="${UUID:-2584b733-2b32-4036-8e26-df7b984f7f9e}"
HY2_PASSWORD="${HY2_PASSWORD:-vevc.HY2.Password}"
WS_PATH="${WS_PATH:-/wspath}"
TUNNEL_NAME="${TUNNEL_NAME:-mytunnel}" # 不再使用命名隧道，但保留变量
WORKDIR="${WORKDIR:-/home/container}"

# 其他小变量
SLEEP=${SLEEP:-5}

# ---------------------------
# 下载 app.js 和 package.json
# ---------------------------
echo "[node] downloading app.js and package.json ..."
# 确保使用您最新版本的 app.js
curl -sSL -o "$WORKDIR/app.js" https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/app.js || true
curl -sSL -o "$WORKDIR/package.json" https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/package.json || true

# ---------------------------
# Xray (xy) VLESS+WS 配置
# ---------------------------
mkdir -p "$WORKDIR/xy"
cd "$WORKDIR/xy" || exit 1

echo "[Xray] downloading and installing Xray core..."
XRAY_ZIP="Xray-linux-64.zip"
XRAY_BIN_NAME="xy" # 目标文件名

# 下载文件 (略去下载检查和解压逻辑，假设这些在您的环境中仍然工作)
curl -fsSL -o "$XRAY_ZIP" "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip" || { echo "[Xray ERROR] Failed to download $XRAY_ZIP"; exit 1; }

if ! command -v unzip >/dev/null 2>&1; then
    echo "[Xray ERROR] unzip command not found."
    exit 1
fi

unzip -o "$XRAY_ZIP"
rm -f "$XRAY_ZIP"

XRAY_CANDIDATE="$(find . -type f \( -iname 'xray' -o -iname 'xray*' -o -iname 'Xray' -o -iname 'Xray*' \) -perm /111 2>/dev/null | head -n1 || true)"
if [ -z "$XRAY_CANDIDATE" ]; then
    XRAY_CANDIDATE="$(find . -type f -iname 'xray*' 2>/dev/null | head -n1 || true)"
    if [ -n "$XRAY_CANDIDATE" ]; then chmod +x "$XRAY_CANDIDATE" || true; fi
fi

if [ -z "$XRAY_CANDIDATE" ]; then
    echo "[Xray ERROR] Xray binary not found after extraction."
    exit 1
fi

mv -f "$XRAY_CANDIDATE" "$XRAY_BIN_NAME"
chmod +x "$XRAY_BIN_NAME"
echo "[Xray] installed -> $XRAY_BIN_NAME"

# 生成 Xray 配置（接收非 TLS 的 WS 流量）
cat > config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "$UUID", "email": "lunes-ws-tls" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": { "path": "$WS_PATH" }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom" }
  ]
}
EOF

# ---------------------------
# Hysteria2 (h2) 配置 (保持不变)
# ---------------------------
mkdir -p "$WORKDIR/h2"
cd "$WORKDIR/h2" || exit 1
echo "[h2] downloading hysteria binary and config..."
curl -fsSL -o h2 "https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.2/hysteria-linux-amd64" || { echo "[h2 ERROR] failed to download hysteria"; exit 1; }
curl -fsSL -o config.yaml https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/hysteria-config.yaml || true

# Hysteria2 仍需自签证书
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout key.pem -out cert.pem -subj "/CN=$DOMAIN" || true
chmod +x h2 || true
# 替换端口与密码占位
if [ -f config.yaml ]; then
  sed -i "s/10008/$PORT/g" config.yaml || true
  sed -i "s/HY2_PASSWORD/$HY2_PASSWORD/g" config.yaml || true
fi

# URL 编码函数
url_encode() {
  arg="$1"
  if command -v node >/dev/null 2>&1; then
    node -e "console.log(encodeURIComponent(process.argv[1]))" "$arg"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - <<PY
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1]))
PY
  else
    # 最后回退
    echo "$arg" | sed -e 's/ /%20/g' -e 's/@/%40/g' -e 's/:/%3A/g' -e 's/\\//%2F/g'
  fi
}

encodedHy2Pwd="$(url_encode "$HY2_PASSWORD")"
hy2Url="hysteria2://$encodedHy2Pwd@$DOMAIN:$PORT?insecure=1#lunes-hy2"
echo "$hy2Url" >> "$WORKDIR/node.txt"

# ---------------------------
# Cloudflare Tunnel 交互式登录 (仅保留登录，不创建命名隧道)
# ---------------------------
CLOUDFLARED_BIN="$WORKDIR/cloudflared"
CLOUDFLARED_DIR="$WORKDIR/.cloudflared"
mkdir -p "$CLOUDFLARED_DIR"

if [ ! -x "$CLOUDFLARED_BIN" ]; then
    echo "[cloudflared] downloading cloudflared ..."
    curl -fsSL -o "$CLOUDFLARED_BIN" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" || { echo "[cloudflared ERROR] download failed"; }
    chmod +x "$CLOUDFLARED_BIN" || true
fi

# **重要：清除旧的命名隧道配置，以防干扰**
echo "[cloudflared] cleaning up old named tunnel configurations..."
rm -f "$CLOUDFLARED_DIR"/*.json || true
rm -f "$CLOUDFLARED_DIR"/config.yml || true

echo "-------- Cloudflared interactive login --------"
set +e
"$CLOUDFLARED_BIN" login
set -e

WAIT=0
MAX=300
CERT=""
while [ $WAIT -lt $MAX ]; do
    if [ -f "$CLOUDFLARED_DIR/cert.pem" ]; then
        CERT="$CLOUDFLARED_DIR/cert.pem"
        break
    fi
    echo "[cloudflared] waiting for cert.pem $WAIT/$MAX"
    sleep "$SLEEP"
    WAIT=$((WAIT + $SLEEP))
done

if [ -z "$CERT" ]; then
    echo "[cloudflared] cert.pem not found. 请放置 cert.pem 到 $CLOUDFLARED_DIR 或手动 login"
else
    echo "[cloudflared] login done. Ready to run ephemeral tunnel."
fi


# ---------------------------
# 构建 VLESS 和 HY2 链接 (⚠️ 注意：VLESS 链接中的域名将是错误的，需要手动替换)
# ---------------------------
ENC_PATH="$(url_encode "$WS_PATH")"
ENC_PWD="$(url_encode "$HY2_PASSWORD")"

# VLESS-WS 链接仍然使用 443 端口，但域名是占位符（需要在启动后手动替换为 *.trycloudflare.com）
VLESS_URL="vless://$UUID@EPHEMERAL_DOMAIN:443?encryption=none&security=tls&type=ws&host=EPHEMERAL_DOMAIN&path=${ENC_PATH}&sni=EPHEMERAL_DOMAIN#lunes-ws-tls"

# HY2 使用 $PORT 端口 (直连)
HY2_URL="hysteria2://$ENC_PWD@$DOMAIN:$PORT?insecure=1#lunes-hy2"

echo "$VLESS_URL" > "$WORKDIR/node.txt"
echo "$HY2_URL" >> "$WORKDIR/node.txt"

# ---------------------------
# 输出信息
# ---------------------------
echo "============================================================"
echo "🚀 VLESS WS+TLS (Ephemeral) & HY2 Node Info"
echo "--- VLESS (Cloudflare Ephemeral 443) ---"
echo "$VLESS_URL"
echo "⚠️ **重要提示:** VLESS 链接中的 EPHEMERAL_DOMAIN 必须在 cloudflared 启动后，手动替换为 *.trycloudflare.com 的临时域名。"
echo "--- HY2 (Direct Connection $PORT) ---"
echo "$HY2_URL"
echo "============================================================"
echo "✅ install.sh finished. You can start the server with: node $WORKDIR/app.js"
