const { spawn } = require("child_process");
const fs = require("fs");

// 检查文件是否存在的异步函数
function waitForFile(path, retries = 20, delay = 3000) {
  return new Promise((resolve, reject) => {
    const check = () => {
      if (fs.existsSync(path)) return resolve(true);
      if (retries <= 0) return reject(`File not found: ${path}`);
      console.log(`[wait] ${path} not found, retrying in ${delay / 1000}s...`);
      retries--;
      setTimeout(check, delay);
    };
    check();
  });
}

const apps = [
  {
    name: "xray",
    binaryPath: "/home/container/xy/xy",
    args: ["-c", "/home/container/xy/config.json"]
  },
  {
    name: "hysteria2",
    binaryPath: "/home/container/h2/h2",
    args: ["server", "-c", "/home/container/h2/config.yaml"]
  }
];

// 启动并保持进程
function runProcess(app) {
  const proc = spawn(app.binaryPath, app.args, { stdio: "inherit" });
  proc.on("exit", (code) => {
    console.log(`[${app.name}] exited with code ${code}, restarting...`);
    setTimeout(() => runProcess(app), 3000);
  });
}

// 启动主进程
apps.forEach(runProcess);

// 额外启动 Cloudflared（在配置文件生成后）
(async () => {
  const configPath = "/home/container/.cloudflared/config.yml";
  try {
    await waitForFile(configPath, 20, 3000);
    console.log(`[cloudflared] config.yml found, starting tunnel...`);
    runProcess({
      name: "cloudflared",
      binaryPath: "/home/container/cloudflared",
      args: ["--config", configPath, "tunnel", "run"]
    });
  } catch (err) {
    console.error(`[cloudflared] start skipped: ${err}`);
  }
})();
