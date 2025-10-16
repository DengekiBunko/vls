#!/usr/bin/env sh
set -eu

# ---------- 配置（可通过 Pterodactyl 面板的 Environment 注入） ----------
DOMAIN="${DOMAIN:-node68.lunes.host}"
PORT="${PORT:-10008}"
UUID="${UUID:-2584b733-9095-4bec-a7d5-62b473540f7a}"
HY2_PASSWORD="${HY2_PASSWORD:-vevc.HY2.Password}"
WS_PATH="${WS_PATH:-/wspath}"
CFTUNNEL_TOKEN="${CFTUNNEL_TOKEN:-}"  # 可选，若要用固定隧道请在面板环境变量填写

# ---------- 工作目录 ----------
cd /home/container || exit 1
mkdir -p /home/container/xy /home/container/h2

# ---------- 下载 app.js 和 package.json（如果你希望使用 node 守护） ----------
# 如果你不想覆盖现有 app.js/package.json，可把这两行删掉
curl -sSL -o /home/container/app.js https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/app.js || true
curl -sSL -o /home/container/package.json https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/package.json || true

# ---------- Xray (xy) 安装与 config ----------
cd /home/container/xy
echo "[start.sh] Downloading Xray..."
curl -sSL -o Xray-linux-64.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip" || true
if command -v unzip >/dev/null 2>&1; then
  unzip -o Xray-linux-64.zip || true
  rm -f Xray-linux-64.zip
fi
# 移动二进制到 xy（包内二进制名可能为 xray/ Xray）
if [ -f xray ]; then mv -f xray xy || true; fi
if [ -f Xray ]; then mv -f Xray xy || true; fi
chmod +x /home/container/xy/xy || true

# 写入 Xray config（这里 origin 使用 TLS on origin — 如果你通过 Cloudflare edge 提供 TLS，建议改为 security: "none"）
cat > /home/container/xy/config.json <<'EOF'
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

# 生成自签 TLS 证书（Xray origin）
# NOTE: 如果你使用 Cloudflare edge TLS（让 edge 终止 TLS），最好把 streamSettings.security 改为 "none" 并不要生成 origin 证书。
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout /home/container/xy/key.pem -out /home/container/xy/cert.pem -subj "/CN=$DOMAIN" || true
chmod 600 /home/container/xy/key.pem /home/container/xy/cert.pem || true

# 替换占位符
sed -i "s/10008/$PORT/g" /home/container/xy/config.json
sed -i "s/YOUR_UUID/$UUID/g" /home/container/xy/config.json
case "$WS_PATH" in
  /*) ;;
  *) WS_PATH="/$WS_PATH" ;;
esac
sed -i "s|YOUR_WS_PATH|$WS_PATH|g" /home/container/xy/config.json

# ---------- Hysteria2 (h2) 安装与 config ----------
cd /home/container/h2
echo "[start.sh] Downloading Hysteria..."
curl -sSL -o h2 "https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.2/hysteria-linux-amd64" || true
chmod +x /home/container/h2/h2 || true

# 尝试下载示例 config，否则写入一个最小 config（指向 /home/container/h2/cert.pem）
if ! curl -sSL -o /home/container/h2/config.yaml https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/hysteria-config.yaml; then
cat > /home/container/h2/config.yaml <<EOF
listen: :$PORT
cert: /home/container/h2/cert.pem
key: /home/container/h2/key.pem
obfs: none
auth:
  - type: password
    password: "$HY2_PASSWORD"
EOF
fi

# 生成 Hysteria2 自签证书（如果不存在）
if [ ! -f /home/container/h2/cert.pem ] || [ ! -f /home/container/h2/key.pem ]; then
  echo "[start.sh] Generating self-signed cert for hysteria2..."
  openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout /home/container/h2/key.pem -out /home/container/h2/cert.pem -subj "/CN=$DOMAIN" || true
  chmod 600 /home/container/h2/key.pem /home/container/h2/cert.pem || true
fi

# 替换 h2 config 占位
sed -i "s/10008/$PORT/g" /home/container/h2/config.yaml || true
sed -i "s/HY2_PASSWORD/$HY2_PASSWORD/g" /home/container/h2/config.yaml || true

# ---------- cloudflared 二进制（如需固定隧道可启动） ----------
cd /home/container
echo "[start.sh] Downloading cloudflared binary (linux-amd64)..."
curl -L -o /home/container/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 || true
chmod +x /home/container/cloudflared || true
if [ -x /home/container/cloudflared ]; then /home/container/cloudflared --version || true; fi

# ---------- 生成 node.txt（连接信息） ----------
encoded_path=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$WS_PATH" 2>/dev/null || echo "%2Fwspath")
vlessUrl="vless://$UUID@$DOMAIN:$PORT?encryption=none&security=tls&type=ws&host=$DOMAIN&path=$encoded_path&sni=$DOMAIN#lunes-ws-tls"
echo "$vlessUrl" > /home/container/node.txt

encodedHy2Pwd=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$HY2_PASSWORD" 2>/dev/null || echo "vevc.HY2.Password")
hy2Url="hysteria2://$encodedHy2Pwd@$DOMAIN:$PORT?insecure=1#lunes-hy2"
echo "$hy2Url" >> /home/container/node.txt

echo "============================================================"
echo "Setup finished. Now launching processes (xy + h2 + cloudflared if token present)."
echo "Node links: /home/container/node.txt"
echo "============================================================"

# ---------- 启动并由 node.js app.js/或直接运行二进制（用你喜欢的方式） ----------
# 如果你使用 app.js 来守护进程，确保 app.js 在 /home/container 下
# 我使用 node app.js 作为守护入口（app.js 会重启子进程）
if [ -f /home/container/app.js ]; then
  # 通过 exec 替换当前 shell 以确保容器主进程为 node（可被 Pterodactyl 管理）
  exec node /home/container/app.js
else
  # 如果没有 app.js，直接前台运行 xy 和 h2（简单方式）
  # 使用 sh -c 以便两个进程同时运行不会阻塞；但推荐使用 app.js 或 supervisord
  /home/container/xy/xy -c /home/container/xy/config.json &
  /home/container/h2/h2 server -c /home/container/h2/config.yaml &
  if [ -n "$CFTUNNEL_TOKEN" ]; then
    /home/container/cloudflared tunnel run --token "$CFTUNNEL_TOKEN" &
  fi
  # 等待子进程（保持容器不退出）
  wait
fi
