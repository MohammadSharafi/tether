// What Claude Code is doing on this Mac: its sessions folders, running processes and login state.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFile, execFileSync } from 'node:child_process';

// Every Claude Code config folder with sessions: ~/.claude, ~/.claude-<name>, and $CLAUDE_CONFIG_DIR.
export function configDirs(home = os.homedir(), env = process.env) {
  const dirs = new Set([env.CLAUDE_CONFIG_DIR, path.join(home, '.claude')].filter(Boolean));
  for (const name of fs.readdirSync(home)) if (name.startsWith('.claude-')) dirs.add(path.join(home, name));
  return [...dirs].filter((d) => fs.existsSync(path.join(d, 'projects')));
}

// Claude Code names a project folder after its path with every non-alphanumeric character as "-".
export const projectFolder = (cwd) => cwd.replace(/[^a-zA-Z0-9]/g, '-');

const etimeSeconds = (t) => {
  const [days, rest] = t.includes('-') ? t.split('-') : [0, t];
  return rest.split(':').map(Number).reduce((a, n) => a * 60 + n, 0) + Number(days) * 86400;
};

// Parses `ps -axo pid=,ppid=,etime=,command=` into Claude Code CLI processes, one per session.
export function parseClaudeProcesses(psOutput, now = Date.now()) {
  const rows = [];
  for (const line of psOutput.split('\n')) {
    const m = line.match(/^\s*(\d+)\s+(\d+)\s+([\d:-]+)\s+(.*)$/);
    if (!m) continue;
    const [, pid, ppid, etime, command] = m;
    const exe = command.split(' ')[0];
    // The CLI binary is lowercase "claude" (the desktop app itself is "Claude"); npm installs run cli.js.
    if (!/(^|\/)claude$/.test(exe) && !command.includes('claude-code/cli.js')) continue;
    rows.push({
      pid: Number(pid), ppid: Number(ppid), command,
      startedAt: now - etimeSeconds(etime) * 1000,
      sessionId: command.match(/--(?:resume|session-id)[= ]([0-9a-f-]{36})/)?.[1],
      source: /claude\.app\/Contents\/MacOS\/claude|\.claude-instances|claude-desktop/.test(command) ? 'desktop' : 'terminal',
    });
  }
  // The desktop app runs each session as a wrapper plus a child with the same arguments: keep the outermost.
  const pids = new Set(rows.map((r) => r.pid));
  return rows.filter((r) => !pids.has(r.ppid));
}

function cwds(pids) {
  if (!pids.length) return {};
  try {
    const out = execFileSync('lsof', ['-a', '-d', 'cwd', '-Fpn', '-p', pids.join(',')], { encoding: 'utf8' });
    const map = {};
    let pid;
    for (const line of out.split('\n')) {
      if (line[0] === 'p') pid = Number(line.slice(1));
      else if (line[0] === 'n' && pid) map[pid] = line.slice(1);
    }
    return map;
  } catch {
    return {};
  }
}

function newestTranscript(dirs, cwd, since) {
  let best;
  for (const dir of dirs) {
    const folder = path.join(dir, 'projects', projectFolder(cwd));
    if (!fs.existsSync(folder)) continue;
    for (const f of fs.readdirSync(folder)) {
      if (!f.endsWith('.jsonl')) continue;
      const mtime = fs.statSync(path.join(folder, f)).mtimeMs;
      if (mtime >= since && (!best || mtime > best.mtime)) best = { id: f.slice(0, -6), mtime };
    }
  }
  return best?.id;
}

/**
 * Claude Code sessions running on this Mac outside this server, keyed by session id:
 * { pids, source: 'desktop' | 'terminal', cwd, startedAt }.
 * A Terminal session started without --resume is matched to the newest transcript in its folder.
 */
export function runningSessions(dirs, { ps, cwdOf = cwds, excludeParent = process.pid } = {}) {
  let out;
  try { out = ps ?? execFileSync('ps', ['-axo', 'pid=,ppid=,etime=,command='], { encoding: 'utf8' }); }
  catch { return new Map(); }
  const procs = parseClaudeProcesses(out).filter((p) => p.ppid !== excludeParent);
  const dirOf = cwdOf(procs.map((p) => p.pid));
  const sessions = new Map();
  for (const p of procs) {
    const cwd = dirOf[p.pid];
    const id = p.sessionId ?? (cwd && newestTranscript(dirs, cwd, p.startedAt - 60_000));
    if (!id) continue;
    const s = sessions.get(id) ?? { pids: [], source: p.source, cwd, startedAt: p.startedAt };
    s.pids.push(p.pid);
    sessions.set(id, s);
  }
  return sessions;
}

// `claude auth status --json` for one config folder; null when the claude command is not installed.
export function loginStatus(dir) {
  return new Promise((resolve) => {
    execFile('claude', ['auth', 'status', '--json'], { env: { ...process.env, CLAUDE_CONFIG_DIR: dir }, timeout: 15_000 }, (err, stdout) => {
      try { resolve(JSON.parse(stdout)); } catch { resolve(err?.code === 'ENOENT' ? null : { loggedIn: false }); }
    });
  });
}

// Plans without extra usage credits cannot use some models (e.g. Fable on Pro).
export const CREDITS_NEEDED = /requires usage credits/i;

export const AUTH_FAILURE = /Failed to authenticate|OAuth (session|token) (has )?expired|Please run \/login|Invalid API key/i;
