const { spawn } = require('child_process');
const path = require('path');

const DOMAIN = process.env.DOMAIN;
const PORT = process.env.PORT;
const CFTUNNEL_TOKEN = process.env.CFTUNNEL_TOKEN;
const PUBLIC_HOSTNAME = process.env.PUBLIC_HOSTNAME;

// 启动 cloudflared 隧道
if (CFTUNNEL_TOKEN && PUBLIC_HOSTNAME) {
  console.log('[INFO] Starting cloudflared tunnel...');
  const cf = spawn('/home/container/cloudflared', ['tunnel', 'run', '--token', CFTUNNEL_TOKEN], { stdio: 'inherit' });
  cf.on('exit', (code) => {
    console.log(`[INFO] cloudflared exited with code ${code}`);
  });
}

// 启动 Xray
const xy = spawn('/home/container/xy/xy', ['-c', '/home/container/xy/config.json'], { stdio: 'inherit' });
xy.on('exit', (code) => { console.log(`[INFO] xy exited with code ${code}`); });

// 启动 Hysteria
const h2 = spawn('/home/container/h2/h2', ['server', '-c', '/home/container/h2/config.yaml'], { stdio: 'inherit' });
h2.on('exit', (code) => { console.log(`[INFO] h2 exited with code ${code}`); });
