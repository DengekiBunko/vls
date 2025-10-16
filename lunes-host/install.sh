#!/usr/bin/env sh
set -eu

# 默认值（可被环境变量覆盖）
DOMAIN="${DOMAIN:-node68.lunes.host}"
PORT="${PORT:-10008}"
UUID="${UUID:-2584b733-9095-4bec-a7d5-62b473540f7a}"
HY2_PASSWORD="${HY2_PASSWORD:-vevc.HY2.Password}"
WS_PATH="${WS_PATH:-/wspath}"
CFTUNNEL_TOKEN="${CFTUNNEL_TOKEN:-}"  # Cloudflare Tunnel token（可选，但提供则 app.js 会启动 cloudflared）

# 确保工作目录
cd /home/container || exit 1
mkdir -p /home/container/xy /home/container/h2

# 下载 app.js 与 package.json（如果你已在容器里预放可跳过）
curl -sSL -o /home/container/app.js https://raw.githubusercontent.com/DengekiBunko/vls/refs/heads/main/lunes-host/app.js || true
curl -sSL -o /home/container/package.json https://raw.githubusercontent.com/DengekiBunko/vls/refs/heads/main/lunes-host/package.json || true

# ---------- Xray (xy) 处置 ----------
cd /home/container/xy
echo "[install] Downloading Xray..."
curl -sSL -o Xray-linux-64.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
# 解压（若容器提供 unzip）
if command -v unzip >/dev/null 2>&1; then
  unzip -o Xray-linux-64.zip
  rm -f Xray-linux-64.zip
else
  echo "[warn] unzip not found; ensure Xray binary exists in /home/container/xy"
fi

# 移动二进制到 xy（不同包内名称差异）
if [ -f xray ]; then mv -f xray xy || true; fi
if [ -f Xray ]; then mv -f Xray xy || true; fi
chmod +x /home/container/xy/xy || true

# 写入 xray origin 配置（plain WS，Cloudflare edge 负责 TLS）
cat > /home/container/xy/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": 10008,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "YOUR_UUID", "email": "lunes-ws" } ],
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

# 替换占位
sed -i "s/10008/$PORT/g" /home/container/xy/config.json
sed -i "s/YOUR_UUID/$UUID/g" /home/container/xy/config.json
# 确保 path 以 / 开头
case "$WS_PATH" in
  /*) ;;
  *) WS_PATH="/$WS_PATH" ;;
esac
sed -i "s|YOUR_WS_PATH|$WS_PATH|g" /home/container/xy/config.json

# ---------- Hysteria2 (h2) ----------
cd /home/container/h2
echo "[install] Downloading Hysteria..."
# 直接下载二进制（示例版本），若失败请替换为可访问的 URL
curl -sSL -o h2 "https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.2/hysteria-linux-amd64" || true
chmod +x /home/container/h2/h2 || true
# 尝试获取示例配置（若仓库路径不可用则忽略）
curl -sSL -o /home/container/h2/config.yaml https://raw.githubusercontent.com/DengekiBunko/vls/refs/heads/main/lunes-host/hysteria-config.yaml || true
# 替换端口与密码（如果 config.yaml 存在占位）
if [ -f /home/container/h2/config.yaml ]; then
  sed -i "s/10008/$PORT/g" /home/container/h2/config.yaml || true
  sed -i "s/HY2_PASSWORD/$HY2_PASSWORD/g" /home/container/h2/config.yaml || true
fi

# ---------- cloudflared 直接二进制下载（已改） ----------
cd /home/container
echo "[install] Downloading cloudflared binary (linux-amd64)..."
# 直接下载二进制文件（linux-amd64）
curl -L -o /home/container/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x /home/container/cloudflared || true
# 简单版本检查（如果 cloudflared 可执行）
if [ -x /home/container/cloudflared ]; then
  /home/container/cloudflared --version || true
fi

# ---------- 生成 node.txt（连接信息） ----------
# vless 用 public domain (Cloudflare edge 提供 TLS). 客户端使用 wss://<PUBLIC_HOST><WS_PATH>
encoded_path=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$WS_PATH" 2>/dev/null || echo "%2Fwspath")
vlessUrl="vless://$UUID@$DOMAIN:443?encryption=none&security=tls&type=ws&host=$DOMAIN&path=$encoded_path&sni=$DOMAIN#lunes-ws"
echo "$vlessUrl" > /home/container/node.txt

# hysteria url
encodedHy2Pwd=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$HY2_PASSWORD" 2>/dev/null || echo "vevc.HY2.Password")
hy2Url="hysteria2://$encodedHy2Pwd@$DOMAIN:$PORT?insecure=1#lunes-hy2"
echo "$hy2Url" >> /home/container/node.txt

# ---------- 权限 & 完成信息 ----------
chmod +x /home/container/app.js || true
chmod +x /home/container/cloudflared || true
echo "============================================================"
echo "Setup complete."
echo " - Xray config: /home/container/xy/config.json"
echo " - Hysteria config: /home/container/h2/config.yaml (if present)"
echo " - node links: /home/container/node.txt"
if [ -n "$CFTUNNEL_TOKEN" ]; then
  echo "cloudflared token present; app.js will attempt to start cloudflared with the token."
else
  echo "No CFTUNNEL_TOKEN provided. If you want a fixed named tunnel, run with CFTUNNEL_TOKEN set."
fi
echo "Start processes: npm start  OR  node /home/container/app.js"
echo "============================================================"
