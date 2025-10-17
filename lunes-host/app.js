const { exec } = require('child_process');
const path = require('path');
const fs = require('fs');

const WORKDIR = '/home/container';
const TUNNEL_NAME = process.env.TUNNEL_NAME || 'mytunnel';
const DOMAIN = process.env.DOMAIN || 'node24.lunes.host';
const PORT = process.env.PORT || '3460';
const UUID = process.env.UUID || '9bdc7c19-2b32-4036-8e26-df7b984f7f9e';
const HY2_PASSWORD = process.env.HY2_PASSWORD || 'jvu2JldmXk5pB1Xz';
const WS_PATH = process.env.WS_PATH || '/wspath';

const xyPath = path.join(WORKDIR, 'xy', 'xy');
const xyConfig = path.join(WORKDIR, 'xy', 'config.json');
const hy2Path = path.join(WORKDIR, 'h2', 'h2');
const hy2Config = path.join(WORKDIR, 'h2', 'config.yaml');
const cloudflaredPath = path.join(WORKDIR, 'cloudflared');

// 临时隧道日志文件
const cfLog = path.join(WORKDIR, 'cloudflared.log');

// ---------------------------
// 启动函数
// ---------------------------
function runCommand(cmd, name) {
  console.log(`[Launcher] Starting ${name}...`);
  const child = exec(cmd);
  child.stdout.on('data', d => process.stdout.write(`[${name}] ${d}`));
  child.stderr.on('data', d => process.stderr.write(`[${name} ERROR] ${d}`));
  child.on('close', code => console.log(`[Launcher] ${name} exited with code ${code}`));
  return child;
}

// ---------------------------
// 启动 Cloudflared 临时隧道
// ---------------------------
let TEMP_DOMAIN = '';
runCommand(`${cloudflaredPath} tunnel --url http://127.0.0.1:${PORT} > ${cfLog} 2>&1 &`, 'Cloudflared');

// 等待 5 秒获取临时域名
setTimeout(() => {
  try {
    const log = fs.readFileSync(cfLog, 'utf-8');
    const match = log.match(/https:\/\/[a-z0-9-]+\.trycloudflare\.com/);
    if (match) TEMP_DOMAIN = match[0].replace('https://','');
  } catch (e) {}
  if(!TEMP_DOMAIN) TEMP_DOMAIN = 'localhost';
  console.log(`[Launcher] Temporary Cloudflare domain: ${TEMP_DOMAIN}`);

  // ---------------------------
  // 构建 VLESS 链接
  // ---------------------------
  const encodePath = encodeURIComponent(WS_PATH);
  const vlessUrl = `vless://${UUID}@${TEMP_DOMAIN}:443?encryption=none&security=tls&type=ws&host=${TEMP_DOMAIN}&path=${encodePath}&sni=${TEMP_DOMAIN}#lunes-ws-tls`;
  const hy2Url = `hysteria2://${encodeURIComponent(HY2_PASSWORD)}@${DOMAIN}:${PORT}?insecure=1#lunes-hy2`;

  fs.writeFileSync(path.join(WORKDIR,'node.txt'), vlessUrl + '\n' + hy2Url);

  console.log('============================================================');
  console.log('🚀 VLESS WS+TLS & HY2 Node Info');
  console.log(vlessUrl);
  console.log(hy2Url);
  console.log('============================================================');

  // ---------------------------
  // 启动 Xray 和 HY2
  // ---------------------------
  runCommand(`${xyPath} -config ${xyConfig}`, 'Xray');
  runCommand(`${hy2Path} server --config ${hy2Config}`, 'Hysteria2');

}, 5000);

// 防止主进程退出
setInterval(()=>{}, 1000*60*60);
