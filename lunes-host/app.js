const { exec } = require('child_process');
const path = require('path');

// ---------------------------
// 配置变量 (确保 PORT 与 install.sh 和 Xray 配置一致)
// ---------------------------
const WORKDIR = '/home/container';
// 从环境变量或默认值获取端口，必须与 Xray 监听的端口一致 (3460)
const PORT = process.env.PORT || '3460'; 

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
// **修改：使用临时隧道命令**
// Cloudflare Tunnel 会将流量转发到本地 Xray 监听的端口 (例如 3460)
const ORIGIN_URL = `http://localhost:${PORT}`; 
const cloudflaredRunCommand = `${cloudflaredPath} tunnel --url ${ORIGIN_URL} --loglevel info`;


// ---------------------------
// 启动函数
// ---------------------------
function runCommand(command, name) {
  console.log(`[Launcher] Starting ${name}...`);
  const child = exec(command, { cwd: WORKDIR });

  // 确保捕获并输出日志和错误
  child.stdout.on('data', (data) => process.stdout.write(`[${name}] ${data}`));
  child.stderr.on('data', (data) => process.stderr.write(`[${name} ERROR] ${data}`));
  child.on('close', (code) => console.log(`[Launcher] ${name} exited with code ${code}`));

  return child;
}

// ---------------------------
// 启动顺序
// ---------------------------
// 先启动 Cloudflared (临时隧道)
runCommand(cloudflaredRunCommand, 'Cloudflared-Ephemeral');

// 给 tunnel 启动一点时间再启动其他服务
// 注意：Xray 必须在 Cloudflared 试图连接它之前启动
setTimeout(() => {
  runCommand(xrayCommand, 'Xray');
  runCommand(hy2Command, 'Hysteria2');
}, 2000); // 2秒延时是必要的

console.log('[Launcher] All services are being started.');

// 防止主进程退出
setInterval(() => {}, 1000 * 60 * 60);
