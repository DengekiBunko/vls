const { spawn } = require("child_process");

const apps = [
  {
    name: "xy",
    binaryPath: "/home/container/xy/xy",
    args: ["-c", "/home/container/xy/config.json"]
  },
  {
    name: "h2",
    binaryPath: "/home/container/h2/h2",
    args: ["server", "-c", "/home/container/h2/config.yaml"]
  }
];

function runProcess(app) {
  const child = spawn(app.binaryPath, app.args, { stdio: "inherit" });
  child.on("exit", (code) => {
    console.log(`[EXIT] ${app.name} exited with code: ${code}`);
    console.log(`[RESTART] Restarting ${app.name}...`);
    setTimeout(() => runProcess(app), 3000);
  });
  child.on("error", (err) => {
    console.error(`[ERROR] Failed to start ${app.name}:`, err.message);
    setTimeout(() => runProcess(app), 5000);
  });
}

function main() {
  for (const app of apps) runProcess(app);
}

main();
