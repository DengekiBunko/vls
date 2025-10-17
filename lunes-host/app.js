const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");

// 基础路径与变量
const WORKDIR = "/home/container";
const DOMAIN = process.env.DOMAIN || "node68.lunes.host";
const PORT = process.env.PORT || "10008";
const UUID = process.env.UUID || "2584b733-2b32-4036-8e26-df7b984f7f9e";
const HY2_PASSWORD = process.env.HY2_PASSWORD || "vevc.HY2.Password";
const WS_PATH = process.env.WS_PATH || "/wspath";

const CLOUDFLARED = path.join(WORKDIR, "cloudflared");
const CF_LOG = path.join(WORKDIR, "cloudflared.log");
const NODE_TXT = path.join(WORKDIR, "node.txt");

function log(...args) {
  console.log("[Launcher]", ...args);
}

// 运行命令并实时输出
function runProcess(name, cmd, args, options = {}) {
  const p = spawn(cmd, args, { stdio: "pipe", ...options });
  p.stdout.on("data", (d) => process.stdout.write(`[${name}] ${d}`));
  p.stderr.on("data", (d) => process.stderr.write(`[${name} ERROR] ${d}`));
  p.on("exit", (code) => log(`${name} exited with code ${code}`));
  return p;
}

// 提取 cloudflared 临时域名
function extractTunnelHost(logPath) {
  if (!fs.existsSync(logPath)) return null;
  const logText = fs.readFileSync(logPath, "utf8");
  const regexList = [
    /https?:\/\/([a-z0-9-]+\.trycloudflare\.com)/i,
    /([a-z0-9-]+\.trycloudflare\.com)/i,
    /https?:\/\/([a-z0-9-]+\.cfargotunnel\.com)/i,
    /([a-z0-9-]+\.cfargotunnel\.com)/i,
  ];
  for (const r of regexList) {
    const m = logText.match(r);
    if (m && m[1]) return m[1];
  }
  return null;
}

// -----------------------------
// 启动流程
// -----------------------------
async function main() {
  log("Starting Xray...");
  runProcess("Xray", path.join(WORKDIR, "xy/xy"), ["-c", path.join(WORKDIR, "xy/config.json")]);

  log("Starting Hysteria2...");
  runProcess("Hysteria2", path.join(WORKDIR, "h2/h2"), ["server", "-c", path.join(WORKDIR, "h2/config.yaml")]);

  // 删除旧日志
  try { fs.unlinkSync(CF_LOG); } catch (e) {}

  log("Starting Cloudflared...");
  const cfProc = runProcess("Cloudflared", CLOUDFLARED, ["tunnel", "--url", `http://127.0.0.1:${PORT}`]);

  // 等待 cloudflared 输出域名
  let tunnelHost = null;
  for (let i = 0; i < 120; i++) {
    await new Promise((r) => setTimeout(r, 1000));
    tunnelHost = extractTunnelHost(CF_LOG);
    if (tunnelHost && !tunnelHost.includes("localhost")) break;
  }

  if (!tunnelHost) {
    log("⚠️ No temporary tunnel domain detected, fallback to localhost.");
    tunnelHost = "localhost";
  } else {
    log("✅ Detected tunnel domain:", tunnelHost);
  }

  // 构造节点链接
  const encodedPath = encodeURIComponent(WS_PATH);
  const encodedPwd = encodeURIComponent(HY2_PASSWORD);
  const vlessUrl = `vless://${UUID}@${tunnelHost}:443?encryption=none&security=tls&type=ws&host=${tunnelHost}&path=${encodedPath}&sni=${tunnelHost}#lunes-ws-tls`;
  const hy2Url = `hysteria2://${encodedPwd}@${DOMAIN}:${PORT}?insecure=1#lunes-hy2`;

  fs.writeFileSync(NODE_TXT, `${vlessUrl}\n${hy2Url}\n`, "utf8");

  log("============================================================");
  log("VLESS (via Cloudflare tunnel):", vlessUrl);
  log("HY2 (direct):", hy2Url);
  log("Node info written to:", NODE_TXT);
  log("============================================================");
}

main();
