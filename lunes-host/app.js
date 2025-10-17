const { exec } = require('child_process');
const path = require('path');

// ---------------------------
// 配置变量 (保持与 install.sh 一致)
// ---------------------------
const WORKDIR = '/home/container';
const TUNNEL_NAME = process.env.TUNNEL_NAME || 'mytunnel';

// Xray/VLESS
const xrayPath = path.join(WORKDIR, 'xy', 'xy');
const xrayConfigPath = path.join(WORKDIR, 'xy', 'config.json');
const xrayCommand = `${xrayPath} -config ${xrayConfigPath}`;

// Hysteria2
const hy2Path = path.join(WORKDIR, 'h2', 'h2');
const hy2ConfigPath = path.join(WORKDIR, 'h2', 'config.yaml');
const hy2Command = `${hy2Path} server --config ${hy2ConfigPath}`;

// Cloudflared
const cloudflaredPath = path.join(WORKDIR, 'cloudflared');
const cloudflaredConfigPath = path.join(WORKDIR, '.cloudflared', 'config.yml');
const cloudflaredRunCommand = `${cloudflaredPath} tunnel --no-autoupdate run --config ${cloudflaredConfigPath}`;

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
// 启动顺序
// ---------------------------
// 先启动 Cloudflared
runCommand(cloudflaredRunCommand, 'Cloudflared');

// 给 tunnel 启动一点时间再启动其他服务
setTimeout(() => {
  runCommand(xrayCommand, 'Xray');
  runCommand(hy2Command, 'Hysteria2');
}, 2000);

console.log('[Launcher] All services are being started.');

// 防止主进程退出
setInterval(() => {}, 1000 * 60 * 60);
