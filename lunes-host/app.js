cat > /home/container/app.js <<'JS'
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
// 定义 config.yml 的路径（install.sh 会写入）
const cloudflaredConfigPath = path.join(WORKDIR, '.cloudflared', 'config.yml');

// cloudflared 启动命令：使用 --config（两个破折号）并 run 隧道
const cloudflaredRunCommand = `${cloudflaredPath} tunnel --no-autoupdate run --config ${cloudflaredConfigPath}`;

// ---------------------------
// 小工具：等待文件出现（异步）
// ---------------------------
function waitForFile(filePath, retries = 40, delayMs = 3000) {
  return new Promise((resolve) => {
    let remaining = retries;
    const check = () => {
      if (fs.existsSync(filePath)) {
        resolve(true);
        return;
      }
      remaining -= 1;
      if (remaining <= 0) {
        resolve(false);
        return;
      }
      console.log(`[wait] ${filePath} not found, retrying in ${Math.round(delayMs/1000)}s... (${remaining} attempts left)`);
      setTimeout(check, delayMs);
    };
    check();
  });
}

// ---------------------------
// 启动函数（使用 exec，保留原始风格）
// ---------------------------
function runCommand(command, name) {
  console.log(`[Launcher] Starting ${name} -> ${command}`);
  try {
    const child = exec(command, { env: process.env });

    child.stdout.on('data', (data) => {
      process.stdout.write(`[${name}] ${data}`);
    });

    child.stderr.on('data', (data) => {
      process.stderr.write(`[${name} ERROR] ${data}`);
    });

    child.on('close', (code, signal) => {
      console.log(`[Launcher] ${name} exited with code ${code} signal ${signal}`);
    });

    return child;
  } catch (err) {
    console.error(`[Launcher] Failed to start ${name}: ${err && err.message ? err.message : err}`);
    return null;
  }
}

// ---------------------------
// 启动 Xray 与 Hysteria2（立即启动）
// ---------------------------
runCommand(xrayCommand, 'Xray');
runCommand(hy2Command, 'Hysteria2');

// ---------------------------
// 启动 cloudflared：
// - 不会触发交互登录（install.sh 保持原有交互）
// - 但会等待短时间让 install.sh 完成并写入 config.yml/cert.pem
// ---------------------------
(async () => {
  // 如果 cloudflared 不存在，直接输出警告并返回
  if (!fs.existsSync(cloudflaredPath)) {
    console.warn('[Launcher] cloudflared binary not found at', cloudflaredPath, '— skipping Cloudflared start.');
    return;
  }

  // 等待 config.yml（install.sh 会在交互登录时写入）
  const ok = await waitForFile(cloudflaredConfigPath, 40, 3000); // 最多等待 40*3s = 120s
  if (!ok) {
    console.warn('[Launcher] cloudflared config.yml not found after waiting — skipping Cloudflared start. If you used interactive login during install, ensure cert and config exist before switching startup to node app.js.');
    return;
  }

  // 如果 config.yml 存在，但 cert.pem 丢失也警告（因为有些 cloudflared 版本需要 cert.pem）
  const certPath = path.join(path.dirname(cloudflaredConfigPath), 'cert.pem');
  if (!fs.existsSync(certPath)) {
    console.warn('[Launcher] cert.pem not found at', certPath, '. Cloudflared may still run if credentials json exists, but interactive login normally creates cert.pem.');
  }

  // 最终启动 cloudflared（以 config.yml 为准）
  runCommand(cloudflaredRunCommand, 'Cloudflared');
})();

// 保持主进程不退出
setInterval(() => {}, 1000 * 60 * 60);
JS
