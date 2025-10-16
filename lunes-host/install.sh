#!/usr/bin/env sh
set -e

# --- 用户环境变量 ---
DOMAIN="${DOMAIN:-example.com}"
PORT="${PORT:-3460}"
UUID="${UUID:-your-uuid}"
HY2_PASSWORD="${HY2_PASSWORD:-your-hy2-password}"
WS_PATH="${WS_PATH:-/wspath}"
TUNNEL_NAME="${TUNNEL_NAME:-mytunnel}"

# --- 工作目录 ---
WORKDIR="/home/container"
mkdir -p $WORKDIR
cd $WORKDIR

# =======================
# 1. 下载 Xray (VLESS WS+TLS)
# =======================
mkdir -p xy
cd xy
curl -sSL -o Xray-linux-64.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
unzip -o Xray-linux-64.zip
rm Xray-linux-64.zip
mv xray xy
chmod +x xy

# 生成自签名证书
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
  -keyout key.pem -out cert.pem -subj "/CN=$DOMAIN"

# 写入 VLESS 配置
cat > config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [{"id":"$UUID","email":"vless-ws-tls"}],
        "decryption":"none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            { "certificateFile": "$WORKDIR/xy/cert.pem", "keyFile": "$WORKDIR/xy/key.pem" }
          ]
        },
        "wsSettings": { "path": "$WS_PATH" }
      }
    }
  ],
  "outbounds":[{"protocol":"freedom"}]
}
EOF

cd $WORKDIR

# =======================
# 2. 下载 HY2 (Hysteria2)
# =======================
mkdir -p h2
cd h2
curl -sSL -o h2 https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.4/hysteria-linux-amd64
chmod +x h2

cat > config.yaml <<EOF
listen: 0.0.0.0:$PORT
cert: key.pem
key: cert.pem
obfs:
  type: password
  password: $HY2_PASSWORD
EOF

openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
  -keyout key.pem -out cert.pem -subj "/CN=$DOMAIN"

# =======================
# 3. 下载 cloudflared 并认证隧道
# =======================
cd $WORKDIR
curl -sSL -o cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x cloudflared
CLOUDFLARED_BIN="$WORKDIR/cloudflared"

# Cloudflare 隧道目录
CLOUDFLARED_DIR="$WORKDIR/.cloudflared"
mkdir -p $CLOUDFLARED_DIR

echo "请在浏览器打开下列 URL 完成 Cloudflare 认证："
$CLOUDFLARED_BIN login --origincert $CLOUDFLARED_DIR/cert.pem

# 等待用户完成浏览器认证后创建隧道
$CLOUDFLARED_BIN tunnel create $TUNNEL_NAME --credentials-file $CLOUDFLARED_DIR/$TUNNEL_NAME.json
$CLOUDFLARED_BIN tunnel route dns $TUNNEL_NAME $DOMAIN
$CLOUDFLARED_BIN tunnel run $TUNNEL_NAME --credentials-file $CLOUDFLARED_DIR/$TUNNEL_NAME.json &

# =======================
# 4. 生成节点链接
# =======================
vlessUrl="vless://$UUID@$DOMAIN:443?encryption=none&security=tls&type=ws&host=$DOMAIN&path=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$WS_PATH")&sni=$DOMAIN#vless-ws-tls"
encodedHy2Pwd=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$HY2_PASSWORD")
hy2Url="hysteria2://$encodedHy2Pwd@$DOMAIN:443?insecure=1#hy2"

echo "$vlessUrl" > $WORKDIR/node.txt
echo "$hy2Url" >> $WORKDIR/node.txt

echo "============================================================"
echo "🚀 VLESS WS+TLS & HY2 Node Info"
echo "$vlessUrl"
echo "$hy2Url"
echo "============================================================"
