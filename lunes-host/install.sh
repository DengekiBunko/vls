#!/usr/bin/env sh
set -eu

# -------------------------
# 配置（可由环境变量覆盖）
# -------------------------
DOMAIN="${DOMAIN:-node24.lunes.host}"        # 容器内部/原始域（仅用于生成 cert CN）
PORT="${PORT:-3460}"                         # origin 监听端口（Xray & H2）
UUID="${UUID:-your-uuid}"
HY2_PASSWORD="${HY2_PASSWORD:-your-hy2-password}"
WS_PATH="${WS_PATH:-/wspath}"                # 请确保 Cloudflare Public Hostname 中的 Path 与此一致
CFTUNNEL_TOKEN="${CFTUNNEL_TOKEN:-}"        # 可选：Cloudflare 隧道 token（若提供，app.js 会尝试启动 cloudflared）
PUBLIC_HOSTNAME="${PUBLIC_HOSTNAME:-}"       # 必填：Cloudflare Public Hostname，例如 luneshost01.xdzw.dpdns.org
# -------------------------

echo "[install.sh] start"

# 确保工作目录
cd /home/container || exit 1
mkdir -p /home/container/xy /home/container/h2 /home/container/.cloudflared

# -------------------------
# 获取 app.js & package.json（可选）
# -------------------------
# 如果你已有 app.js/package.json，可删掉下两行
curl -sSL -o /home/container/app.js https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/app.js || true
curl -sSL -o /home/container/package.json https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/package.json || true
chmod +x /home/container/app.js || true

# -------------------------
# 下载并准备 Xray (xy)
# -------------------------
cd /home/container/xy
echo "[install.sh] Downloading Xray..."
curl -sSL -o Xray-linux-64.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
# unzip 若不存在则提示但继续（多数容器含 unzip）
if command -v unzip >/dev/null 2>&1; then
  unzip -o Xray-linux-64.zip || true
  rm -f Xray-linux-64.zip
else
  echo "[install.sh][warn] unzip not found; if xray binary not present, please provide it manually"
fi

# 移动/重命名二进制为 xy（兼容不同打包）
if [ -f xray ]; then mv -f xray xy || true; fi
if [ -f Xray ]; then mv -f Xray xy || true; fi
chmod +x /home/container/xy/xy || true

# 写入 Xray config（使用 TLS at origin）
cat > /home/container/xy/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "$UUID", "email": "lunes-ws-tls" }
        ],
        "decryption": "none"
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
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF

# 生成 Xray origin 自签证书（CN 使用 PUBLIC_HOSTNAME 以避免 SNI 差异）
# 如果你更愿意让 Cloudflare 在 edge 终止 TLS，可改为 security:"none" 并删除证书生成
echo "[install.sh] Generating Xray self-signed cert..."
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
  -keyout /home/container/xy/key.pem -out /home/container/xy/cert.pem -subj "/CN=${PUBLIC_HOSTNAME:-$DOMAIN}" || true
chmod 600 /home/container/xy/key.pem /home/container/xy/cert.pem || true

# -------------------------
# 下载并准备 Hysteria2 (h2)
# -------------------------
cd /home/container/h2
echo "[install.sh] Downloading Hysteria..."
curl -sSL -o h2 "https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.2/hysteria-linux-amd64" || true
chmod +x /home/container/h2/h2 || true

# 生成 Hysteria 的证书（单独放在 h2 目录）
echo "[install.sh] Generating Hysteria self-signed cert..."
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
  -keyout /home/container/h2/key.pem -out /home/container/h2/cert.pem -subj "/CN=${PUBLIC_HOSTNAME:-$DOMAIN}" || true
chmod 600 /home/container/h2/key.pem /home/container/h2/cert.pem || true

# 写入 Hysteria v2 config（正确的 object 格式 obfs）
cat > /home/container/h2/config.yaml <<EOF
listen: 0.0.0.0:$PORT
cert: /home/container/h2/cert.pem
key: /home/container/h2/key.pem
obfs:
  type: password
  password: "$HY2_PASSWORD"
# 你可以在这里添加更多 h2 配置项
EOF

# -------------------------
# 下载 cloudflared 可执行文件（直接二进制，不用解压）
# -------------------------
cd /home/container
echo "[install.sh] Downloading cloudflared binary (linux-amd64)..."
curl -L -o /home/container/cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
chmod +x /home/container/cloudflared || true
if [ -x /home/container/cloudflared ]; then
  /home/container/cloudflared --version || true
fi

# 若提供 token，则在 .cloudflared 里保存 token（注意安全：建议在 Pterodactyl 面板用 Environment 注入 token 而非写入脚本）
if [ -n "$CFTUNNEL_TOKEN" ]; then
  echo "[install.sh] Writing token to /home/container/.cloudflared/token.txt"
  printf '%s' "$CFTUNNEL_TOKEN" > /home/container/.cloudflared/token.txt
  chmod 600 /home/container/.cloudflared/token.txt || true
fi

# -------------------------
# 生成 node 链接 (使用 CF Public Hostname + :443)
# -------------------------
# WS path 需要 URL encode
ENC_PATH=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$WS_PATH" 2>/dev/null || printf '%s' "%2Fwspath")
VLESS_URL="vless://$UUID@${PUBLIC_HOSTNAME:-$DOMAIN}:443?encryption=none&security=tls&type=ws&host=${PUBLIC_HOSTNAME:-$DOMAIN}&path=${ENC_PATH}&sni=${PUBLIC_HOSTNAME:-$DOMAIN}#lunes-ws-tls"
HY2_ENC=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$HY2_PASSWORD" 2>/dev/null || printf '%s' "password")
HY2_URL="hysteria2://$HY2_ENC@${PUBLIC_HOSTNAME:-$DOMAIN}:443?insecure=1#lunes-hy2"

echo "$VLESS_URL" > /home/container/node.txt
echo "$HY2_URL" >> /home/container/node.txt

# -------------------------
# 完成提示
# -------------------------
echo "============================================================"
echo "[install.sh] Setup complete."
echo " - Xray config: /home/container/xy/config.json"
echo " - Xray cert/key: /home/container/xy/cert.pem /home/container/xy/key.pem"
echo " - Hysteria config: /home/container/h2/config.yaml"
echo " - Hysteria cert/key: /home/container/h2/cert.pem /home/container/h2/key.pem"
echo " - cloudflared binary: /home/container/cloudflared"
echo " - node links: /home/container/node.txt"
echo " NOTE: If you provided CFTUNNEL_TOKEN, app.js will try to start cloudflared with it."
echo "============================================================"
