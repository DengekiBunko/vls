// app.js - launcher: start cloudflared temp tunnel, xray, hysteria2, update node.txt
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const WORKDIR = process.env.WORKDIR || '/home/container';
const DOMAIN = process.env.DOMAIN || 'localhost';
const PORT = process.env.PORT || '10008';
const UUID = process.env.UUID || '2584b733-2b32-4036-8e26-df7b984f7f9e';
const HY2_PASSWORD = process.env.HY2_PASSWORD || 'vevc.HY2.Password';
const WS_PATH = process.env.WS_PATH || '/wspath';
const NODE_TXT = path.join(WORKDIR, 'node.txt');
const CLOUD_LOG = path.join(WORKDIR, 'cloudflared-tmp.log');

function spawnStd(name, cmd, args) {
  console.log(`[Launcher] spawn ${name}: ${cmd} ${args.join(' ')}`);
  const p = spawn(cmd, args, { cwd: WORKDIR, stdio: ['ignore', 'pipe', 'pipe'] });
  p.stdout.on('data', (d) => process.stdout.write(`[${name}] ${d.toString()}`));
  p.stderr.on('data', (d) => process.stderr.write(`[${name} ERROR] ${d.toString()}`));
  p.on('exit', (code, signal) => {
    console.log(`[Launcher] ${name} exited code=${code} signal=${signal}`);
    // do not auto-restart here; container orchestrator can restart if desired
  });
  return p;
}

function urlEncode(s) {
  try {
    return encodeURIComponent(s);
  } catch (e) {
    return s;
  }
}

function writeNodeTxt(vlessHost) {
  const encPath = urlEncode(WS_PATH);
  const encPwd = urlEncode(HY2_PASSWORD);
  const vlessUrl = `vless://${UUID}@${vlessHost}:443?encryption=none&security=tls&type=ws&host=${vlessHost}&path=${encPath}&sni=${vlessHost}#lunes-ws-tls`;
  const hy2Url = `hysteria2://${encPwd}@${DOMAIN}:${PORT}?insecure=1#lunes-hy2`;
  fs.writeFileSync(NODE_TXT, vlessUrl + '\n' + hy2Url + '\n', { encoding: 'utf8' });
  console.log('[Launcher] node.txt updated:');
  console.log(vlessUrl);
  console.log(hy2Url);
}

// 1) Start cloudflared temporary tunnel (background, capture log)
const cloudflaredBin = path.join(WORKDIR, 'cloudflared');
if (!fs.existsSync(cloudflaredBin)) {
  console.warn('[Launcher] cloudflared binary not found at', cloudflaredBin, '— Cloudflared will not be started by app.js');
} else {
  // spawn cloudflared and pipe to file and stdout
  const outStream = fs.createWriteStream(CLOUD_LOG, { flags: 'a' });
  const p = spawn(cloudflaredBin, ['tunnel', '--url', `http://127.0.0.1:${PORT}`, 'run'], { cwd: WORKDIR, stdio: ['ignore', 'pipe', 'pipe'] });

  p.stdout.on('data', (d) => {
    process.stdout.write(`[Cloudflared] ${d.toString()}`);
    outStream.write(d);
  });
  p.stderr.on('data', (d) => {
    process.stderr.write(`[Cloudflared ERROR] ${d.toString()}`);
    outStream.write(d);
  });
  p.on('exit', (code, sig) => {
    console.log('[Cloudflared] exited', code, sig);
    outStream.end();
  });

  // wait and try to extract temporary domain from log/stdout
  (async () => {
    const maxAttempts = 30;
    let found = null;
    for (let i = 0; i < maxAttempts; i++) {
      await new Promise(r => setTimeout(r, 1000));
      try {
        const txt = fs.readFileSync(CLOUD_LOG, 'utf8');
        // look for trycloudflare or cfargotunnel domains
        const m = txt.match(/https?:\/\/[a-z0-9.-]+\.trycloudflare\.com/i) ||
                  txt.match(/[a-z0-9-]+\.trycloudflare\.com/i) ||
                  txt.match(/https?:\/\/[a-z0-9.-]+\.cfargotunnel\.com/i) ||
                  txt.match(/[a-z0-9-]+\.cfargotunnel\.com/i);
        if (m) {
          found = m[0].toString();
          // strip leading scheme if present
          found = found.replace(/^https?:\/\//i, '');
          found = found.replace(/\/$/, '');
          break;
        }
      } catch (e) {
        // ignore read errors
      }
    }
    if (!found) {
      console.warn('[Launcher] Could not detect temporary tunnel domain from cloudflared logs; fallback to container DOMAIN:', DOMAIN);
      found = DOMAIN;
    }
    // update node.txt with detected vless host
    writeNodeTxt(found);
  })();
}

// 2) Delay a moment then start Xray and Hysteria2
setTimeout(() => {
  const xrayBin = path.join(WORKDIR, 'xy', 'xy');
  const h2Bin = path.join(WORKDIR, 'h2', 'h2');
  if (fs.existsSync(xrayBin)) {
    spawnStd('Xray', xrayBin, ['-config', path.join(WORKDIR, 'xy', 'config.json')]);
  } else {
    console.warn('[Launcher] Xray binary not found at', xrayBin);
  }
  if (fs.existsSync(h2Bin)) {
    spawnStd('Hysteria2', h2Bin, ['server', '--config', path.join(WORKDIR, 'h2', 'config.yaml')]);
  } else {
    console.warn('[Launcher] Hysteria2 binary not found at', h2Bin);
  }
}, 1500);

// Keep process alive
setInterval(() => {}, 1000 * 60 * 60);
