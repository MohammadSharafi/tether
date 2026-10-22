// One-time setup: run the server at login (launchd on macOS, the Startup folder on Windows),
// expose it over Tailscale, show the pairing QR code.
//   node setup.mjs             install + expose + pair
//   node setup.mjs --pair      only show the pairing QR code
//   node setup.mjs --dry-run   print the login item, change nothing
//   node setup.mjs --uninstall remove the login item
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync, spawn } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import qrcode from 'qrcode-terminal';
import { loadToken, STATE_DIR } from './server.mjs';

const LABEL = 'dev.tether.server';
const PORT = Number(process.env.PORT ?? 8787);
const here = path.dirname(fileURLToPath(import.meta.url));
const plistPath = path.join(os.homedir(), 'Library', 'LaunchAgents', `${LABEL}.plist`);
const args = new Set(process.argv.slice(2));
const WIN = process.platform === 'win32';

const xml = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

// Prefer the stable Homebrew link over the versioned Cellar path, which breaks on `brew upgrade`.
const nodePath = ['/opt/homebrew/bin/node', '/usr/local/bin/node']
  .find((p) => fs.existsSync(p) && fs.realpathSync(p) === fs.realpathSync(process.execPath)) ?? process.execPath;

export function plist() {
  const env = {
    HOME: os.homedir(),
    PATH: process.env.PATH, // Claude's Bash tool needs the same tools you have in Terminal
    ...(process.env.CLAUDE_CONFIG_DIR && { CLAUDE_CONFIG_DIR: process.env.CLAUDE_CONFIG_DIR }),
    PORT: String(PORT),
  };
  const log = path.join(STATE_DIR, 'server.log');
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array><string>${xml(nodePath)}</string><string>${xml(path.join(here, 'server.mjs'))}</string></array>
  <key>WorkingDirectory</key><string>${xml(here)}</string>
  <key>EnvironmentVariables</key>
  <dict>
${Object.entries(env).map(([k, v]) => `    <key>${k}</key><string>${xml(v)}</string>`).join('\n')}
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${xml(log)}</string>
  <key>StandardErrorPath</key><string>${xml(log)}</string>
</dict>
</plist>
`;
}

// Windows login item: a hidden launcher in the Startup folder runs start.cmd, which restarts the server if it stops.
// No admin rights and no Task Scheduler needed. PATH comes from the user's own login session.
export function windowsLauncher({ node = process.execPath, dir = here, state = STATE_DIR, env = process.env } = {}) {
  const q = (v) => String(v).replace(/%/g, '%%');   // cmd expands %VAR%; keep literal percent signs
  const cmdPath = path.win32.join(state, 'start.cmd');
  const sets = [`set "PORT=${q(env.PORT ?? PORT)}"`, ...(env.CLAUDE_CONFIG_DIR ? [`set "CLAUDE_CONFIG_DIR=${q(env.CLAUDE_CONFIG_DIR)}"`] : [])];
  const cmd = ['@echo off', 'rem Tether server launcher, written by setup.mjs. Restarts the server if it stops.', ...sets,
    `cd /d "${q(dir)}"`, ':loop', `"${q(node)}" "${q(path.win32.join(dir, 'server.mjs'))}" >> "${q(path.win32.join(state, 'server.log'))}" 2>&1`,
    'timeout /t 5 /nobreak >nul', 'goto loop', ''].join('\r\n');
  // Window style 0 = hidden, so no console window appears at login.
  const vbs = `CreateObject("WScript.Shell").Run """${cmdPath}""", 0, False\r\n`;
  return { cmd, cmdPath, vbs };
}
const startupVbs = () => path.join(process.env.APPDATA ?? '', 'Microsoft', 'Windows', 'Start Menu', 'Programs', 'Startup', 'Tether.vbs');
// Stops the launcher loop and its server (matched by the launcher's own path on the command line).
function stopWindowsServer() {
  const ps = `Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*${path.join(STATE_DIR, 'start.cmd').replace(/'/g, "''")}*' } | ForEach-Object { taskkill /PID $_.ProcessId /T /F | Out-Null }`;
  try { execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', ps], { stdio: 'ignore', windowsHide: true }); } catch {}
}

function tailscaleCli() {
  for (const c of ['tailscale', '/Applications/Tailscale.app/Contents/MacOS/Tailscale', 'C:\\Program Files\\Tailscale\\tailscale.exe']) {
    try { execFileSync(c, ['version'], { stdio: 'ignore' }); return c; } catch {}
  }
  return null;
}

// The https address of this Mac on your tailnet, or PUBLIC_URL if you expose the server another way.
function publicUrl(cli) {
  if (process.env.PUBLIC_URL) return process.env.PUBLIC_URL;
  if (!cli) return null;
  try {
    const dns = JSON.parse(execFileSync(cli, ['status', '--json'], { encoding: 'utf8' })).Self?.DNSName?.replace(/\.$/, '');
    return dns ? `https://${dns}` : null;
  } catch { return null; }
}

function showPairing(url) {
  const link = `tether://pair?url=${encodeURIComponent(url)}&token=${encodeURIComponent(loadToken())}`;
  console.log('\nScan this with your phone camera to pair the app:\n');
  qrcode.generate(link, { small: true });
  console.log(`Server address: ${url}\n`);
}

const uid = os.userInfo().uid;
const launchctl = (...a) => { try { execFileSync('launchctl', a, { stdio: 'ignore' }); return true; } catch { return false; } };

if (!process.argv[1] || import.meta.url !== pathToFileURL(process.argv[1]).href) {
  // imported (tests): do nothing
} else if (args.has('--dry-run')) {
  if (WIN) { const w = windowsLauncher(); console.log(`${w.cmdPath}:\n${w.cmd}\n${startupVbs()}:\n${w.vbs}`); } else console.log(plist());
} else if (args.has('--uninstall')) {
  if (WIN) { stopWindowsServer(); fs.rmSync(startupVbs(), { force: true }); }
  else { launchctl('bootout', `gui/${uid}/${LABEL}`); fs.rmSync(plistPath, { force: true }); }
  console.log('Removed the login item. The server no longer starts at login.');
} else {
  const cli = tailscaleCli();
  if (!args.has('--pair') && WIN) {
    loadToken(); // creates the token on first run
    const w = windowsLauncher();
    fs.mkdirSync(STATE_DIR, { recursive: true });
    fs.writeFileSync(w.cmdPath, w.cmd);
    fs.mkdirSync(path.dirname(startupVbs()), { recursive: true });
    fs.writeFileSync(startupVbs(), w.vbs);
    stopWindowsServer(); // restart if already running
    spawn('wscript.exe', [startupVbs()], { detached: true, stdio: 'ignore', windowsHide: true }).unref();
    console.log(`Server installed: starts at login, restarts if it stops. Log: ${path.join(STATE_DIR, 'server.log')}`);
    if (cli) execFileSync(cli, ['serve', '--bg', String(PORT)], { stdio: 'inherit' });
  } else if (!args.has('--pair')) {
    loadToken(); // creates the token on first run
    fs.mkdirSync(path.dirname(plistPath), { recursive: true });
    fs.writeFileSync(plistPath, plist());
    launchctl('bootout', `gui/${uid}/${LABEL}`); // restart if already installed
    // bootout returns before the old job is gone, and bootstrap fails until it is: retry for up to 10 s.
    const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
    let loaded = false;
    for (let i = 0; i < 20 && !(loaded = launchctl('bootstrap', `gui/${uid}`, plistPath)); i++) sleep(500);
    if (!loaded) throw new Error(`launchctl could not load ${plistPath}`);
    console.log(`Server installed: starts at login, restarts if it stops. Log: ${path.join(STATE_DIR, 'server.log')}`);
    if (cli) {
      execFileSync(cli, ['serve', '--bg', String(PORT)], { stdio: 'inherit' });
    }
  }
  const url = publicUrl(cli);
  if (url) showPairing(url);
  else {
    console.log('\nTailscale was not found. Install it from https://tailscale.com/download on this computer and your phone,');
    console.log('sign in to the same account on both, then run: npm run setup');
  }
}
