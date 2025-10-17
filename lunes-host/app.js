cat > /home/container/app.js <<'JS'
const { exec } = require('child_process');
const path = require('path');

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
// 【新增】定义 config.yml 的路径
const cloudflaredConfigPath = path.join(WORKDIR, '.cloudflared', 'config.yml');

// 【修改】使用 -f 参数指定 config.yml 文件，这是运行已配置隧道的标准方式。
// 注意：原始脚本中没有TUNNEL_TOKEN，所以我们使用依赖 cert.pem 的方式.
const cloudflaredRunCommand = `${cloudflaredPath} tunnel --no-autoupdate run --config ${cloudflaredConfigPath}`;


// ---------------------------
// 启动函数
// ---------------------------
function runCommand(command, name) {
  console.log(`[Launcher] Starting ${name}...`);
  const child = exec(command);

  // 将子进程的输出实时打印到主进程的控制台
  child.stdout.on('data', (data) => {
    process.stdout.write(`[${name}] ${data}`);
  });

  child.stderr.on('data', (data) => {
    process.stderr.write(`[${name} ERROR] ${data}`);
  });

  child.on('close', (code) => {
    console.log(`[Launcher] ${name} exited with code ${code}`);
  });

  return child;
}

// ---------------------------
// 启动所有服务
// ---------------------------
runCommand(xrayCommand, 'Xray');
runCommand(hy2Command, 'Hysteria2');
runCommand(cloudflaredRunCommand, 'Cloudflared'); // 使用修改后的命令

console.log('[Launcher] All services are being started.');

// 防止主进程退出
setInterval(() => {}, 1000 * 60 * 60);
JS
