const { spawn } = require('child_process');
const path = require('path');

const WORKDIR = process.env.WORKDIR || '/home/container';
const PORT = process.env.PORT || '10008';

// 启动函数
function runCommand(name, cmd, args) {
  console.log(`[Launcher] Starting ${name}...`);
  const p = spawn(cmd, args, { cwd: WORKDIR });
  p.stdout.on('data', (d) => process.stdout.write(`[${name}] ${d.toString()}`));
  p.stderr.on('data', (d) => process.stderr.write(`[${name} ERROR] ${d.toString()}`));
  p.on('exit', (code) => console.log(`[Launcher] ${name} exited with code ${code}`));
  return p;
}

// 启动 Xray
const xrayBin = path.join(WORKDIR, 'xy', 'xy');
const xrayConfig = path.join(WORKDIR, 'xy', 'config.json');
runCommand('Xray', xrayBin, ['-config', xrayConfig]);

// 启动 Hysteria2
const h2Bin = path.join(WORKDIR, 'h2', 'h2');
const h2Config = path.join(WORKDIR, 'h2', 'config.yaml');
runCommand('Hysteria2', h2Bin, ['server', '--config', h2Config]);

// 启动 Cloudflared 临时隧道
const cloudflaredBin = path.join(WORKDIR, 'cloudflared');
if (require('fs').existsSync(cloudflaredBin)) {
  runCommand('Cloudflared', cloudflaredBin, ['tunnel', '--url', `http://127.0.0.1:${PORT}`, 'run']);
} else {
  console.warn('[Launcher] cloudflared not found, skipping');
}

// 防止主进程退出
setInterval(() => {}, 1000 * 60 * 60);
