// app.js — 最终修正版（基于 exec，确保 Cloudflared 可启动）
const { exec } = require('child_process');
const path = require('path');

// ---------------------------
// 配置变量
// ---------------------------
const WORKDIR = '/home/container';
const DOMAIN = process.env.DOMAIN || 'node68.lunes.host';
const PORT = process.env.PORT || '10008';
const UUID = process.env.UUID || '2584b733-2b32-4036-8e26-df7b984f7f9e';
const HY2_PASSWORD = process.env.HY2_PASSWORD || 'vevc.HY2.Password';
const WS_PATH = process.env.WS_PATH || '/wspath';
const TUNNEL_NAME = process.env.TUNNEL_NAME || 'mytunnel';
const TUNNEL_TOKEN = process.env.TUNNEL_TOKEN || ''; // 可选

// ---------------------------
// 可执行文件路径
// ---------------------------
const xrayPath = path.join(WORKDIR, 'xy', 'xy');
const xrayConfigPath = path.join(WORKDIR, 'xy', 'config.json');
const xrayCommand = `${xrayPath} -config ${xrayConfigPath}`;

const hy2Path = path.join(WORKDIR, 'h2', 'h2');
const hy2ConfigPath = path.join(WORKDIR, 'h2', 'config.yaml');
const hy2Command = `${hy2Path} server --config ${hy2ConfigPath}`;

const cloudflaredPath = path.join(WORKDIR, 'cloudflared');

// ---------------------------
// Cloudflared 启动命令
// ---------------------------
let cloudflaredCommand = '';
if (TUNNEL_TOKEN && TUNNEL_TOKEN.trim() !== '') {
  // 使用 token 运行（推荐）
  cloudflaredCommand = `${cloudflaredPath} tunnel --no-autoupdate run --token ${TUNNEL_TOKEN}`;
  console.log(`[Launcher] Starting Cloudflared using TUNNEL_TOKEN`);
} else {
  // 使用已登录凭证文件运行
  cloudflaredCommand = `${cloudflaredPath} tunnel --no-autoupdate run ${TUNNEL_NAME}`;
  console.log(`[Launcher] Starting Cloudflared using tunnel name "${TUNNEL_NAME}"`);
}

// ---------------------------
// 启动函数
// ---------------------------
function runCommand(command, name) {
  console.log(`[Launcher] Starting ${name}...`);
  const child = exec(command, { cwd: WORKDIR });

  child.stdout.on('data', (data) => process.stdout.write(`[${name}] ${data}`));
  child.stderr.on('data', (data) => process.stderr.write(`[${name} ERROR] ${data}`));
  child.on('close', (code) => console.log(`[Launcher] ${name} exited with code ${code}`));
  return child;
}

// ---------------------------
// 启动所有服务
// ---------------------------
runCommand(xrayCommand, 'Xray');
runCommand(hy2Command, 'Hysteria2');
runCommand(cloudflaredCommand, 'Cloudflared');

console.log('[Launcher] All services are being started.');

// 保活防退出
setInterval(() => {}, 1000 * 60 * 60);
