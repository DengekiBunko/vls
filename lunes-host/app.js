const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");

// 检查文件存在（带重试）
function waitForFile(file, retries = 30, delay = 3000) {
  return new Promise((resolve, reject) => {
    const check = () => {
      if (fs.existsSync(file)) return resolve(true);
      if (retries <= 0) return reject(`❌ File not found: ${file}`);
      console.log(`[cloudflared] waiting for ${file}... (${retries} left)`);
      retries--;
      setTimeout(check, delay);
    };
    check();
  });
}

// 启动并保持进程
function runProcess(app) {
  console.log(`[start] ${app.name}`);
  const proc = spawn(app.binaryPath, app.args, { stdio: "inherit" });
  proc.on("exit", (code) => {
    console.log(`[restart] ${app.name} exited (${code}), restarting...`);
    setTimeout(() => runProcess(app), 5000);
  });
}

(async () => {
  // 启动 Xray
  runProcess({
    name: "xray",
    binaryPath: "/home/container/xy/xy",
    args: ["-c", "/home/container/xy/config.json"]
  });

  // 启动 Hysteria2
  runProcess({
    name: "hysteria2",
    binaryPath: "/home/container/h2/h2",
    args: ["server", "-c", "/home/container/h2/config.yaml"]
  });

  // 等待 cloudflared 的 config.yml
  const cfDir = "/home/container/.cloudflared";
  const configFile = path.join(cfDir, "config.yml");
  const credFile = fs.existsSync(cfDir)
    ? fs.readdirSync(cfDir).find((f) => f.endsWith(".json"))
    : null;

  try {
    await waitForFile(configFile);
    console.log(`[cloudflared] config found: ${configFile}`);

    if (!credFile) {
      console.warn("[cloudflared] warning: credential file not found, tunnel may fail!");
    }

    runProcess({
      name: "cloudflared",
      binaryPath: "/home/container/cloudflared",
      args: ["--config", configFile, "tunnel", "run"]
    });
  } catch (err) {
    console.error(err);
  }
})();
