#!/usr/bin/env sh

set -eu



# ---------------------------

# 配置变量

# ---------------------------

DOMAIN="${DOMAIN:-node68.lunes.host}"

PORT="${PORT:-10008}"

UUID="${UUID:-2584b733-2b32-4036-8e26-df7b984f7f9e}"

HY2_PASSWORD="${HY2_PASSWORD:-vevc.HY2.Password}"

WS_PATH="${WS_PATH:-/wspath}"

# 强烈建议使用一个不易冲突的 TUNNEL_NAME，例如使用前缀
TUNNEL_NAME="${TUNNEL_NAME:-lunes-tunnel}" 

WORKDIR="${WORKDIR:-/home/container}"



# ---------------------------

# 下载 app.js 和 package.json

# ---------------------------

echo "[node] downloading app.js and package.json ..."

curl -sSL -o "$WORKDIR/app.js" https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/app.js

curl -sSL -o "$WORKDIR/package.json" https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/package.json



# ---------------------------

# Xray (xy) VLESS+WS+TLS 配置

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



# 确保在正确的工作目录创建证书，或使用完整路径
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout key.pem -out cert.pem -subj "/CN=$DOMAIN"



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

# Hysteria2 (h2) 配置

# ---------------------------

mkdir -p "$WORKDIR/h2"
cd "$WORKDIR/h2"
curl -sSL -o h2 https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.2/hysteria-linux-amd64
curl -sSL -o config.yaml https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/hysteria-config.yaml
# 确保在正确的工作目录创建证书，或使用完整路径
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout key.pem -out cert.pem -subj "/CN=$DOMAIN"
chmod +x h2
sed -i "s/10008/$PORT/g" config.yaml
sed -i "s/HY2_PASSWORD/$HY2_PASSWORD/g" config.yaml
# 这里的 node 命令执行可能在某些极简环境中失败，但暂时保留
encodedHy2Pwd=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$HY2_PASSWORD")
hy2Url="hysteria2://$encodedHy2Pwd@$DOMAIN:$PORT?insecure=1#lunes-hy2"
echo "$hy2Url" >> "$WORKDIR/node.txt"



# ---------------------------

# Cloudflare Tunnel 交互式登录 + tunnel 创建和启动

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

# 必须启用错误检查 (set -e) 来捕获登录失败，但登录是一个交互式过程，因此保留 set +e 在这之前

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

    echo "[cloudflared] found cert.pem, creating and running tunnel '$TUNNEL_NAME'..."

    # 1. 尝试创建隧道。如果隧道已存在，此命令可能会失败（但 Cloudflared 会自动处理）

    # 为了防止已存在隧道导致脚本退出，我们仍然使用 || true，但会检查凭证文件是否存在。

    "$CLOUDFLARED_BIN" tunnel create "$TUNNEL_NAME" --credentials-file "$CLOUDFLARED_DIR/$TUNNEL_NAME.json" || echo "Tunnel '$TUNNEL_NAME' might already exist or creation failed."

    

    # 2. 尝试配置 DNS 路由

    # --overwrite-dns 选项可以确保旧的 DNS 记录被覆盖。

    "$CLOUDFLARED_BIN" tunnel route dns "$TUNNEL_NAME" "$DOMAIN" --overwrite-dns 

    

    # 3. 创建 Tunnel 的配置文件 config.yml

    cat > "$CLOUDFLARED_DIR/config.yml" <<CONFIG

tunnel: $TUNNEL_NAME

credentials-file: $CLOUDFLARED_DIR/$TUNNEL_NAME.json

originRequest:

  noTLSVerify: true

ingress:

  - hostname: $DOMAIN

    service: http://localhost:$PORT

  - service: http_status:404

CONFIG



    # 4. 启动 Cloudflare Tunnel 在后台运行

    echo "[cloudflared] starting tunnel '$TUNNEL_NAME' in background..."

    "$CLOUDFLARED_BIN" tunnel run --config "$CLOUDFLARED_DIR/config.yml" "$TUNNEL_NAME" &

    # 给 tunnel 几秒钟启动时间

    sleep 5

    echo "[cloudflared] initialization done."

fi



# ---------------------------

# 构建 VLESS 和 HY2 链接

# ---------------------------

# 注意：VLESS 和 HY2 链接中的端口已固定为 443，这是 Cloudflare 隧道默认的出口端口。

ENC_PATH=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$WS_PATH")

ENC_PWD=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$HY2_PASSWORD")

# 确保链接中使用 $DOMAIN 作为主机名

VLESS_URL="vless://$UUID@$DOMAIN:443?encryption=none&security=tls&type=ws&host=$DOMAIN&path=${ENC_PATH}&sni=$DOMAIN#lunes-ws-tls"

HY2_URL="hysteria2://$ENC_PWD@$DOMAIN:443?insecure=1#lunes-hy2" # Hysteria2 不走 Cloudflare Tunnel，但保留 443 端口便于穿透



# 覆盖之前的 node.txt

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
