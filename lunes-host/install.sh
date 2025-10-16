#!/usr/bin/env sh
set -eu

# -------------------------
# 配置（环境变量覆盖）
# -------------------------
DOMAIN="${DOMAIN:-node24.lunes.host}"        # 用于 cert CN（若 PUBLIC_HOSTNAME 未提供则回退）
PORT="${PORT:-3460}"                         # origin 监听端口（Xray & H2）
UUID="${UUID:-your-uuid}"
HY2_PASSWORD="${HY2_PASSWORD:-your-hy2-password}"
WS_PATH="${WS_PATH:-/wspath}"                # 与 Cloudflare Public Hostname Path 保持一致
CFTUNNEL_TOKEN="${CFTUNNEL_TOKEN:-}"        # 可选：Cloudflare 隧道 token
PUBLIC_HOSTNAME="${PUBLIC_HOSTNAME:-}"       # 必填：Cloudflare Public Hostname（例如 luneshost01.xdzw.dpdns.org）
# -------------------------

echo "[install.sh] Starting installation..."

# 确保工作目录
cd /home/container || exit 1
mkdir -p /home/container/xy /home/container/h2 /home/container/.cloudflared

# 下载 app.js/package.json（如果需要）
curl -sSL -o /home/container/app.js https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/app.js || true
curl -sSL -o /home/container/package.json https://raw.githubusercontent.com/vevc/one-node/refs/heads/main/lunes-host/package.json || true
chmod +x /home/container/app.js || true

# -------------------------
# Xray 部分（xy）
# -------------------------
cd /home/container/xy
echo "[install.sh] Downloading Xray..."
curl -sSL -o Xray-linux-64.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip" || true
if command -v unzip >/dev/null 2>&1; then
  unzip -o Xray-linux-64.zip || true
  rm -f Xray-linux-64.zip
fi
# 兼容二进制名
if [ -f xray ]; then mv -f xray xy || true; fi
if [ -f Xray ]; then mv -f Xray xy || true; fi
chmod +x /home/container/xy/xy || true

# 写入 Xray config（单一、无重复）
cat > /home/container/xy/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$UUID", "email": "lunes-ws-tls" } ],
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

# 生成 Xray origin 自签（使用 PUBLIC_HOSTNAME 或 DOMAIN 作为 CN）
echo "[install.sh] Generating Xray cert..."
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
  -keyout /home/container/xy/key.pem -out /home/container/xy/cert.pem -subj "/CN=${PUBLIC_HOSTNAME:-$DOMAIN}" || true
chmod 600 /home/container/xy/key.pem /home/container/xy/cert.pem || true

# -------------------------
# Hysteria2 部分（h2）
# -------------------------
cd /home/container/h2
echo "[install.sh] Downloading Hysteria binary..."
curl -sSL -o h2 "https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.2/hysteria-linux-amd64" || true
chmod +x /home/container/h2/h2 || true

# 生成 Hysteria TLS 证书（放到 /home/container/h2）
echo "[install.sh] Generating Hysteria cert..."
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
  -keyout /home/container/h2/key.pem -out /home/container/h2/cert.pem -subj "/CN=${PUBLIC_HOSTNAME:-$DOMAIN}" || true
chmod 600 /home/container/h2/key.pem /home/container/h2/cert.pem || true

# 写入符合 Hysteria v2 的 config.yaml（没有重复字段）
cat > /home/container/h2/config.yaml <<EOF
listen: 0.0.0.0:$PORT
cert: /home/container/h2/cert.pem
key: /home/container/h2/key.pem

# 认证（客户端需与此匹配）
auth:
  type: password
  password: "$HY2_PASSWORD"

# obfs 使用 Salamander（官方 obfuscation）
obfs:
  type: salamander
  salamander:
    password: "$HY2_PASSWORD"

# 可选：更多配置项可在此添加
EOF

# -------------------------
# cloudflared 二进制（直接下载）
# -------------------------
cd /home/container
echo "[install.sh] Downloading cloudflared..."
curl -L -o /home/container/cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" || true
chmod +x /home/container/cloudflared || true
if [ -x /home/container/cloudflared ]; then /home/container/cloudflared --version || true; fi

# 将 token 写入 .cloudflared/token.txt（可选，但建议用 Pterodactyl 面板 Environment 注入）
if [ -n "$CFTUNNEL_TOKEN" ]; then
  printf '%s' "$CFTUNNEL_TOKEN" > /home/container/.cloudflared/token.txt
  chmod 600 /home/container/.cloudflared/token.txt || true
  echo "[install.sh] token saved to /home/container/.cloudflared/token.txt"
fi

# -------------------------
# 生成 node 链接（使用 PUBLIC_HOSTNAME + 443）
# -------------------------
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
echo " - Hysteria config: /home/container/h2/config.yaml"
echo " - node links: /home/container/node.txt"
echo " - cloudflared binary: /home/container/cloudflared"
echo " Note: ensure PUBLIC_HOSTNAME env var is set to your CF public hostname."
echo "============================================================"
