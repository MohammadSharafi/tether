// Token usage read straight from Claude Code's JSONL transcripts.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

export const configDir = () => process.env.CLAUDE_CONFIG_DIR ?? path.join(os.homedir(), '.claude');

export const emptyUsage = () => ({ input: 0, output: 0, cacheRead: 0, cacheWrite: 0 });

// Adds one API message's usage. Newer transcripts keep the real numbers in usage.iterations.
export function addUsage(total, usage) {
  const parts = usage.iterations?.length ? usage.iterations : [usage];
  for (const u of parts) {
    total.input += u.input_tokens ?? 0;
    total.output += u.output_tokens ?? 0;
    total.cacheRead += u.cache_read_input_tokens ?? 0;
    total.cacheWrite += u.cache_creation_input_tokens ?? 0;
  }
  return total;
}

const cwdCache = new Map(); // session id -> folder (a session's folder never changes)

// The SDK's session list reads only the start of a transcript, so a first message carrying a large
// photo hides the folder. This reads the whole transcript once to find it.
export function transcriptCwd(id, dir = configDir()) {
  if (cwdCache.has(id)) return cwdCache.get(id);
  const projects = path.join(dir, 'projects');
  for (const p of fs.existsSync(projects) ? fs.readdirSync(projects) : []) {
    const file = path.join(projects, p, `${id}.jsonl`);
    if (!fs.existsSync(file)) continue;
    for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
      const m = line.match(/"cwd":("(?:[^"\\]|\\.)*")/);
      if (m) { cwdCache.set(id, JSON.parse(m[1])); return cwdCache.get(id); }
    }
  }
  return undefined;
}

const localDay = (t) => new Date(t).toLocaleDateString('en-CA'); // YYYY-MM-DD in the Mac's time zone

// Per-file summary: { [day]: { usage, models: {model: output} } } plus the project folder.
// One API message can span several transcript lines, so each message id counts once.
export function summarizeTranscript(text) {
  const days = {};
  const seen = new Set();
  let cwd;
  for (const line of text.split('\n')) {
    if (!line.includes('"usage"') && cwd) continue;
    let e;
    try { e = JSON.parse(line); } catch { continue; }
    cwd ??= e.cwd;
    const msg = e.message;
    if (e.type !== 'assistant' || !msg?.usage || !e.timestamp || seen.has(msg.id)) continue;
    seen.add(msg.id);
    const day = (days[localDay(e.timestamp)] ??= { usage: emptyUsage(), models: {} });
    const before = day.usage.output;
    addUsage(day.usage, msg.usage);
    if (msg.model && msg.model !== '<synthetic>') day.models[msg.model] = (day.models[msg.model] ?? 0) + day.usage.output - before;
  }
  return { cwd, days };
}

const cache = new Map(); // file -> { mtimeMs, size, summary }

// shortcut: reads top-level session transcripts only (not subagent sub-files); add them if subagent spend matters.
export function usageByDay({ dirs = [configDir()], days = 14, now = Date.now() } = {}) {
  // Step by calendar day, not 24h, so daylight-saving changes never skip or repeat a date.
  const dayAt = (i) => { const d = new Date(now); d.setDate(d.getDate() - i); d.setHours(0, 0, 0, 0); return d; };
  const since = dayAt(days - 1).getTime();
  const byDay = {}, byProject = {}, byModel = {};
  for (const [projects, p] of dirs.flatMap((d) => {
    const projects = path.join(d, 'projects');
    return fs.existsSync(projects) ? fs.readdirSync(projects).map((p) => [projects, p]) : [];
  })) {
    const folder = path.join(projects, p);
    if (!fs.statSync(folder).isDirectory()) continue;
    for (const f of fs.readdirSync(folder)) {
      if (!f.endsWith('.jsonl')) continue;
      const file = path.join(folder, f);
      const st = fs.statSync(file);
      if (st.mtimeMs < since) continue;
      let c = cache.get(file);
      if (!c || c.mtimeMs !== st.mtimeMs || c.size !== st.size) {
        c = { mtimeMs: st.mtimeMs, size: st.size, summary: summarizeTranscript(fs.readFileSync(file, 'utf8')) };
        cache.set(file, c);
      }
      const project = c.summary.cwd ? path.basename(c.summary.cwd) : p;
      for (const [day, d] of Object.entries(c.summary.days)) {
        if (day < localDay(since)) continue;
        for (const [k, v] of Object.entries(d.usage)) {
          (byDay[day] ??= emptyUsage())[k] += v;
          (byProject[project] ??= emptyUsage())[k] += v;
        }
        for (const [m, out] of Object.entries(d.models)) byModel[m] = (byModel[m] ?? 0) + out;
      }
    }
  }
  const series = [];
  for (let i = days - 1; i >= 0; i--) {
    const date = localDay(dayAt(i));
    series.push({ date, ...(byDay[date] ?? emptyUsage()) });
  }
  return {
    days: series,
    projects: Object.entries(byProject).filter(([, u]) => u.input + u.output > 0)
      .map(([name, u]) => ({ name, ...u })).sort((a, b) => b.output - a.output),
    models: Object.entries(byModel).map(([name, output]) => ({ name, output })).sort((a, b) => b.output - a.output),
  };
}
