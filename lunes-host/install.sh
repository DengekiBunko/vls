#!/usr/bin/env sh
set -eu

DOMAIN="${DOMAIN:-node68.lunes.host}"
PORT="${PORT:-10008}"
UUID="${UUID:-2584b733-9095-4bec-a7d5-62b473540f7a}"
HY2_PASSWORD="${HY2_PASSWORD:-vevc.HY2.Password}"
WS_PATH="${WS_PATH:-/wspath}"   # WebSocket path
CFTUNNEL_TOKEN="${CFTUNNEL_TOKEN:-}"  # Cloudflare Tunnel token (must be provided)

# --- basic files (from repo) ---
# 下载 app.js 和 package.json（使用你的 repo 原始地址）
curl -sSL -o app.js https://raw.githubusercontent.com/DengekiBunko/vls/refs/heads/main/lunes-host/app.js
curl -sSL -o package.json https://raw.githubusercontent.com/DengekiBunko/vls/refs/heads/main/lunes-host/package.json

# --- Xray (xy) VLESS+WS origin (plain WS, Cloudflare edge will do TLS) ---
mkdir -p /home/container/xy
cd /home/container/xy

# 下载 Xray 二进制并准备
curl -sSL -o Xray-linux-64.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
unzip -o Xray-linux-64.zip
rm -f Xray-linux-64.zip
# the binary inside is usually named xray
if [ -f xray ]; then
  mv -f xray xy
elif [ -f Xray ]; then
  mv -f Xray xy
fi
chmod +x xy || true

# 写入 origin 的 config.json（plain ws，security: none）
cat > /home/container/xy/config.json <<'EOF'
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": 10008,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "YOUR_UUID", "email": "lunes-ws-tls" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": { "path": "YOUR_WS_PATH" }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF

# 替换占位符（port / uuid / ws_path）
sed -i "s/10008/$PORT/g" /home/container/xy/config.json
sed -i "s/YOUR_UUID/$UUID/g" /home/container/xy/config.json
# 确保 path 以 / 开始
case "$WS_PATH" in
  /*) ;;
  *) WS_PATH="/$WS_PATH" ;;
esac
# 把 path 写成 /YOUR_WS_PATH（JSON 中 path 字段）
# 使用 | 分隔，避免 / 在 sed 中冲突
sed -i "s|YOUR_WS_PATH|$WS_PATH|g" /home/container/xy/config.json

# --- Hysteria2 (h2) ---
mkdir -p /home/container/h2
cd /home/container/h2
# 下载 hysteria 二进制
curl -sSL -o h2 https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.2/hysteria-linux-amd64 || true
chmod +x h2 || true
# 下载示例 config（若无网络可手写）
curl -sSL -o config.yaml https://raw.githubusercontent.com/DengekiBunko/vls/refs/heads/main/lunes-host/hysteria-config.yaml || true
# 替换端口与密码（如果下载到的 config 有占位）
sed -i "s/10008/$PORT/g" /home/container/h2/config.yaml || true
sed -i "s/HY2_PASSWORD/$HY2_PASSWORD/g" /home/container/h2/config.yaml || true

# --- cloudflared 安装（用于 Named Tunnel / run --token ） ---
mkdir -p /home/container
cd /home/container
echo "Downloading cloudflared..."
curl -L -o /home/container/cloudflared.tgz "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.tgz"
tar -xzf /home/container/cloudflared.tgz -C /home/container
chmod +x /home/container/cloudflared
rm -f /home/container/cloudflared.tgz

# --- write node info file (node.txt) ---
# vless URL - 客户端应使用 wss://<DOMAIN>:443 由 Cloudflare 提供 TLS; origin 是 plain WS behind cloudflared
encoded_path=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$WS_PATH")
vlessUrl="vless://$UUID@$DOMAIN:443?encryption=none&security=tls&type=ws&host=$DOMAIN&path=$encoded_path&sni=$DOMAIN#lunes-ws-tls"
echo "$vlessUrl" > /home/container/node.txt

# hysteria (hy2) url （保持原样）
encodedHy2Pwd=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$HY2_PASSWORD")
hy2Url="hysteria2://$encodedHy2Pwd@$DOMAIN:$PORT?insecure=1#lunes-hy2"
echo "$hy2Url" >> /home/container/node.txt

# --- cloudflared startup (using token) ---
if [ -z "$CFTUNNEL_TOKEN" ]; then
  echo "WARNING: CFTUNNEL_TOKEN not provided. cloudflared will not be auto-launched by app.js."
else
  echo "Cloudflared token provided; app.js will spawn cloudflared tunnel run --token <token>."
  # We don't run it here; app.js will spawn cloudflared so that node process supervises it.
fi

# --- finish: make sure working dir is /home/container and node files present ---
chmod +x /home/container/xy/xy || true
chmod +x /home/container/h2/h2 || true
cd /home/container

echo "============================================================"
echo "Setup complete. Files created under /home/container"
echo "node info: /home/container/node.txt"
echo "To start processes run: npm start  (or node app.js)"
echo "If you supplied CFTUNNEL_TOKEN, app.js will spawn cloudflared with that token."
echo "============================================================"
