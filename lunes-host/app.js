const { spawn } = require("child_process");

// 要运行的进程列表
const apps = [
  // Xray (VLESS WS+TLS)
  {
    name: "xray",
    binaryPath: "/home/container/xy/xy",
    args: ["-c", "/home/container/xy/config.json"]
  },
  // Hysteria2
  {
    name: "hysteria2",
    binaryPath: "/home/container/h2/h2",
    args: ["server", "-c", "/home/container/h2/config.yaml"]
  },
  // Cloudflared 隧道
  {
    name: "cloudflared",
    binaryPath: "/home/container/cloudflared",
    args: ["--config", "/home/container/.cloudflared/config.yml", "tunnel", "run"]
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

apps.forEach(runProcess);
