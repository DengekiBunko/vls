const { exec } = require('child_process');
const path = require('path');

// ---------------------------
// 配置变量 (确保这些与 install.sh 中的一致)
// ---------------------------
const WORKDIR = process.env.WORKDIR || '/home/container';
const TUNNEL_NAME = process.env.TUNNEL_NAME || 'mytunnel'; // 从部署命令读取 tunnel 名称
const DOMAIN = process.env.DOMAIN || 'node68.lunes.host';
const PORT = process.env.PORT || '10008';

// ---------------------------
// 构建命令
// ---------------------------
const xrayPath = path.join(WORKDIR, 'xy', 'xy');
const xrayConfigPath = path.join(WORKDIR, 'xy', 'config.json');
const xrayCommand = `${xrayPath} -config ${xrayConfigPath}`;

const hy2Path = path.join(WORKDIR, 'h2', 'h2');
const hy2ConfigPath = path.join(WORKDIR, 'h2', 'config.yaml');
const hy2Command = `${hy2Path} server --config ${hy2ConfigPath}`;

const cloudflaredPath = path.join(WORKDIR, 'cloudflared');
const cloudflaredCommand = `${cloudflaredPath} tunnel --no-autoupdate run ${TUNNEL_NAME}`;

// ---------------------------
// 启动函数
// ---------------------------
function runCommand(command, name) {
  console.log(`[Launcher] Starting ${name}...`);
  const child = exec(command);

  child.stdout.on('data', (data) => {
    process.stdout.write(`[${name}] ${data}`);
  });

  child.stderr.on('data', (data) => {
    process.stderr.write(`[${name} ERROR] ${data}`);
  });

  child.on('close', (code) => {
    console.log(`[Launcher] ${name} exited with code ${code}`);
  });

  return child;
}

// ---------------------------
// 启动服务
// ---------------------------
// VLESS-WS 走 Cloudflared Tunnel
runCommand(cloudflaredCommand, 'Cloudflared');
runCommand(xrayCommand, 'Xray');

// Hysteria2 直连
runCommand(hy2Command, 'Hysteria2');

console.log('[Launcher] All services are being started.');

// 防止主进程退出
setInterval(() => {}, 1000 * 60 * 60);
