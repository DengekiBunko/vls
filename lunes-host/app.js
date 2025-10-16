// app.js - starts cloudflared (if token/name), then xy (xray), then h2 (hysteria)
// Restart children on exit.
const { spawn, execSync } = require('child_process');
const fs = require('fs');

const CFTUNNEL_TOKEN = process.env.CFTUNNEL_TOKEN || '';
const CFTUNNEL_NAME = process.env.CFTUNNEL_NAME || ''; // optional: explicit tunnel name or ID
const CLOUD_FLARE_BIN = '/home/container/cloudflared';
const XY_BIN = '/home/container/xy/xy';
const H2_BIN = '/home/container/h2/h2';

function runProcess(name, cmd, args, cwd) {
  console.log(`[START] ${name}: ${cmd} ${args.join(' ')}`);
  const child = spawn(cmd, args, { stdio: 'inherit', cwd: cwd || undefined, env: process.env });
  child.on('exit', (code, signal) => {
    console.log(`[EXIT] ${name} exited (code=${code} signal=${signal}). Restarting in 3s...`);
    setTimeout(() => runProcess(name, cmd, args, cwd), 3000);
  });
  child.on('error', (err) => {
    console.error(`[ERROR] ${name} failed to start:`, err.message);
    setTimeout(() => runProcess(name, cmd, args, cwd), 5000);
  });
  return child;
}

function startCloudflaredIfNeeded() {
  if (!fs.existsSync(CLOUD_FLARE_BIN)) {
    console.warn('[WARN] cloudflared binary not found at', CLOUD_FLARE_BIN);
    return null;
  }
  if (!CFTUNNEL_TOKEN && !CFTUNNEL_NAME) {
    console.warn('[WARN] No CFTUNNEL_TOKEN or CFTUNNEL_NAME provided; not starting cloudflared.');
    return null;
  }

  try {
    // If user provided explicit name/ID, try to run it directly
    if (CFTUNNEL_NAME) {
      console.log('[INFO] Starting cloudflared with provided tunnel name:', CFTUNNEL_NAME);
      return runProcess('cloudflared', CLOUD_FLARE_BIN, ['tunnel', 'run', CFTUNNEL_NAME, '--token', CFTUNNEL_TOKEN], '/home/container');
    }

    // Otherwise, try to list tunnels with token and pick the first
    if (CFTUNNEL_TOKEN) {
      try {
        console.log('[INFO] Attempting to list tunnels using provided token...');
        const out = execSync(`${CLOUD_FLARE_BIN} tunnel list --token "${CFTUNNEL_TOKEN}"`, { encoding: 'utf8', stdio: ['pipe','pipe','pipe'] });
        // parse lines, skip header
        const lines = out.split(/\r?\n/).map(l => l.trim()).filter(Boolean);
        // look for line that looks like "NAME... TUNNEL ID ..." - choose first data line
        // Some versions print a table; take the first non-header line
        if (lines.length >= 2) {
          // If table header present, take the 2nd line
          const candidateLine = lines[1];
          // The name is typically the first whitespace-separated token
          const name = candidateLine.split(/\s+/)[0];
          if (name) {
            console.log('[INFO] Found tunnel name from list:', name);
            return runProcess('cloudflared', CLOUD_FLARE_BIN, ['tunnel', 'run', name, '--token', CFTUNNEL_TOKEN], '/home/container');
          }
        }
        console.warn('[WARN] Could not parse tunnel name from cloudflared list output, falling back to token-run.');
      } catch (e) {
        console.warn('[WARN] cloudflared tunnel list failed:', e.message);
      }
      // fallback: try token-only run (some cloudflared versions accept this)
      console.log('[INFO] Trying cloudflared tunnel run --token <token> (fallback)');
      return runProcess('cloudflared', CLOUD_FLARE_BIN, ['tunnel', 'run', '--token', CFTUNNEL_TOKEN], '/home/container');
    }
  } catch (err) {
    console.error('[ERROR] Failed to start cloudflared:', err.message);
    return null;
  }
}

// Main
(function main() {
  // 1) start cloudflared if requested
  const cf = startCloudflaredIfNeeded();

  // wait a bit for cloudflared to establish tunnel (if started)
  const waitMs = cf ? 6000 : 0;
  if (waitMs > 0) {
    console.log(`[INFO] Waiting ${waitMs}ms for cloudflared to initialize...`);
  }

  setTimeout(() => {
    // 2) start xray (xy)
    runProcess('xy', XY_BIN, ['-c', '/home/container/xy/config.json'], '/home/container/xy');

    // 3) start h2
    runProcess('h2', H2_BIN, ['server', '-c', '/home/container/h2/config.yaml'], '/home/container/h2');

  }, waitMs);

  // graceful exit handlers
  process.on('SIGINT', () => { console.log('[SIGINT] Exiting...'); process.exit(0); });
  process.on('SIGTERM', () => { console.log('[SIGTERM] Exiting...'); process.exit(0); });
})();
