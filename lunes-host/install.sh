#!/usr/bin/env sh
set -e

# 环境变量（部署时传入）
DOMAIN="${DOMAIN:-node68.lunes.host}"
PORT="${PORT:-3460}"
UUID="${UUID:-2584b733-9095-4bec-a7d5-62b473540f7a}"
HY2_PASSWORD="${HY2_PASSWORD:-vevc.HY2.Password}"
WS_PATH="${WS_PATH:-/ws}"
CFTUNNEL_TOKEN="${CFTUNNEL_TOKEN:-}"

echo "===== 🚀 Lunes Host 自部署启动 ====="
echo "Domain: $DOMAIN"
echo "Port: $PORT"
echo "UUID: $UUID"
echo "HY2 Password: $HY2_PASSWORD"
echo "CF Tunnel Token: ${CFTUNNEL_TOKEN:+已设置}"

mkdir -p /home/container

# -----------------------------------------------------
# 1️⃣ 下载 Cloudflared
# -----------------------------------------------------
cd /home/container
if [ ! -f "cloudflared" ]; then
  echo "[Cloudflared] 下载中..."
  curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.tgz | tar -xz
  chmod +x cloudflared
  rm -f cloudflared.tgz
fi

# -----------------------------------------------------
# 2️⃣ 下载并配置 Xray (VLESS + WS + TLS)
# -----------------------------------------------------
mkdir -p /home/container/xy
cd /home/container/xy

curl -sSL -o Xray-linux-64.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
unzip -o Xray-linux-64.zip
mv xray xy
chmod +x xy
rm -f Xray-linux-64.zip

# 写入配置
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
        "security": "tls",
        "tlsSettings": {
          "certificates": [{ "certificateFile": "/home/container/xy/cert.pem", "keyFile": "/home/container/xy/key.pem" }]
        },
        "wsSettings": { "path": "$WS_PATH" }
      }
    }
  ],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

# 生成证书
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
  -keyout /home/container/xy/key.pem \
  -out /home/container/xy/cert.pem \
  -subj "/CN=$DOMAIN"

# VLESS 链接
vlessUrl="vless://$UUID@$DOMAIN:$PORT?encryption=none&security=tls&type=ws&host=$DOMAIN&path=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$WS_PATH")&sni=$DOMAIN#lunes-ws-tls"

# -----------------------------------------------------
# 3️⃣ HY2 节点
# -----------------------------------------------------
mkdir -p /home/container/h2
cd /home/container/h2

curl -sSL -o h2 https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.4/hysteria-linux-amd64
chmod +x h2

cat > config.yaml <<EOF
listen: :$PORT
auth:
  type: password
  password: $HY2_PASSWORD
tls:
  cert: /home/container/h2/cert.pem
  key: /home/container/h2/key.pem
EOF

openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
  -keyout /home/container/h2/key.pem \
  -out /home/container/h2/cert.pem \
  -subj "/CN=$DOMAIN"

encodedHy2Pwd=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$HY2_PASSWORD")
hy2Url="hysteria2://$encodedHy2Pwd@$DOMAIN:$PORT?insecure=1#lunes-hy2"

# -----------------------------------------------------
# 4️⃣ 启动管理 app.js
# -----------------------------------------------------
cat > /home/container/app.js <<'EOF'
const { spawn } = require("child_process");

const processes = [
  { name: "xy", cmd: "/home/container/xy/xy", args: ["-c", "/home/container/xy/config.json"] },
  { name: "h2", cmd: "/home/container/h2/h2", args: ["server", "-c", "/home/container/h2/config.yaml"] },
  process.env.CFTUNNEL_TOKEN ? { name: "cloudflared", cmd: "/home/container/cloudflared", args: ["tunnel", "run", "--token", process.env.CFTUNNEL_TOKEN] } : null
].filter(Boolean);

for (const app of processes) {
  const proc = spawn(app.cmd, app.args, { stdio: "inherit" });
  proc.on("exit", (code) => {
    console.log(`[EXIT] ${app.name} exited with code: ${code}`);
    setTimeout(() => {
      console.log(`[RESTART] Restarting ${app.name}...`);
      spawn(app.cmd, app.args, { stdio: "inherit" });
    }, 2000);
  });
}
EOF

# -----------------------------------------------------
# 5️⃣ 输出节点信息
# -----------------------------------------------------
echo "============================================================"
echo "✅ VLESS + HY2 部署完成"
echo "------------------------------------------------------------"
echo "VLESS: $vlessUrl"
echo "HY2:   $hy2Url"
echo "============================================================"

echo "$vlessUrl" > /home/container/node.txt
echo "$hy2Url" >> /home/container/node.txt
