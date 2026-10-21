// Helpers behind the phone's folder picker, changes view, transcript export and plan meter.
import fs from 'node:fs';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const run = promisify(execFile);

/**
 * Subfolders of `dir` for the folder picker. Only folders inside `home` are listed: the phone
 * browses your projects, not the whole disk. Symlinks are resolved first, so `..` or a link
 * cannot step outside. Returns null when the folder is outside home or does not exist.
 */
export function listFolders(home, dir) {
  const homeReal = fs.realpathSync(home);
  let real;
  try { real = fs.realpathSync(path.resolve(dir || home)); } catch { return null; }
  if (real !== homeReal && !real.startsWith(homeReal + path.sep)) return null;
  if (!fs.statSync(real).isDirectory()) return null;
  const dirs = fs.readdirSync(real, { withFileTypes: true })
    .filter((d) => d.isDirectory() && !d.name.startsWith('.'))
    .map((d) => ({ name: d.name, path: path.join(real, d.name), repo: fs.existsSync(path.join(real, d.name, '.git')) }))
    .sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: 'base' }))
    .slice(0, 500);
  return { path: real, parent: real === homeReal ? null : path.dirname(real), repo: fs.existsSync(path.join(real, '.git')), dirs };
}

const EMPTY_TREE = '4b825dc642cb6eb9a060e54bf8d69288fbee4904';
const clipText = (s, n) => (s.length > n ? { text: s.slice(0, n), truncated: true } : { text: s, truncated: false });

/**
 * Uncommitted changes in a session's folder (what Claude changed since the last commit), file by file.
 * Read-only: GIT_OPTIONAL_LOCKS=0 keeps git from taking locks a running session might need.
 */
export async function gitChanges(cwd, { maxFiles = 50, maxDiff = 20_000 } = {}) {
  const git = (...args) => run('git', ['-C', cwd, ...args], {
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0' }, maxBuffer: 20_000_000, timeout: 15_000,
  }).then((r) => r.stdout);
  try { await git('rev-parse', '--is-inside-work-tree'); } catch { return { repo: false, files: [] }; }
  const base = await git('rev-parse', '--verify', '-q', 'HEAD').then(() => 'HEAD', () => EMPTY_TREE);
  const branch = (await git('branch', '--show-current').catch(() => '')).trim() || null;
  const numstat = new Map();
  for (const line of (await git('diff', base, '--numstat', '-z')).split('\0')) {
    const m = line.match(/^(\d+|-)\t(\d+|-)\t(.+)$/s);
    if (m) numstat.set(m[3], { added: m[1] === '-' ? null : Number(m[1]), removed: m[2] === '-' ? null : Number(m[2]) });
  }
  const files = [];
  const entries = (await git('status', '--porcelain=v1', '-z', '--untracked-files=all')).split('\0');
  for (let i = 0; i < entries.length; i++) {
    const entry = entries[i];
    if (!entry) continue;
    const code = entry.slice(0, 2), file = entry.slice(3);
    if (code[0] === 'R' || code[0] === 'C') i++; // with -z a rename's old path is the next entry: skip it
    const status = code === '??' ? 'added' : code[0] === 'R' ? 'renamed' : code.includes('D') ? 'deleted' : code.includes('A') ? 'added' : 'modified';
    files.push({ path: file, status, untracked: code === '??', ...(numstat.get(file) ?? { added: null, removed: null }) });
  }
  files.sort((a, b) => a.path.localeCompare(b.path));
  const shown = files.slice(0, maxFiles);
  for (const f of shown) {
    let diff;
    if (numstat.has(f.path)) diff = await git('diff', base, '--', f.path).catch(() => '');
    else if (!f.untracked) diff = ''; // e.g. a pure rename: no content change to show
    else { // untracked: show the new file's start as added lines, text files only
      try {
        const buf = fs.readFileSync(path.join(cwd, f.path));
        if (buf.subarray(0, 8000).includes(0)) diff = ''; // binary: no line counts, like git's "-"
        else {
          const lines = buf.toString('utf8').split('\n');
          diff = lines.slice(0, 300).map((l) => `+${l}`).join('\n');
          f.added = lines.length;
          f.removed = 0;
        }
      } catch { diff = ''; }
    }
    const c = clipText(diff, maxDiff);
    f.diff = c.text;
    f.truncated = c.truncated;
    delete f.untracked;
  }
  return { repo: true, branch, total: files.length, files: shown };
}

/** A session transcript as Markdown, for sharing. Full text: nothing is clipped. */
export function exportMarkdown(title, messages) {
  const out = [`# ${title}`, ''];
  for (const m of messages) {
    if (m.parent_tool_use_id) continue;
    const content = typeof m.message?.content === 'string' ? [{ type: 'text', text: m.message.content }] : m.message?.content ?? [];
    for (const b of content) {
      if (b.type === 'text' && b.text?.trim()) out.push(m.type === 'assistant' ? b.text.trim() : `**You:** ${b.text.trim()}`, '');
      else if (b.type === 'tool_use') {
        const detail = b.input?.command ?? b.input?.file_path ?? b.input?.pattern ?? '';
        out.push(`> ${b.name}${detail ? `: \`${String(detail).split('\n')[0].slice(0, 200)}\`` : ''}`, '');
      } else if (b.type === 'image' && m.type !== 'assistant') out.push('**You:** _(photo)_', '');
    }
  }
  return out.join('\n').trimEnd() + '\n';
}

/** The plan meter from the SDK's /usage data. */
export function planFromUsage(raw) {
  if (!raw?.rate_limits_available || !raw.rate_limits) return { available: false, subscription: raw?.subscription_type ?? null };
  const win = (w) => w && w.utilization != null ? { utilization: w.utilization, resetsAt: w.resets_at } : null;
  return {
    available: true,
    subscription: raw.subscription_type,
    fiveHour: win(raw.rate_limits.five_hour),
    sevenDay: win(raw.rate_limits.seven_day),
  };
}
