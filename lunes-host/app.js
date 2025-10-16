// app.js - spawn services, cloudflared: prefer "tunnel run <UUID> --credentials-file <file>"
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const WORKDIR = '/home/container';
const LOGDIR = path.join(WORKDIR, 'logs');
if (!fs.existsSync(LOGDIR)) fs.mkdirSync(LOGDIR, { recursive: true });

const xrayPath = path.join(WORKDIR, 'xy', 'xy');
const xrayConfigPath = path.join(WORKDIR, 'xy', 'config.json');

const hy2Path = path.join(WORKDIR, 'h2', 'h2');
const hy2ConfigPath = path.join(WORKDIR, 'h2', 'config.yaml');

const cloudflaredPath = path.join(WORKDIR, 'cloudflared');
const cloudflaredConfigPath = path.join(WORKDIR, '.cloudflared', 'config.yml');

function fileExists(p) {
  try { return fs.existsSync(p); } catch (e) { return false; }
}

function spawnService(bin, args, name, logfile) {
  const out = fs.createWriteStream(logfile, { flags: 'a' });
  console.log(`[Launcher] spawning ${name}: ${bin} ${args.join(' ')}`);
  out.write(`[Launcher] spawning ${name}: ${bin} ${args.join(' ')}\n`);
  const child = spawn(bin, args, { stdio: ['ignore', 'pipe', 'pipe'] });

  child.stdout.on('data', (d) => {
    const s = `[${name}] ${d.toString()}`;
    process.stdout.write(s);
    out.write(s);
  });
  child.stderr.on('data', (d) => {
    const s = `[${name} ERROR] ${d.toString()}`;
    process.stderr.write(s);
    out.write(s);
  });
  child.on('close', (code, signal) => {
    const msg = `[Launcher] ${name} exited code=${code} signal=${signal}\n`;
    process.stdout.write(msg);
    out.write(msg);
    out.end();
  });

  return child;
}

// Start Xray
if (!fileExists(xrayPath)) {
  console.error(`[Launcher ERROR] Xray binary not found at ${xrayPath}`);
} else {
  spawnService(xrayPath, ['-config', xrayConfigPath], 'Xray', path.join(LOGDIR, 'xray.log'));
}

// Start Hysteria2
if (!fileExists(hy2Path)) {
  console.error(`[Launcher ERROR] Hysteria2 binary not found at ${hy2Path}`);
} else {
  spawnService(hy2Path, ['server', '--config', hy2ConfigPath], 'Hysteria2', path.join(LOGDIR, 'hysteria2.log'));
}

// Cloudflared: pick the safest run command
function prepareCloudflaredArgs(cfgPath) {
  // If cloudflared binary missing, return error
  if (!fileExists(cloudflaredPath)) {
    return { ok: false, msg: `cloudflared binary not found at ${cloudflaredPath}` };
  }
  if (!fileExists(cfgPath)) {
    // Try to run without config (it will use default path), but warn
    return { ok: true, args: ['tunnel', '--no-autoupdate', 'run', '--config', cfgPath], warn: `config not found at ${cfgPath}` };
  }

  try {
    const cfg = fs.readFileSync(cfgPath, 'utf8');
    // extract tunnel id/name
    const tunnelMatch = cfg.match(/^\s*tunnel:\s*(.+)\s*$/m);
    // extract credentials-file path (may be absolute or relative)
    const credMatch = cfg.match(/^\s*credentials-file:\s*(.+)\s*$/m);

    let tunnel = tunnelMatch ? tunnelMatch[1].trim().replace(/^["']|["']$/g, '') : null;
    let cred = credMatch ? credMatch[1].trim().replace(/^["']|["']$/g, '') : null;

    // If credentials-file is relative, make it absolute relative to WORKDIR/.cloudflared
    if (cred && !path.isAbsolute(cred)) {
      cred = path.join(path.dirname(cfgPath), cred);
    }

    // Prefer "tunnel run <TUNNEL> --credentials-file <file>"
    if (tunnel) {
      const args = ['tunnel', '--no-autoupdate', 'run', tunnel];
      if (cred) {
        if (!fileExists(cred)) {
          return { ok: false, msg: `credentials-file referenced in config but missing: ${cred}` };
        }
        args.push('--credentials-file', cred);
      }
      return { ok: true, args, info: `using tunnel run ${tunnel}` };
    }

    // fallback: pass config as --config
    return { ok: true, args: ['tunnel', '--no-autoupdate', 'run', '--config', cfgPath], info: 'fallback to --config' };
  } catch (e) {
    return { ok: false, msg: `failed to read config: ${e.message}` };
  }
}

const cloudRes = prepareCloudflaredArgs(cloudflaredConfigPath);
if (!cloudRes.ok) {
  console.error('[Launcher ERROR] Cloudflared preparation failed:', cloudRes.msg);
  console.error('[Launcher] You can try to run cloudflared manually to see the full error.');
} else {
  if (cloudRes.warn) console.warn('[Launcher WARN]', cloudRes.warn);
  if (cloudRes.info) console.log('[Launcher INFO]', cloudRes.info);
  spawnService(cloudflaredPath, cloudRes.args, 'Cloudflared', path.join(LOGDIR, 'cloudflared.log'));
}

console.log('[Launcher] spawn attempts done. Check logs in', LOGDIR);
setInterval(() => {}, 1000 * 60 * 60);
