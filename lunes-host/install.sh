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
# Xray (xy) VLESS+WS 配置 (Cloudflared 终止 TLS)
# ---------------------------
mkdir -p "$WORKDIR/xy"
cd "$WORKDIR/xy" || exit 1

echo "[Xray] downloading and installing Xray core..."
XRAY_ZIP="Xray-linux-64.zip"
XRAY_BIN_NAME="xy" # 目标文件名

# 下载文件
curl -fsSL -o "$XRAY_ZIP" "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip" || { echo "[Xray ERROR] Failed to download $XRAY_ZIP"; exit 1; }

# 检查 unzip
if ! command -v unzip >/dev/null 2>&1; then
    echo "[Xray ERROR] unzip command not found. Please ensure 'unzip' is installed in the container environment."
    exit 1
fi

# 解压
unzip -o "$XRAY_ZIP" || { echo "[Xray ERROR] Failed to unzip $XRAY_ZIP"; exit 1; }
rm -f "$XRAY_ZIP"

# 查找可能的可执行二进制（支持子目录、不同大小写和带后缀名的情况）
XRAY_CANDIDATE="$(find . -type f \( -iname 'xray' -o -iname 'xray*' -o -iname 'Xray' -o -iname 'Xray*' \) -perm /111 2>/dev/null | head -n1 || true)"

# 如果找不到带执行权限的，退而求其次找任意匹配名的文件并尝试赋予执行权限
if [ -z "$XRAY_CANDIDATE" ]; then
    XRAY_CANDIDATE="$(find . -type f -iname 'xray*' 2>/dev/null | head -n1 || true)"
    if [ -n "$XRAY_CANDIDATE" ]; then
        chmod +x "$XRAY_CANDIDATE" || true
    fi
fi

if [ -z "$XRAY_CANDIDATE" ]; then
    echo "[Xray ERROR] Xray binary not found after extraction. Current directory listing:"
    ls -la
    echo "Hint: run 'unzip -l Xray-linux-64.zip' locally to inspect archive contents, and ensure you downloaded the correct arch for the container (check 'uname -m')."
    exit 1
fi

# 移动并命名为目标可执行文件
mv -f "$XRAY_CANDIDATE" "$XRAY_BIN_NAME"
chmod +x "$XRAY_BIN_NAME"
echo "[Xray] installed -> $XRAY_BIN_NAME (from $XRAY_CANDIDATE)"

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

# Hysteria2 仍需自签证书（若已有证书可跳过）
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout key.pem -out cert.pem -subj "/CN=$DOMAIN" || true
chmod +x h2 || true
# 替换端口与密码占位
if [ -f config.yaml ]; then
  sed -i "s/10008/$PORT/g" config.yaml || true
  sed -i "s/HY2_PASSWORD/$HY2_PASSWORD/g" config.yaml || true
fi

# URL 编码函数：优先使用 node，其次 python3，最后用简单替换（非严格）
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
    # 最后回退（非严格），将常见字符替换
    echo "$arg" | sed -e 's/ /%20/g' -e 's/@/%40/g' -e 's/:/%3A/g' -e 's/\\//%2F/g'
  fi
}

encodedHy2Pwd="$(url_encode "$HY2_PASSWORD")"
hy2Url="hysteria2://$encodedHy2Pwd@$DOMAIN:$PORT?insecure=1#lunes-hy2"
echo "$hy2Url" >> "$WORKDIR/node.txt"

# ---------------------------
# Cloudflare Tunnel 交互式登录 + tunnel 创建
# ---------------------------
CLOUDFLARED_BIN="$WORKDIR/cloudflared"
CLOUDFLARED_DIR="$WORKDIR/.cloudflared"
mkdir -p "$CLOUDFLARED_DIR"

if [ ! -x "$CLOUDFLARED_BIN" ]; then
    echo "[cloudflared] downloading cloudflared ..."
    curl -fsSL -o "$CLOUDFLARED_BIN" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" || { echo "[cloudflared ERROR] download failed"; }
    chmod +x "$CLOUDFLARED_BIN" || true
fi

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
    WAIT=$((WAIT + SLEEP))
done

if [ -z "$CERT" ]; then
    echo "[cloudflared] cert.pem not found. 请放置 cert.pem 到 $CLOUDFLARED_DIR 或手动 login"
else
    echo "[cloudflared] found cert.pem, creating tunnel (if not exists) and routing DNS ..."
    set +e
    CREATE_OUTPUT=$("$CLOUDFLARED_BIN" tunnel create "$TUNNEL_NAME" 2>&1)
    echo "$CREATE_OUTPUT"
    # 解析 Tunnel ID：尝试从 'Created tunnel <ID>' 或 JSON 输出中提取
    TUNNEL_ID="$(printf "%s\n" "$CREATE_OUTPUT" | grep -Eo 'Created tunnel [0-9a-fA-F-]+' | awk '{print $3}' || true)"
    if [ -z "$TUNNEL_ID" ]; then
        # 另一种可能输出： cloudflared 会输出 JSON 或 'id: <id>'
        TUNNEL_ID="$(printf "%s\n" "$CREATE_OUTPUT" | grep -Eo '[0-9a-fA-F-]{20,}' | head -n1 || true)"
    fi

    # 如果仍为空，尝试从 list 中查找
    if [ -z "$TUNNEL_ID" ]; then
        echo "[cloudflared] Tunnel create did not return ID; trying tunnel list..."
        TUNNEL_ID=$("$CLOUDFLARED_BIN" tunnel list 2>/dev/null | grep -w "$TUNNEL_NAME" | awk '{print $1,$2,$3,$4,$5}' | awk '{print $1}' | head -n 1 || true)
    fi

    "$CLOUDFLARED_BIN" tunnel route dns "$TUNNEL_NAME" "$DOMAIN" 2>&1 || true
    set -e

    # ---------------------------------
    # 生成 config.yml：优先使用 TUNNEL_ID（若有），否则用 TUNNEL_NAME
    # ---------------------------------
    CFG_TUNNEL_ID="${TUNNEL_ID:-$TUNNEL_NAME}"
    CREDENTIALS_FILE="$CLOUDFLARED_DIR/${TUNNEL_ID}.json"
    echo "[cloudflared] generating config.yml (tunnel: $CFG_TUNNEL_ID)..."
    cat > "$CLOUDFLARED_DIR/config.yml" <<EOF
tunnel: $CFG_TUNNEL_ID
credentials-file: $CLOUDFLARED_DIR/$(basename "$CREDENTIALS_FILE")
ingress:
  - hostname: $DOMAIN
    service: http://localhost:$PORT
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF

    echo "[cloudflared] initialization done."
fi

# ---------------------------
# 构建 VLESS 和 HY2 链接
# ---------------------------
ENC_PATH="$(url_encode "$WS_PATH")"
ENC_PWD="$(url_encode "$HY2_PASSWORD")"

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
