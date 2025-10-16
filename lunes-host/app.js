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
    // hysteria: server -c config.yaml
    binaryPath: '/home/container/h2/h2',
    args: ['server', '-c', '/home/container/h2/config.yaml'],
    cwd: '/home/container/h2'
  }
];

// If CFTUNNEL_TOKEN is present, add cloudflared as an app to be managed
if (CFTUNNEL_TOKEN) {
  apps.push({
    name: 'cloudflared',
    binaryPath: '/home/container/cloudflared',
    args: ['tunnel', 'run', '--token', CFTUNNEL_TOKEN],
    cwd: '/home/container'
  });
} else {
  console.warn('[WARN] CFTUNNEL_TOKEN not found in env. cloudflared will not be started by app.js.');
}

function spawnApp(app) {
  console.log(`[START] Launching ${app.name}: ${app.binaryPath} ${app.args.join(' ')}`);
  const child = spawn(app.binaryPath, app.args, {
    stdio: 'inherit',
    cwd: app.cwd || undefined,
    env: process.env
  });

  child.on('exit', (code, signal) => {
    console.log(`[EXIT] ${app.name} exited (code=${code} signal=${signal}). Restarting in 3s...`);
    setTimeout(() => spawnApp(app), 3000);
  });

  child.on('error', (err) => {
    console.error(`[ERROR] Failed to start ${app.name}: ${err.message}. Retry in 5s...`);
    setTimeout(() => spawnApp(app), 5000);
  });
}

// start all apps
for (const app of apps) spawnApp(app);

// keep node running
process.on('SIGINT', () => {
  console.log('[SIGINT] Exiting, letting child processes stop.');
  process.exit(0);
});
