const { spawn } = require("child_process");

// Binary and config definitions (only Reality/Xray)
const apps = [
  {
    name: "xy",
    binaryPath: "/home/container/xy/xy",
    args: ["-c", "/home/container/xy/config.json"]
  }
];

// Run binary with keep-alive
function runProcess(app) {
  const child = spawn(app.binaryPath, app.args, { stdio: "inherit" });

  child.on("exit", (code) => {
    console.log(`[EXIT] ${app.name} exited with code: ${code}`);
    console.log(`[RESTART] Restarting ${app.name}...`);
    setTimeout(() => runProcess(app), 3000); // restart after 3s
  });

  child.on("error", (err) => {
    console.error(`[ERROR] Failed to start ${app.name}:`, err.message);
    // retry after 5 seconds if binary missing
    setTimeout(() => runProcess(app), 5000);
  });
}

// Main execution
function main() {
  try {
    for (const app of apps) {
      runProcess(app);
    }
  } catch (err) {
    console.error("[ERROR] Startup failed:", err);
    process.exit(1);
  }
}

main();
