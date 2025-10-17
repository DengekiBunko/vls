// app.js
// 完整：先启动 cloudflared 临时隧道、等待并解析 trycloudflare 域名，
// 再更新 Xray config.json 并启动 xy（vless），同时启动 h2（hysteria）
// 自动重启逻辑：xy/h2 若退出会自动重启

const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");

const WORKDIR = process.env.WORKDIR || "/home/container";
const CLOUDFLARED_BIN = path.join(WORKDIR, "cloudflared");
const XY_BIN = path.join(WORKDIR, "xy", "xy");
const XY_CONFIG = path.join(WORKDIR, "xy", "config.json");
const H2_BIN = path.join(WORKDIR, "h2", "h2");
const H2_CONFIG = path.join(WORKDIR, "h2", "config.yaml");
const NODE_TXT = path.join(WORKDIR, "node.txt");

// env defaults (与 install.sh 保持一致)
const CONTAINER_DOMAIN = process.env.DOMAIN || "localhost"; // 容器自己的域名（用于 hy2 直连）
const PORT = process.env.PORT || "10008";
const UUID = process.env.UUID || "";
const HY2_PASSWORD = process.env.HY2_PASSWORD || "";
const WS_PATH = process.env.WS_PATH || "/wspath";

// how long to wait for cloudflared domain (ms)
const TUNNEL_TIMEOUT = 90 * 1000;
const TUNNEL_POLL_INTERVAL = 1000;

console.log(`[init] WORKDIR=${WORKDIR} DOMAIN(env)=${CONTAINER_DOMAIN} PORT=${PORT} UUID=${UUID}`);

// util: restartable process
function runKeepAlive(name, bin, args = [], opts = {}) {
  let child = null;

  function start() {
    console.log(`[${name}] starting: ${bin} ${args.join(" ")}`);
    child = spawn(bin, args, Object.assign({ stdio: "inherit" }, opts));

    child.on("exit", (code, sig) => {
      console.log(`[${name}] exited with code=${code} sig=${sig}, restarting in 3s...`);
      setTimeout(start, 3000);
    });

    child.on("error", (err) => {
      console.error(`[${name}] failed to start:`, err && err.message ? err.message : err);
      setTimeout(start, 5000);
    });
  }

  start();
  return () => {
    if (child) child.kill();
  };
}

// start cloudflared quick tunnel and wait for trycloudflare domain
function startTunnelAndGetDomain() {
  return new Promise((resolve, reject) => {
    if (!fs.existsSync(CLOUDFLARED_BIN)) {
      return reject(new Error(`cloudflared not found at ${CLOUDFLARED_BIN}`));
    }

    console.log("[cloudflared] launching quick tunnel...");
    const args = ["tunnel", "--url", `http://127.0.0.1:${PORT}`];
    // add --no-autoupdate to avoid auto-update message in some versions
    args.push("--no-autoupdate");

    const proc = spawn(CLOUDFLARED_BIN, args, { stdio: ["ignore", "pipe", "pipe"] });

    let domain = null;
    let stdoutBuffer = "";
    let stderrBuffer = "";

    function checkLineForDomain(line) {
      // match https://xxx.trycloudflare.com 形式
      const m = line.match(/https?:\/\/([a-z0-9-]+\.trycloudflare\.com)/i);
      if (m && m[1]) {
        domain = m[1];
        console.log("[cloudflared] detected temporary domain:", domain);
        cleanupAndResolve();
      }
    }

    function cleanupAndResolve() {
      // do not kill cloudflared here — keep it running to maintain tunnel
      resolve(domain);
    }

    proc.stdout.on("data", (d) => {
      const text = d.toString();
      process.stdout.write(text);
      stdoutBuffer += text;
      // split lines and check latest chunk
      const lines = stdoutBuffer.split(/\r?\n/);
      // keep last partial line in buffer
      stdoutBuffer = lines.pop();
      for (const ln of lines) {
        checkLineForDomain(ln);
      }
    });

    proc.stderr.on("data", (d) => {
      const text = d.toString();
      process.stderr.write(text);
      stderrBuffer += text;
      const lines = stderrBuffer.split(/\r?\n/);
      stderrBuffer = lines.pop();
      for (const ln of lines) {
        checkLineForDomain(ln);
      }
    });

    proc.on("exit", (code) => {
      if (!domain) {
        reject(new Error(`cloudflared exited early with code ${code} and no domain`));
      }
    });

    // timeout guard
    const timeout = setTimeout(() => {
      if (domain) return; // already resolved
      console.error("[cloudflared] timeout waiting for trycloudflare domain");
      // attempt to resolve using fallback domain (container domain) to avoid localhost
      const fallback = CONTAINER_DOMAIN || "localhost";
      console.log(`[cloudflared] using fallback domain: ${fallback}`);
      resolve(fallback);
    }, TUNNEL_TIMEOUT);
  });
}

// update xray config.json with host / sni / ws headers
function updateXrayConfig(tempDomain) {
  try {
    if (!fs.existsSync(XY_CONFIG)) {
      console.warn(`[xy] config.json not found at ${XY_CONFIG}, skipping update.`);
      return;
    }
    const raw = fs.readFileSync(XY_CONFIG, "utf8");
    let cfg = JSON.parse(raw);

    if (!Array.isArray(cfg.inbounds) || cfg.inbounds.length === 0) {
      console.warn("[xy] config.json has no inbounds, skipping.");
    } else {
      // update first vless inbound that matches
      for (let ib of cfg.inbounds) {
        if (ib && ib.protocol && ib.protocol.toLowerCase() === "vless") {
          if (!ib.streamSettings) ib.streamSettings = {};
          const ss = ib.streamSettings;
          // ensure wsSettings object exists
          if (!ss.wsSettings) ss.wsSettings = {};
          if (!ss.wsSettings.headers) ss.wsSettings.headers = {};
          ss.wsSettings.path = WS_PATH;
          // set Host header to tunnel domain
          ss.wsSettings.headers.Host = tempDomain;
          // set TLS serverName
          if (!ss.tlsSettings) ss.tlsSettings = {};
          ss.tlsSettings.serverName = tempDomain;
        }
      }
    }

    fs.writeFileSync(XY_CONFIG, JSON.stringify(cfg, null, 2), "utf8");
    console.log("[xy] config.json updated with domain:", tempDomain);
  } catch (err) {
    console.error("[xy] failed to update config.json:", err && err.message ? err.message : err);
  }
}

// build vless and hy2 urls and write node.txt
function writeNodeTxt(tempDomain) {
  try {
    // encode path and hy2 password
    const encPath = encodeURIComponent(WS_PATH);
    const encHy2Pwd = encodeURIComponent(HY2_PASSWORD);

    const vless = `vless://${UUID}@${tempDomain}:443?encryption=none&security=tls&type=ws&host=${tempDomain}&path=${encPath}&sni=${tempDomain}#lunes-ws-tls`;
    const hy2 = `hysteria2://${encHy2Pwd}@${CONTAINER_DOMAIN}:${PORT}?insecure=1#lunes-hy2`;

    const content = `${vless}\n${hy2}\n`;
    fs.writeFileSync(NODE_TXT, content, "utf8");
    console.log("[node.txt] wrote vless & hy2 to", NODE_TXT);
    console.log("VLESS:", vless);
    console.log("HY2:", hy2);
  } catch (err) {
    console.error("[node.txt] failed to write:", err && err.message ? err.message : err);
  }
}

(async () => {
  try {
    // 1) start cloudflared and wait for domain
    let tempDomain;
    try {
      tempDomain = await startTunnelAndGetDomain();
    } catch (e) {
      console.error("[cloudflared] error while starting tunnel:", e && e.message ? e.message : e);
      // fallback to container domain (avoid using literal 'localhost' when possible)
      tempDomain = CONTAINER_DOMAIN || "localhost";
    }

    console.log("[main] using domain:", tempDomain);

    // 2) update Xray config.json with the domain BEFORE starting xy
    updateXrayConfig(tempDomain);

    // 3) write node.txt so external tools/readers can get correct links
    writeNodeTxt(tempDomain);

    // 4) start h2 (hysteria) and xy (xray) with keep-alive
    // start h2 first (it uses direct container domain)
    if (fs.existsSync(H2_BIN)) {
      runKeepAlive("h2", H2_BIN, ["server", "-c", H2_CONFIG]);
    } else {
      console.warn(`[h2] binary not found at ${H2_BIN}, skipping h2 start.`);
    }

    // start xy (xray)
    if (fs.existsSync(XY_BIN)) {
      runKeepAlive("xy", XY_BIN, ["-c", XY_CONFIG]);
    } else {
      console.warn(`[xy] binary not found at ${XY_BIN}, skipping xy start.`);
    }

    console.log("[main] startup sequence complete. cloudflared remains running to keep the tunnel alive.");
  } catch (err) {
    console.error("[main] fatal error:", err && err.message ? err.message : err);
    process.exit(1);
  }
})();
