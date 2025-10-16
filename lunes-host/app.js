// app.js — 修正版（保证 Cloudflared 持续运行；VLESS-WS 通过 tunnel；HY2 直连优先 PUBLIC_IP）
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');

// ---------------------------
// 配置变量（可由部署命令覆盖）
// ---------------------------
const WORKDIR = process.env.WORKDIR || '/home/container';
const TUNNEL_NAME = process.env.TUNNEL_NAME || 'mytunnel';
const DOMAIN = process.env.DOMAIN || 'node68.lunes.host';
const PORT = process.env.PORT || '10008'; // Xray 监听端口（VLESS）
const WS_PATH = process.env.WS_PATH || '/wspath';
const UUID = process.env.UUID || 'replace-with-uuid';
const HY2_PASSWORD = process.env.HY2_PASSWORD || 'replace-hy2-password';
const PUBLIC_IP = process.env.PUBLIC_IP || ''; // 强烈建议在部署时提供宿主公网 IP（用于 HY2 直连）
const TUNNEL_TOKEN = process.env.TUNNEL_TOKEN || ''; // 可选：如果提供 token 则使用 --token 不需要交互登录

// ---------------------------
// 可执行文件路径
// ---------------------------
const xrayPath = path.join(WORKDIR, 'xy', 'xy');
const xrayConfigPath = path.join(WORKDIR, 'xy', 'config.json');

const hy2Path = path.join(WORKDIR, 'h2', 'h2');
const hy2ConfigPath = path.join(WORKDIR, 'h2', 'config.yaml');

const cloudflaredPath = path.join(WORKDIR, 'cloudflared');
const cloudflaredDir = path.join(WORKDIR, '.cloudflared');
const cloudflaredConfigPath = path.join(cloudflaredDir, 'config.yml');

// ---------------------------
// 辅助函数
// ---------------------------
function spawnAndPipe(cmd, args, name) {
  console.log(`[Launcher] Spawning ${name}: ${cmd} ${args.join(' ')}`);
  const child = spawn(cmd, args, { stdio: ['ignore', 'pipe', 'pipe'] });

  child.stdout.on('data', (d) => process.stdout.write(`[${name}] ${d}`));
  child.stderr.on('data', (d) => process.stderr.write(`[${name} ERROR] ${d}`));
  child.on('close', (code) => console.log(`[Launcher] ${name} exited with code ${code}`));
  child.on('error', (err) => console.error(`[Launcher] ${name} spawn error:`, err));
  return child;
}

function writeNodeFiles(vlessUrl, hy2Url) {
  try {
    const nodeTxt = path.join(WORKDIR, 'node.txt');
    fs.writeFileSync(nodeTxt, `${vlessUrl}\n${hy2Url}\n`, { encoding: 'utf8' });
    console.log(`[Launcher] node info written to ${nodeTxt}`);
  } catch (e) {
    console.error('[Launcher] failed to write node.txt:', e);
  }
}

// URL-encoding helpers
function enc(s) {
  return encodeURIComponent(s);
}

// ---------------------------
// 检查 cloudflared 凭证 & 生成 config.yml（如果使用凭证方式）
// ---------------------------
if (!fs.existsSync(cloudflaredDir)) {
  try { fs.mkdirSync(cloudflaredDir, { recursive: true }); } catch (e) { /* ignore */ }
}

let useToken = false;
if (TUNNEL_TOKEN && TUNNEL_TOKEN.trim() !== '') {
  useToken = true;
  console.log('[Launcher] Using TUNNEL_TOKEN to run cloudflared (no interactive login required).');
}

// 如果不用 token，就必须存在凭证 json（来自 cloudflared login/create）
let credentialsJson = null;
if (!useToken) {
  try {
    const files = fs.readdirSync(cloudflaredDir);
    const jsons = files.filter(f => f.endsWith('.json'));
    if (jsons.length > 0) {
      // 选择第一个 json（通常是 tunnel 凭证），优先最近修改的
      jsons.sort((a, b) => {
        const aStat = fs.statSync(path.join(cloudflaredDir, a));
        const bStat = fs.statSync(path.join(cloudflaredDir, b));
        return bStat.mtimeMs - aStat.mtimeMs;
      });
      credentialsJson = jsons[0];
      console.log(`[Launcher] Found cloudflared credentials: ${credentialsJson}`);
    } else {
      console.warn('[Launcher] No .json credentials found in .cloudflared — cloudflared login must be done first unless using TUNNEL_TOKEN.');
    }
  } catch (e) {
    console.warn('[Launcher] while checking .cloudflared:', e);
  }
}

// 如果有凭证且不使用 token，则生成 config.yml 指向 Xray 端口
if (!useToken && credentialsJson) {
  const credentialsPath = path.join(cloudflaredDir, credentialsJson);
  const cfg = [
    `tunnel: ${TUNNEL_NAME}`,
    `credentials-file: ${credentialsPath}`,
    `ingress:`,
    `  - hostname: ${DOMAIN}`,
    `    service: tcp://localhost:${PORT}`,
    `  - service: http_status:404`
  ].join('\n') + '\n';
  try {
    fs.writeFileSync(cloudflaredConfigPath, cfg, { encoding: 'utf8' });
    console.log(`[Launcher] Generated cloudflared config at ${cloudflaredConfigPath}`);
  } catch (e) {
    console.error('[Launcher] Failed writing cloudflared config:', e);
  }
}

// ---------------------------
// 生成节点 URL（VLESS 指向 DOMAIN:443，HY2 优先使用 PUBLIC_IP 直连）
// ---------------------------
// VLESS URL -> 使用域名（走 Cloudflare tunnel 的域名）
const vlessUrl = `vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&type=ws&host=${DOMAIN}&path=${enc(WS_PATH)}&sni=${DOMAIN}#lunes-ws-tls`;

// HY2 URL -> 优先 PUBLIC_IP:PORT（直连），否则回退到 DOMAIN（警告）
let hy2HostForUrl = '';
if (PUBLIC_IP && PUBLIC_IP.trim() !== '') {
  hy2HostForUrl = `${PUBLIC_IP}:${PORT}`;
} else {
  hy2HostForUrl = `${DOMAIN}:443`;
  console.warn(`[Launcher] WARNING: PUBLIC_IP not provided. HY2 URL will use DOMAIN (${DOMAIN}), which may route through Cloudflare/tunnel. To force HY2 direct connect, provide PUBLIC_IP env var.`);
}
const hy2Url = `hysteria2://${enc(HY2_PASSWORD)}@${hy2HostForUrl}?insecure=1#lunes-hy2`;

// write node info
writeNodeFiles(vlessUrl, hy2Url);

// ---------------------------
// 启动 Cloudflared（优先使用 token 启动，否则使用 --config 指定的 config.yml）
// ---------------------------
let cloudflaredChild = null;
if (useToken) {
  // run with token (no config.yml needed)
  const args = ['tunnel', '--no-autoupdate', 'run', '--token', TUNNEL_TOKEN];
  cloudflaredChild = spawnAndPipe(cloudflaredPath, args, 'Cloudflared');
} else {
  if (!credentialsJson) {
    console.error('[Launcher] No cloudflared credentials found and no TUNNEL_TOKEN provided. Cloudflared cannot be started in credential mode. Exiting.');
    // We don't exit the process to allow Xray/Hysteria to run if desired, but warn loudly.
  } else {
    const args = ['tunnel', '--no-autoupdate', 'run', '--config', cloudflaredConfigPath];
    cloudflaredChild = spawnAndPipe(cloudflaredPath, args, 'Cloudflared');
  }
}

// ---------------------------
// 启动 Xray（确保 Xray 在 cloudflared 之后启动更可靠）
// ---------------------------
if (!fs.existsSync(xrayPath)) {
  console.error(`[Launcher] Xray executable not found at ${xrayPath}. Please ensure it exists and is executable.`);
} else {
  // xray expects: -config <path> OR -c <path> depending on build; we use -config
  const xrayArgs = ['-config', xrayConfigPath];
  spawnAndPipe(xrayPath, xrayArgs, 'Xray');
}

// ---------------------------
// 启动 Hysteria2（直连）
// ---------------------------
if (!fs.existsSync(hy2Path)) {
  console.error(`[Launcher] Hysteria2 executable not found at ${hy2Path}. Please ensure it exists and is executable.`);
} else {
  const hy2Args = ['server', '--config', hy2ConfigPath];
  spawnAndPipe(hy2Path, hy2Args, 'Hysteria2');
}

// ---------------------------
// 保持主进程存活
// ---------------------------
console.log('[Launcher] All services started (or attempted). Check logs above for Cloudflared/Xray/Hysteria2 status.');
setInterval(() => {}, 1000 * 60 * 60);
