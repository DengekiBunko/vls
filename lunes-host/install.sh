#!/usr/bin/env sh

DOMAIN="${DOMAIN:-node24.lunes.host}"
PORT="${PORT:-3460}"
UUID="${UUID:-your-uuid}"
HY2_PASSWORD="${HY2_PASSWORD:-your-hy2-password}"
WS_PATH="${WS_PATH:-/wspath}"
CFTUNNEL_TOKEN="${CFTUNNEL_TOKEN:-your-cf-token}"
PUBLIC_HOSTNAME="${PUBLIC_HOSTNAME:-your-cf-subdomain}" # 这里替换成你 Cloudflare Tunnel 的 Hostname

# 下载 app.js 和 package.json
curl -sSL -o app.js https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/app.js
curl -sSL -o package.json https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/package.json

# --- Xray ---
mkdir -p /home/container/xy
cd /home/container/xy

curl -sSL -o Xray-linux-64.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
unzip Xray-linux-64.zip
rm Xray-linux-64.zip
mv xray xy
chmod +x xy

# 创建 Xray 配置
cat > config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [{"id":"$UUID","email":"lunes-ws-tls"}],
        "decryption":"none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            { "certificateFile": "/home/container/xy/cert.pem", "keyFile": "/home/container/xy/key.pem" }
          ]
        },
        "wsSettings": { "path": "$WS_PATH" }
      }
    }
  ],
  "outbounds":[{"protocol":"freedom"}]
}
EOF

# 自签 TLS 证书
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout key.pem -out cert.pem -subj "/CN=$PUBLIC_HOSTNAME"

# --- Hysteria2 ---
mkdir -p /home/container/h2
cd /home/container/h2
curl -sSL -o h2 https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.2/hysteria-linux-amd64
chmod +x h2

# 创建 Hysteria2 配置（新版结构）
cat > config.yaml <<EOF
listen: :443
tls:
  cert: /home/container/h2/cert.pem
  key: /home/container/h2/key.pem
auth:
  type: password
  password: $HY2_PASSWORD
masquerade:
  type: proxy
  proxy:
    url: https://$PUBLIC_HOSTNAME
EOF

# 生成 TLS 证书
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout key.pem -out cert.pem -subj "/CN=$PUBLIC_HOSTNAME"

# --- 输出节点信息 ---
vlessUrl="vless://$UUID@$PUBLIC_HOSTNAME:443?encryption=none&security=tls&type=ws&host=$PUBLIC_HOSTNAME&path=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$WS_PATH")&sni=$PUBLIC_HOSTNAME#lunes-ws-tls"
encodedHy2Pwd=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$HY2_PASSWORD")
hy2Url="hysteria2://$encodedHy2Pwd@$PUBLIC_HOSTNAME:443?insecure=1#lunes-hy2"

echo $vlessUrl > /home/container/node.txt
echo $hy2Url >> /home/container/node.txt

echo "============================================================"
echo "🚀 VLESS WS+TLS & HY2 Node Info"
echo "$vlessUrl"
echo "$hy2Url"
echo "============================================================"
