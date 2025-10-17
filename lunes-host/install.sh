#!/usr/bin/env bash
set -eu

# ---------------------------
# 环境变量（你部署命令传入）
# ---------------------------
DOMAIN="${DOMAIN:-node24.lunes.host}"
PORT="${PORT:-3460}"
UUID="${UUID:-9bdc7c19-2b32-4036-8e26-df7b984f7f9e}"
HY2_PASSWORD="${HY2_PASSWORD:-jvu2JldmXk5pB1Xz}"

BASE_DIR="/home/container"
XRAY_DIR="$BASE_DIR/xy"
HY2_DIR="$BASE_DIR/hy2"
APP_FILE="$BASE_DIR/app.js"

mkdir -p "$XRAY_DIR" "$HY2_DIR"

echo "[install] Installing dependencies..."
apk add --no-cache curl unzip >/dev/null 2>&1 || true

# ---------------------------
# 下载 Xray
# ---------------------------
echo "[install] Downloading Xray..."
curl -L -o /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
unzip -o /tmp/xray.zip -d /tmp/xray
mv /tmp/xray/xray "$XRAY_DIR/xy"
chmod +x "$XRAY_DIR/xy"

# ---------------------------
# 下载 Cloudflared
# ---------------------------
echo "[install] Downloading cloudflared..."
curl -L -o /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x /usr/local/bin/cloudflared

# ---------------------------
# 创建 Cloudflare 临时隧道
# ---------------------------
echo "[install] Creating temporary tunnel..."
CF_LOG=$(cloudflared tunnel --url http://localhost:8080 2>&1 | tee /tmp/cf.log | tail -n 10)
ARGO_DOMAIN=$(grep -oE 'https://[-a-z0-9]+\.trycloudflare\.com' /tmp/cf.log | head -n 1 | sed 's#https://##')

if [ -z "$ARGO_DOMAIN" ]; then
  echo "[error] Failed to detect Argo tunnel domain!"
  cat /tmp/cf.log
  exit 1
fi

echo "[install] Temporary tunnel domain: $ARGO_DOMAIN"

# ---------------------------
# 生成 Xray 配置文件
# ---------------------------
cat > "$XRAY_DIR/config.json" <<EOF
{
  "inbounds": [
    {
      "port": 8080,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "$UUID", "flow": "none" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/websocket" }
      }
    }
  ],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

# ---------------------------
# 生成 Hy2 配置文件
# ---------------------------
cat > "$HY2_DIR/config.yaml" <<EOF
listen: 0.0.0.0:$PORT
password: "$HY2_PASSWORD"
tls:
  sni: "$DOMAIN"
  alpn: ["h3"]
  cert: "/etc/ssl/certs/ssl-cert-snakeoil.pem"
  key: "/etc/ssl/private/ssl-cert-snakeoil.key"
EOF

# ---------------------------
# 生成 app.js
# ---------------------------
cat > "$APP_FILE" <<EOF
const { spawn } = require("child_process");

// 定义运行程序
const apps = [
  {
    name: "xray",
    binaryPath: "/home/container/xy/xy",
    args: ["-c", "/home/container/xy/config.json"]
  },
  {
    name: "hy2",
    binaryPath: "/usr/local/bin/hysteria",
    args: ["server", "-c", "/home/container/hy2/config.yaml"]
  }
];

// 启动并保持存活
function run(app) {
  console.log("[run]", app.name);
  const proc = spawn(app.binaryPath, app.args, { stdio: "inherit" });
  proc.on("exit", (code) => {
    console.log(\`\${app.name} exited with code \${code}\`);
    setTimeout(() => run(app), 3000);
  });
}

apps.forEach(run);
EOF

chmod +x "$XRAY_DIR/xy"

# ---------------------------
# 输出节点信息
# ---------------------------
echo ""
echo "====================== 节点信息 ======================"
echo "▶ Hy2:"
echo "  地址: $DOMAIN"
echo "  端口: $PORT"
echo "  密码: $HY2_PASSWORD"
echo "  协议: h3, tls"
echo ""
echo "▶ VLESS-WS (Cloudflare 临时隧道):"
echo "  地址: $ARGO_DOMAIN"
echo "  端口: 443"
echo "  UUID: $UUID"
echo "  传输: ws"
echo "  路径: /websocket"
echo "  SNI: $ARGO_DOMAIN"
echo "======================================================"
