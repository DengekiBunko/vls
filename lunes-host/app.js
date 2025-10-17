const { exec } = require('child_process');
const path = require('path');

const WORKDIR = process.env.WORKDIR || '/home/container';
const DOMAIN = process.env.DOMAIN || 'localhost';
const PORT = process.env.PORT || '10008';         // Hysteria port
const XRAY_PORT = process.env.XRAY_PORT || '10008'; // Xray internal port
const UUID = process.env.UUID || '2584b733-2b32-4036-8e26-df7b984f7f9e';
const HY2_PASSWORD = process.env.HY2_PASSWORD || 'vevc.HY2.Password';
const WS_PATH = process.env.WS_PATH || '/wspath';

const xrayPath = path.join(WORKDIR, 'xy', 'xy');
const xrayConfigPath = path.join(WORKDIR, 'xy', 'config.json');

const hy2Path = path.join(WORKDIR, 'h2', 'h2');
const hy2ConfigPath = path.join(WORKDIR, 'h2', 'config.yaml');

function runCommand(command, name) {
    console.log(`[Launcher] Starting ${name}...`);
    const child = exec(command, { cwd: WORKDIR });

    child.stdout.on('data', (data) => process.stdout.write(`[${name}] ${data}`));
    child.stderr.on('data', (data) => process.stderr.write(`[${name} ERROR] ${data}`));
    child.on('close', (code) => console.log(`[Launcher] ${name} exited with code ${code}`));

    return child;
}

// 启动 Xray 和 Hysteria（延迟一点以确保文件和 cloudflared 已就绪）
setTimeout(() => {
    runCommand(`${xrayPath} -config ${xrayConfigPath}`, 'Xray');
    runCommand(`${hy2Path} server --config ${hy2ConfigPath}`, 'Hysteria2');
}, 2000);

// 防止主进程退出
setInterval(() => {}, 1000 * 60 * 60);

console.log('[Launcher] All services are being started.');
