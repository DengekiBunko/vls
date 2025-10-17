const { exec } = require('child_process');
const path = require('path');
const fs = require('fs');

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
const cloudflaredConfigPath = path.join(WORKDIR, '.cloudflared', 'config.yml');

// 如果 config.yml 存在则使用 --config run，否则尝试使用临时隧道运行（会提示需要隧道 ID）
let cloudflaredRunCommand;
if (fs.existsSync(cloudflaredConfigPath)) {
  cloudflaredRunCommand = `${cloudflaredPath} tunnel --no-autoupdate run --config ${cloudflaredConfigPath}`;
} else {
  // fallback: run without --config will require ID arg; but try running temporary tunnel via url (non-config)
  cloudflaredRunCommand = `${cloudflaredPath} tunnel --no-autoupdate run --url http://127.0.0.1:10008`;
}

// ---------------------------
// 启动函数
// ---------------------------
function runCommand(command, name) {
  console.log(`[Launcher] Starting ${name}...`);
  const child = exec(command, { cwd: WORKDIR, env: process.env });

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
// 启动所有服务（按你原来风格）
// ---------------------------
runCommand(xrayCommand, 'Xray');
runCommand(hy2Command, 'Hysteria2');
runCommand(cloudflaredRunCommand, 'Cloudflared');

console.log('[Launcher] All services are being started.');

// 防止主进程退出
setInterval(() => {}, 1000 * 60 * 60);
