#!/usr/bin/env sh
set -eu

# ---------------------------
# 1. 配置变量 (无需 TUNNEL_NAME)
# ---------------------------
WORKDIR="/home/container"
DOMAIN="${DOMAIN:-node24.lunes.host}"
PORT="${PORT:-3460}"
UUID="${UUID:-9bdc7c19-2b32-4036-8e26-df7b984f7f9e}"
HY2_PASSWORD="${HY2_PASSWORD:-jvu2JldmXk5pB1Xz}"
WS_PATH="${WS_PATH:-/wspath}"

# ---------------------------
# 2. 清理旧配置和下载 app.js/package.json (使用临时隧道专用的 app.js)
# ---------------------------
echo "[setup] cleaning up old configurations..."
CLOUDFLARED_DIR="$WORKDIR/.cloudflared"
rm -rf "$CLOUDFLARED_DIR" || true
mkdir -p "$CLOUDFLARED_DIR"

echo "[setup] downloading necessary files..."
# 确保这里下载的是你修改后的 app.js (使用临时隧道命令)
curl -sSL -o "$WORKDIR/app.js" https://raw.githubusercontent.com/DengekiBunko/vls/refs/heads/main/lunes-host/app-ephemeral.js || true
curl -sSL -o "$WORKDIR/package.json" https://raw.githubusercontent.com/DengekiBunko/vls/refs/heads/main/lunes-host/package.json || true


# ---------------------------
# 3. 下载 Xray/Hysteria2/Cloudflared
# ---------------------------
echo "[setup] downloading Xray/Hysteria2/Cloudflared binaries..."
# Xray (xy)
mkdir -p "$WORKDIR/xy" && cd "$WORKDIR/xy" && curl -fsSL "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip" -o Xray-linux-64.zip && unzip -o Xray-linux-64.zip && mv -f Xray-linux-64 "$WORKDIR/xy/xy" && chmod +x "$WORKDIR/xy/xy" && rm -f Xray-linux-64.zip

# Hysteria2 (h2)
mkdir -p "$WORKDIR/h2" && cd "$WORKDIR/h2" && curl -fsSL -o h2 "https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.2/hysteria-linux-amd64" && chmod +x h2

# Cloudflared
CLOUDFLARED_BIN="$WORKDIR/cloudflared"
curl -fsSL -o "$CLOUDFLARED_BIN" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" && chmod +x "$CLOUDFLARED_BIN"

# ---------------------------
# 4. 生成 Xray/Hysteria2 配置 (使用环境变量)
# ---------------------------
echo "[config] generating Xray config..."
cat > "$WORKDIR/xy/config.json" <<EOF
{"log": { "loglevel": "warning" },"inbounds": [{"port": $PORT,"protocol": "vless","settings": {"clients": [{"id": "$UUID", "email": "lunes-ws-tls"}],"decryption": "none"},"streamSettings": {"network": "ws","security": "none","wsSettings": {"path": "$WS_PATH"}}}]"outbounds": [ { "protocol": "freedom" } ]}
EOF

echo "[config] generating Hysteria2 config and certs..."
# Hysteria2 配置
curl -fsSL -o "$WORKDIR/h2/config.yaml" https://raw.githubusercontent.com/DengekiBunko/vls/refs/heads/main/lunes-host/hysteria-config.yaml
sed -i "s/10008/$PORT/g; s/HY2_PASSWORD/$HY2_PASSWORD/g" "$WORKDIR/h2/config.yaml"
# Hysteria2 证书
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout "$WORKDIR/h2/key.pem" -out "$WORKDIR/h2/cert.pem" -subj "/CN=$DOMAIN"

# ---------------------------
# 5. Cloudflared 交互式登录 (必须手动完成)
# ---------------------------
echo "============================================================"
echo "🚨 CLOUDFLARED 登录 (REQUIRED) 🚨"
echo "请在浏览器中完成登录，完成后关闭浏览器标签页。"
echo "============================================================"
set +e
"$CLOUDFLARED_BIN" login
set -e

if [ ! -f "$CLOUDFLARED_DIR/cert.pem" ]; then
    echo "============================================================"
    echo "⚠️ ERROR: cert.pem not found. 临时隧道无法启动！"
    echo "请检查 login 步骤是否完成。"
    echo "============================================================"
    exit 1
fi

echo "✅ install.sh (Ephemeral) finished."
