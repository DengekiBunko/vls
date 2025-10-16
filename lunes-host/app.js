const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');

// ---------------------------
// 配置变量
// ---------------------------
const WORKDIR = process.env.WORKDIR || '/home/container';
const TUNNEL_NAME = process.env.TUNNEL_NAME || 'mytunnel';
const DOMAIN = process.env.DOMAIN || 'node68.lunes.host';
const PORT = process.env.PORT || '10008';

// Xray 可执行文件和配置
const xrayPath = path.join(WORKDIR, 'xy', 'xy');
const xrayConfigPath = path.join(WORKDIR, 'xy', 'config.json');

// Hysteria2 可执行文件和配置
const hy2Path = path.join(WORKDIR, 'h2', 'h2');
const hy2ConfigPath = path.join(WORKDIR, 'h2', 'config.yaml');

// Cloudflared 可执行文件和配置
const cloudflaredPath = path.join(WORKDIR, 'cloudflared');
const cloudflaredDir = path.join(WORKDIR, '.cloudflared');
const cloudflaredConfig = path.join(cloudflaredDir, 'config.yml');

// ---------------------------
// 确保 cloudflared 配置文件存在
// ---------------------------
if (!fs.existsSync(cloudflaredDir)) fs.mkdirSync(cloudflaredDir, { recursive: true });

// 自动生成最小配置，把 Xray 端口通过 tunnel 暗道出去
const tunnelCredentials = fs.readdirSync(cloudflaredDir).find(f => f.endsWith('.json'));
if (!tunnelCredentials) {
    console.error(`[Cloudflared] Tunnel credentials not found in ${cloudflaredDir}. Please login first.`);
    process.exit(1);
}

const configContent = `
tunnel: ${TUNNEL_NAME}
credentials-file: ${path.join(cloudflaredDir, tunnelCredentials)}
ingress:
  - hostname: ${DOMAIN}
    service: tcp://localhost:${PORT}
  - service: http_status:404
`.trim();

fs.writeFileSync(cloudflaredConfig, configContent);

// ---------------------------
// 启动函数
// ---------------------------
function runCommand(command, name) {
    console.log(`[Launcher] Starting ${name}...`);
    const parts = command.split(' ');
    const child = spawn(parts[0], parts.slice(1), { stdio: 'pipe' });

    child.stdout.on('data', (data) => process.stdout.write(`[${name}] ${data}`));
    child.stderr.on('data', (data) => process.stderr.write(`[${name} ERROR] ${data}`));

    child.on('close', (code) => console.log(`[Launcher] ${name} exited with code ${code}`));
    return child;
}

// ---------------------------
// 启动服务
// ---------------------------

// 1️⃣ Cloudflared 隧道
const cloudflaredCommand = `${cloudflaredPath} tunnel --no-autoupdate run --config ${cloudflaredConfig}`;
runCommand(cloudflaredCommand, 'Cloudflared');

// 2️⃣ Xray
const xrayCommand = `${xrayPath} -config ${xrayConfigPath}`;
runCommand(xrayCommand, 'Xray');

// 3️⃣ Hysteria2
const hy2Command = `${hy2Path} server --config ${hy2ConfigPath}`;
runCommand(hy2Command, 'Hysteria2');

console.log('[Launcher] All services are being started.');

// 防止主进程退出
setInterval(() => {}, 1000 * 60 * 60);
