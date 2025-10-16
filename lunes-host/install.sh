#!/usr/bin/env sh

# === 配置变量 ===
DOMAIN="${DOMAIN:-luneshost01.xdzw.dpdns.org}"
PORT="${PORT:-3460}"
UUID="${UUID:-your-uuid}"
HY2_PASSWORD="${HY2_PASSWORD:-your-hy2-password}"
WS_PATH="${WS_PATH:-/wspath}"
TUNNEL_NAME="${TUNNEL_NAME:-lunes-tunnel}"
CLOUDFLARED_DIR="/home/container/.cloudflared"

# === 创建工作目录 ===
mkdir -p /home/container/xy /home/container/h2 $CLOUDFLARED_DIR
cd /home/container

# === 安装 Xray ===
curl -sSL -o Xray-linux-64.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
unzip -o Xray-linux-64.zip
rm Xray-linux-64.zip
mv xray xy/xy
chmod +x xy/xy

# 创建 Xray 配置
cat > xy/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": { "clients": [{"id":"$UUID"}], "decryption":"none" },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "certificates": [{"certificateFile": "xy/cert.pem","keyFile": "xy/key.pem"}]
        },
        "wsSettings": { "path": "$WS_PATH" }
      }
    }
  ],
  "outbounds":[{"protocol":"freedom"}]
}
EOF

openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout xy/key.pem -out xy/cert.pem -subj "/CN=$DOMAIN"

# === 安装 Hysteria2 ===
cd /home/container/h2
curl -sSL -o h2 https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.4/hysteria-linux-amd64
chmod +x h2
cat > config.yaml <<EOF
listen: 0.0.0.0:$PORT
cert: h2-cert.pem
key: h2-key.pem
obfs:
  type: password
  password: $HY2_PASSWORD
EOF
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout h2-key.pem -out h2-cert.pem -subj "/CN=$DOMAIN"

# === 安装 Cloudflared ===
cd /home/container
curl -sSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o cloudflared
chmod +x cloudflared

# === cloudflared 登录 & 隧道 ===
echo "请在浏览器打开下列 URL 完成 Cloudflare 认证："
cloudflared login --origincert $CLOUDFLARED_DIR/cert.pem

# 等待用户完成认证后创建隧道
cloudflared tunnel create $TUNNEL_NAME --credentials-file $CLOUDFLARED_DIR/$TUNNEL_NAME.json
cloudflared tunnel route dns $TUNNEL_NAME $DOMAIN
cloudflared tunnel run $TUNNEL_NAME --credentials-file $CLOUDFLARED_DIR/$TUNNEL_NAME.json &

# === 输出节点链接 ===
vlessUrl="vless://$UUID@$DOMAIN:$PORT?encryption=none&security=tls&type=ws&host=$DOMAIN&path=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$WS_PATH")&sni=$DOMAIN#lunes-ws-tls"
encodedHy2Pwd=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$HY2_PASSWORD")
hy2Url="hysteria2://$encodedHy2Pwd@$DOMAIN:$PORT?insecure=1#lunes-hy2"
echo "============================================================"
echo "🚀 VLESS WS+TLS & HY2 Node Info"
echo "$vlessUrl"
echo "$hy2Url"
echo "============================================================"
