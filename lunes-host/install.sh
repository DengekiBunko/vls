#!/usr/bin/env sh

DOMAIN="${DOMAIN:-node68.lunes.host}"
PORT="${PORT:-10008}"
UUID="${UUID:-2584b733-9095-4bec-a7d5-62b473540f7a}"
HY2_PASSWORD="${HY2_PASSWORD:-vevc.HY2.Password}"
WS_PATH="${WS_PATH:-/wspath}" # 新增 WebSocket 路径变量

# 下载 app.js 和 package.json (不变)
curl -sSL -o app.js https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/app.js
curl -sSL -o package.json https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/package.json

# --- Xray (xy) VLESS+WS+TLS 配置 ---
mkdir -p /home/container/xy
cd /home/container/xy

# 下载和解压 Xray (不变)
curl -sSL -o Xray-linux-64.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
unzip Xray-linux-64.zip
rm Xray-linux-64.zip
mv xray xy
chmod +x xy

# 下载新的 xray-config.json (假设您已将上面的配置保存到某个 URL)
# 或者，我们可以直接在这里创建它
cat > config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": 10008,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "YOUR_UUID",
            "email": "lunes-ws-tls"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "/home/container/xy/cert.pem",
              "keyFile": "/home/container/xy/key.pem"
            }
          ]
        },
        "wsSettings": {
          "path": "YOUR_WS_PATH"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF

# 生成自签名 TLS 证书
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout key.pem -out cert.pem -subj "/CN=$DOMAIN"

# 替换配置文件中的占位符
sed -i "s/10008/$PORT/g" config.json
sed -i "s/YOUR_UUID/$UUID/g" config.json
# 注意 sed 中路径分隔符的处理
sed -i "s|YOUR_WS_PATH|$WS_PATH|g" config.json

# 构建新的 VLESS URL
vlessUrl="vless://$UUID@$DOMAIN:$PORT?encryption=none&security=tls&type=ws&host=$DOMAIN&path=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$WS_PATH")&sni=$DOMAIN#lunes-ws-tls"
echo $vlessUrl > /home/container/node.txt

# --- Hysteria2 (h2) 配置 (不变) ---
mkdir -p /home/container/h2
cd /home/container/h2
curl -sSL -o h2 https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.2/hysteria-linux-amd64
curl -sSL -o config.yaml https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/hysteria-config.yaml
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout key.pem -out cert.pem -subj "/CN=$DOMAIN"
chmod +x h2
sed -i "s/10008/$PORT/g" config.yaml
sed -i "s/HY2_PASSWORD/$HY2_PASSWORD/g" config.yaml
encodedHy2Pwd=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$HY2_PASSWORD")
hy2Url="hysteria2://$encodedHy2Pwd@$DOMAIN:$PORT?insecure=1#lunes-hy2"
echo $hy2Url >> /home/container/node.txt

# --- 输出最终信息 ---
echo "============================================================"
echo "🚀 VLESS WS+TLS & HY2 Node Info"
echo "------------------------------------------------------------"
echo "$vlessUrl"
echo "$hy2Url"
echo "============================================================"