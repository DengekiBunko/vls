const { spawn } = require('child_process');
const path = require('path');

const CFTUNNEL_TOKEN = process.env.CFTUNNEL_TOKEN || '';
const XY_BIN = '/home/container/xy/xy';
const H2_BIN = '/home/container/h2/h2';
const CLOUDFLARED_BIN = '/home/container/cloudflared';

function run(name, cmd, args, cwd) {
  console.log(`[START] ${name}: ${cmd} ${args.join(' ')}`);
  const child = spawn(cmd, args, { stdio: 'inherit', cwd: cwd || undefined, env: process.env });
  child.on('exit', (code, signal) => {
    console.log(`[EXIT] ${name} exited (code=${code} signal=${signal}). Restarting in 3s...`);
    setTimeout(() => run(name, cmd, args, cwd), 3000);
  });
  child.on('error', (err) => {
    console.error(`[ERROR] Failed to start ${name}:`, err.message);
    setTimeout(() => run(name, cmd, args, cwd), 5000);
  });
}

// If token provided, attempt to run cloudflared tunnel run (token or named run method)
if (CFTUNNEL_TOKEN) {
  // We'll run cloudflared in "tunnel run --token <token>" mode; ensure cloudflared binary exists
  run('cloudflared', CLOUDFLARED_BIN, ['tunnel', 'run', '--token', CFTUNNEL_TOKEN], '/home/container');
} else {
  console.warn('[WARN] CFTUNNEL_TOKEN not set; cloudflared will not be started automatically.');
}

// Start Xray (xy)
run('xy', XY_BIN, ['-c', '/home/container/xy/config.json'], '/home/container/xy');

// Start Hysteria2 (h2)
run('h2', H2_BIN, ['server', '-c', '/home/container/h2/config.yaml'], '/home/container/h2');
