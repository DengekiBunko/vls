const { exec } = require('child_process');
const path = require('path');

// ---------------------------
// 配置变量 (确保这些与 install.sh 中的一致)
// ---------------------------
const WORKDIR = '/home/container';
const TUNNEL_NAME = process.env.TUNNEL_NAME || 'mytunnel'; // 从环境变量读取，或使用默认值

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
const cloudflaredCommand = `${cloudflaredPath} tunnel --no-autoupdate run --token ${process.env.TUNNEL_TOKEN}`;

// ---------------------------
// 启动函数
// ---------------------------
function runCommand(command, name) {
  console.log(`[Launcher] Starting ${name}...`);
  const child = exec(command);

  // 将子进程的输出实时打印到主进程的控制台
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
// 启动所有服务
// ---------------------------
//【重要】注意：原始脚本中没有TUNNEL_TOKEN，但这是 `cloudflared tunnel run` 更现代、更可靠的运行方式。
// 为了简单起见，我们先用旧的方式，它会依赖于已登录的 cert.pem。
const cloudflaredRunCommand = `${cloudflaredPath} tunnel --no-autoupdate run ${TUNNEL_NAME}`;


runCommand(xrayCommand, 'Xray');
runCommand(hy2Command, 'Hysteria2');
runCommand(cloudflaredRunCommand, 'Cloudflared');

console.log('[Launcher] All services are being started.');

// 防止主进程退出
setInterval(() => {}, 1000 * 60 * 60);
