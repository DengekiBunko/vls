const { spawn } = require('child_process');
const path = require('path');

const WORKDIR = '/home/container';
const PORT = process.env.PORT || 10008;

// Xray 启动
const xray = spawn(path.join(WORKDIR, 'xy', 'xy'), ['-config', path.join(WORKDIR, 'xy', 'config.json')], { stdio: 'inherit' });

// Hysteria2 启动
const hy2 = spawn(path.join(WORKDIR, 'h2', 'h2'), ['server', '--config', path.join(WORKDIR, 'h2', 'config.yaml')], { stdio: 'inherit' });

// Cloudflared 临时隧道启动
const cloudflared = spawn(path.join(WORKDIR, 'cloudflared'), ['tunnel', '--url', `http://localhost:${PORT}`, 'run'], { stdio: 'inherit' });

console.log('[Launcher] All services started.');

// 防止主进程退出
setInterval(() => {}, 1000 * 60 * 60);
