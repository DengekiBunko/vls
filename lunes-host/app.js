const { spawn } = require('child_process');
const path = require('path');

const CFTUNNEL_TOKEN = process.env.CFTUNNEL_TOKEN || '';

const apps = [
  {
    name: 'xy',
    binaryPath: '/home/container/xy/xy',
    args: ['-c', '/home/container/xy/config.json'],
    cwd: '/home/container/xy'
  },
  {
    name: 'h2',
    binaryPath: '/home/container/h2/h2',
    args: ['server', '-c', '/home/container/h2/config.yaml'],
    cwd: '/home/container/h2'
  }
];

if (CFTUNNEL_TOKEN) {
  apps.push({
    name: 'cloudflared',
    binaryPath: '/home/container/cloudflared',
    args: ['tunnel', 'run', '--token', CFTUNNEL_TOKEN],
    cwd: '/home/container'
  });
} else {
  console.warn('[WARN] CFTUNNEL_TOKEN not set; cloudflared will not be started by app.js.');
}

function run(app) {
  console.log(`[START] ${app.name}: ${app.binaryPath} ${app.args.join(' ')}`);
  const child = spawn(app.binaryPath, app.args, {
    stdio: 'inherit',
    cwd: app.cwd || undefined,
    env: process.env
  });

  child.on('exit', (code, signal) => {
    console.log(`[EXIT] ${app.name} exited (code=${code} signal=${signal}), restarting in 3s...`);
    setTimeout(() => run(app), 3000);
  });

  child.on('error', (err) => {
    console.error(`[ERROR] ${app.name} start error:`, err.message);
    setTimeout(() => run(app), 5000);
  });
}

for (const a of apps) run(a);

process.on('SIGINT', () => { console.log('[SIGINT] quitting'); process.exit(0); });
