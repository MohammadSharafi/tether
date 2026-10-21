// Tether server: lists local Claude Code sessions and drives live ones
// through the Agent SDK, for the iOS app. Listens on loopback only; `npm run setup`
// exposes it to your devices with `tailscale serve`.
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { addUsage, emptyUsage, usageByDay, transcriptCwd } from './usage.mjs';
import { configDirs, runningSessions, loginStatus, AUTH_FAILURE, CREDITS_NEEDED } from './system.mjs';
import { createPusher } from './push.mjs';
import { listFolders, gitChanges, exportMarkdown, planFromUsage } from './extras.mjs';

export const STATE_DIR = path.join(os.homedir(), '.tether');
const MAX_BODY = 25_000_000; // room for a few photos
const EVENT_BUFFER = 500;
const IDLE_CLOSE_MS = 30 * 60_000;
const WORKING_MS = 30_000; // a running session whose transcript changed this recently is mid-turn
export const MODES = ['default', 'acceptEdits', 'plan', 'auto'];
export const EFFORTS = ['default', 'low', 'medium', 'high', 'xhigh', 'max'];
const IMAGE_TYPES = ['image/jpeg', 'image/png', 'image/gif', 'image/webp'];
const FALLBACK_MODELS = [
  { value: 'default', displayName: 'Default', description: 'Your Claude Code default' },
  { value: 'opus', displayName: 'Opus', description: 'Most capable for complex work' },
  { value: 'sonnet', displayName: 'Sonnet', description: 'Fast and capable for everyday work' },
  { value: 'haiku', displayName: 'Haiku', description: 'Fastest for quick answers' },
];
const noPush = { enabled: false, register: () => false, notify: async () => {}, activity: async () => {} };
const HEX_TOKEN = /^[0-9a-f]{64,200}$/i;

export function loadToken(dir = STATE_DIR) {
  if (process.env.TETHER_TOKEN) return process.env.TETHER_TOKEN;
  const file = path.join(dir, 'token');
  if (!fs.existsSync(file)) {
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    fs.writeFileSync(file, crypto.randomBytes(24).toString('base64url') + '\n', { mode: 0o600 });
  }
  return fs.readFileSync(file, 'utf8').trim();
}

// Sums token usage over stored assistant messages, counting each API message id once.
export function sumUsage(messages) {
  const total = emptyUsage();
  const seen = new Set();
  for (const m of messages) {
    const msg = m.message;
    if (m.type !== 'assistant' || !msg?.usage || seen.has(msg.id)) continue;
    seen.add(msg.id);
    addUsage(total, msg.usage);
  }
  return total;
}

const clip = (s, n = 2000) => (typeof s === 'string' && s.length > n ? s.slice(0, n) + '…' : s);

function toolDetail(input) {
  if (typeof input?.command === 'string') return clip(input.command);
  if (typeof input?.file_path === 'string') return input.file_path;
  if (typeof input?.questions?.[0]?.question === 'string') return input.questions[0].question;
  return clip(JSON.stringify(input ?? {}, null, 1));
}

// The parts of a tool's input the app renders specially (diffs, plans, questions), clipped for the phone.
export function displayInput(name, input) {
  if (!input) return undefined;
  switch (name) {
    case 'Edit': return { file_path: input.file_path, old_string: clip(input.old_string, 3000), new_string: clip(input.new_string, 3000) };
    case 'MultiEdit': return { file_path: input.file_path, edits: (input.edits ?? []).slice(0, 5).map((e) => ({ old_string: clip(e.old_string, 1500), new_string: clip(e.new_string, 1500) })) };
    case 'Write': return { file_path: input.file_path, content: clip(input.content, 3000) };
    case 'Bash': return { command: clip(input.command), description: input.description };
    case 'ExitPlanMode': return { plan: clip(input.plan, 8000) };
    case 'AskUserQuestion': return { questions: input.questions };
    default: return undefined;
  }
}

// Harness messages stored as user turns (command echoes, task notifications, compaction summaries).
const META = /^(<(task-notification|command-|local-command|system-reminder|bash-)|This session is being continued)/;

// Turns one user/assistant message into the flat events the app renders.
export function mapContent(type, message) {
  const content = typeof message?.content === 'string'
    ? [{ type: 'text', text: message.content }]
    : Array.isArray(message?.content) ? message.content : [];
  if (type !== 'assistant') {
    const text = content.filter((b) => b.type === 'text').map((b) => b.text).join('\n\n').trim();
    const images = content.filter((b) => b.type === 'image').length;
    if (!text && !images) return [];
    if (META.test(text)) return [{ kind: 'meta', text: clip(text, 300) }];
    return [{ kind: 'user', text: clip(text, 4000), ...(images && { images }) }];
  }
  const out = [];
  for (const b of content) {
    // shortcut: text is capped at 4000 chars (iOS leaves very tall Text blank); page it if full transcripts are needed on the phone.
    if (b.type === 'text' && b.text?.trim()) out.push({ kind: 'assistant', text: clip(b.text, 4000) });
    else if (b.type === 'tool_use') out.push({ kind: 'tool', name: b.name, text: toolDetail(b.input), input: displayInput(b.name, b.input) });
  }
  return out;
}

const mapStored = (messages) => messages.filter((m) => !m.parent_tool_use_id).flatMap((m) => mapContent(m.type, m.message));

export function mapResult(m) {
  return {
    kind: 'result',
    isError: m.is_error || m.subtype !== 'success',
    text: m.subtype === 'success' ? undefined : m.subtype,
    cost: m.total_cost_usd,
    usage: m.usage && {
      input: m.usage.input_tokens, output: m.usage.output_tokens,
      cacheRead: m.usage.cache_read_input_tokens, cacheWrite: m.usage.cache_creation_input_tokens,
    },
  };
}

function inbox() {
  const items = [];
  let wake = null, done = false;
  return {
    push(m) { items.push(m); wake?.(); wake = null; },
    close() { done = true; wake?.(); wake = null; },
    async *[Symbol.asyncIterator]() {
      for (;;) {
        while (items.length) yield items.shift();
        if (done) return;
        await new Promise((r) => (wake = r));
      }
    },
  };
}

class HttpError extends Error {
  constructor(code, message) { super(message); this.code = code; }
}

// --- Input checks for everything the phone sends ---

function text(body, field, { optional = false } = {}) {
  const v = body?.[field];
  if (optional && (v === undefined || v === '')) return '';
  if (typeof v !== 'string' || !v.trim() || v.length > 100_000) throw new HttpError(400, `"${field}" must be a non-empty string.`);
  return v;
}

function images(body) {
  const list = body?.images ?? [];
  if (!Array.isArray(list) || list.length > 4) throw new HttpError(400, 'Up to 4 images.');
  return list.map((img) => {
    if (!IMAGE_TYPES.includes(img?.mediaType)) throw new HttpError(400, `Image type must be one of ${IMAGE_TYPES.join(', ')}.`);
    if (typeof img.data !== 'string' || !/^[A-Za-z0-9+/]+={0,2}$/.test(img.data)) throw new HttpError(400, 'Image data must be base64.');
    if (img.data.length * 0.75 > 5_000_000) throw new HttpError(400, 'Each image must be under 5 MB.');
    return { mediaType: img.mediaType, data: img.data };
  });
}

function message(body) {
  const imgs = images(body);
  const t = text(body, 'text', { optional: imgs.length > 0 });
  return { text: t, images: imgs };
}

function settings(body) {
  const out = {};
  if (body?.mode !== undefined) {
    if (!MODES.includes(body.mode)) throw new HttpError(400, `"mode" must be one of ${MODES.join(', ')}.`);
    out.mode = body.mode;
  }
  if (body?.effort !== undefined) {
    if (!EFFORTS.includes(body.effort)) throw new HttpError(400, `"effort" must be one of ${EFFORTS.join(', ')}.`);
    out.effort = body.effort;
  }
  if (body?.model !== undefined) {
    if (typeof body.model !== 'string' || !/^[\w.\-[\]]{1,80}$/.test(body.model)) throw new HttpError(400, 'Bad "model".');
    out.model = body.model;
  }
  return out;
}

function answers(body) {
  const a = body?.answers;
  if (a === undefined) return undefined;
  const entries = a && typeof a === 'object' && !Array.isArray(a) ? Object.entries(a) : null;
  if (!entries || entries.length > 8 || entries.some(([k, v]) => typeof v !== 'string' || k.length > 2000 || v.length > 2000)) {
    throw new HttpError(400, '"answers" must map question text to answer text.');
  }
  return a;
}

export function createApp({
  token, sdk, pusher = noPush, dirs: fixedDirs, pushDelayMs = 3000,
  scan = runningSessions, signal = (pid, sig) => process.kill(pid, sig), auth = loginStatus,
  home = os.homedir(), changes = gitChanges, activityThrottleMs = 15_000,
}) {
  const cache = new Map(); // key -> { at, value }: commands per folder, plan usage
  async function cached(key, ttl, fn) {
    const c = cache.get(key);
    if (c && Date.now() - c.at < ttl) return c.value;
    const value = await fn();
    cache.set(key, { at: Date.now(), value });
    return value;
  }

  // A Claude Code process with no prompt: enough to read slash commands and plan usage. No model call.
  async function probe(cwd, dir, fn) {
    const box = inbox();
    const q = sdk.query({ prompt: box, options: { cwd, env: { ...process.env, CLAUDE_CONFIG_DIR: dir }, permissionMode: 'default' } });
    let timer;
    try {
      return await Promise.race([fn(q), new Promise((_, no) => { timer = setTimeout(() => no(new Error('Claude Code did not answer in time.')), 30_000); })]);
    } finally {
      clearTimeout(timer);
      box.close();
      q.close?.();
    }
  }

  const activityTokens = new Map(); // session id -> { token, sandbox } for its Live Activity
  const dirs = () => fixedDirs ?? configDirs();
  // New sessions go to the folder the server was started with, like your `claude` command.
  const primaryDir = fixedDirs?.[0] ?? process.env.CLAUDE_CONFIG_DIR ?? path.join(os.homedir(), '.claude');
  const sessionDir = new Map(); // session id -> sessions folder, learned from listings
  const authCache = new Map(); // folder -> { at, status }

  // The SDK reads the sessions folder from CLAUDE_CONFIG_DIR, so folder-specific calls run one at a time.
  let chain = Promise.resolve();
  function inDir(dir, fn) {
    const run = chain.then(async () => {
      const prev = process.env.CLAUDE_CONFIG_DIR;
      process.env.CLAUDE_CONFIG_DIR = dir;
      try { return await fn(); } finally {
        if (prev === undefined) delete process.env.CLAUDE_CONFIG_DIR; else process.env.CLAUDE_CONFIG_DIR = prev;
      }
    });
    chain = run.catch(() => {});
    return run;
  }

  async function listAll() {
    const all = [];
    for (const dir of dirs()) {
      for (const x of await inDir(dir, () => sdk.listSessions({ limit: 200 }))) {
        sessionDir.set(x.sessionId, dir);
        all.push({ ...x, dir });
      }
    }
    return all.sort((a, b) => b.lastModified - a.lastModified).slice(0, 300);
  }

  async function dirOf(id) {
    if (!sessionDir.has(id)) await listAll();
    return sessionDir.get(id) ?? primaryDir;
  }

  async function accounts() {
    return Promise.all(dirs().map(async (dir) => {
      let c = authCache.get(dir);
      if (!c || Date.now() - c.at > 60_000) authCache.set(dir, (c = { at: Date.now(), status: await auth(dir) }));
      return { dir, loggedIn: c.status?.loggedIn ?? null, method: c.status?.authMethod };
    }));
  }

  const live = new Map();
  const want = Buffer.from(`Bearer ${token}`);
  let models = FALLBACK_MODELS;
  let rateLimit = null;

  function authorized(req) {
    const got = Buffer.from(req.headers.authorization ?? '');
    return got.length === want.length && crypto.timingSafeEqual(got, want);
  }

  const frame = (e) => `${e.seq ? `id: ${e.seq}\n` : ''}data: ${JSON.stringify(e)}\n\n`;

  function emit(s, e) {
    e.seq = ++s.seq;
    s.events.push(e);
    if (s.events.length > EVENT_BUFFER) s.events.shift();
    for (const res of s.clients) res.write(frame(e));
  }

  // Ephemeral events (streaming text) go to open streams only; the full message follows as a normal event.
  function broadcast(s, e) {
    for (const res of s.clients) res.write(frame(e));
  }

  // Push only when nobody is watching the session in the app. The short delay lets an app that is
  // just opening the session connect first, and drops requests answered in the meantime.
  function notify(s, p) {
    setTimeout(() => {
      if (s.clients.size || (p.requestId && !s.pending.has(p.requestId))) return;
      pusher.notify({ title: s.title, sessionId: s.id, ...p }).catch(() => {});
    }, pushDelayMs).unref();
  }

  function setState(s, state) {
    if (s.state === state) return;
    s.state = state;
    clearTimeout(s.idleTimer);
    // shortcut: idle sessions close after 30 min to free the claude process; the next message resumes them.
    if (state === 'idle') s.idleTimer = setTimeout(() => s.inbox.close(), IDLE_CLOSE_MS).unref();
    emit(s, { kind: 'status', state });
    updateActivity(s, { force: true });
  }

  // Live Activity on the phone's lock screen: routine progress at most every 15 s, state changes at once.
  function activityState(s) {
    const waiting = [...s.pending.values()].at(-1);
    return {
      status: s.state, title: s.title,
      detail: clip(waiting?.label ?? s.lastTool ?? s.lastText ?? '', 120),
      requestId: waiting?.reqId ?? null, updatedAt: Date.now() / 1000,
    };
  }
  function updateActivity(s, { force = false } = {}) {
    const target = activityTokens.get(s.id);
    if (!target) return;
    const now = Date.now();
    if (!force && now - (s.activityAt ?? 0) < activityThrottleMs) return;
    s.activityAt = now;
    const end = s.state === 'closed';
    const alert = s.state === 'waiting' ? { title: s.title, body: activityState(s).detail || 'Claude needs you.' } : undefined;
    pusher.activity(target, activityState(s), { end, alert }).catch(() => {});
    if (end) activityTokens.delete(s.id);
  }

  function decide(s, reqId, { allow, always, answers: ans, message: note }) {
    const p = s.pending.get(reqId);
    if (!p) return false;
    s.pending.delete(reqId);
    p.resolve(allow
      ? {
          behavior: 'allow',
          updatedInput: ans ? { ...p.input, answers: ans } : p.input,
          ...(always && p.suggestions?.length && { updatedPermissions: p.suggestions }),
        }
      : { behavior: 'deny', message: note || 'Denied from the phone.' });
    emit(s, { kind: 'permissionResolved', id: reqId, allow, ...(always && { always: true }) });
    if (!s.pending.size) setState(s, 'running');
    return true;
  }

  function askPhone(s, tool, input, opts = {}) {
    const reqId = crypto.randomUUID();
    return new Promise((resolve) => {
      s.pending.set(reqId, { resolve, input, suggestions: opts.suggestions, reqId, label: clip(opts.title ?? `${tool}: ${toolDetail(input)}`, 120) });
      setState(s, 'waiting');
      emit(s, {
        kind: 'permission', id: reqId, name: tool, title: opts.title, text: toolDetail(input),
        input: displayInput(tool, input), canAlways: !!opts.suggestions?.length && !opts.suppressAlwaysAllowRule,
      });
      if (tool === 'AskUserQuestion') notify(s, { kind: 'question', body: `Claude asks: ${toolDetail(input)}` });
      else if (tool === 'ExitPlanMode') notify(s, { kind: 'plan', body: 'A plan is ready for your review.' });
      else notify(s, { kind: 'permission', requestId: reqId, body: clip(opts.title ?? `${tool}: ${toolDetail(input)}`, 180) });
      opts.signal?.addEventListener('abort', () => decide(s, reqId, { allow: false, message: 'Aborted.' }), { once: true });
    });
  }

  function startLive(id, cwd, { resume = false, mode = 'default', model, effort = 'default', title, dir = primaryDir }) {
    const s = {
      id, cwd, title: title ?? path.basename(cwd), mode, model, effort, inbox: inbox(), events: [],
      clients: new Set(), pending: new Map(), state: 'running', seq: 0, lastText: '', partial: '',
    };
    // History from before this live run; the live buffer covers everything after, so the two never overlap.
    s.history = resume ? inDir(dir, () => sdk.getSessionMessages(id)).then(mapStored).catch(() => []) : Promise.resolve([]);
    sessionDir.set(id, dir);
    s.q = sdk.query({
      prompt: s.inbox,
      options: {
        cwd,
        env: { ...process.env, CLAUDE_CONFIG_DIR: dir }, // the session's own folder and login
        permissionMode: mode, // tools not allowed by your settings or the mode are sent to the phone for approval
        ...(model && model !== 'default' && { model }),
        ...(effort !== 'default' && { effort }),
        includePartialMessages: true,
        ...(resume ? { resume: id } : { sessionId: id }),
        canUseTool: (tool, input, opts) => askPhone(s, tool, input, opts),
      },
    });
    live.set(id, s);
    s.q.supportedModels?.().then((m) => { if (m?.length) models = m; }).catch(() => {});
    (async () => {
      try {
        for await (const m of s.q) {
          if (m.parent_tool_use_id) continue; // subagent traffic stays on the Mac
          if (m.type === 'assistant') {
            s.partial = '';
            for (const e of mapContent('assistant', m.message)) {
              if (e.kind === 'assistant') { s.lastText = e.text; s.lastTool = null; }
              if (e.kind === 'tool') s.lastTool = `${e.name}: ${e.text}`;
              emit(s, e);
              updateActivity(s);
              if (e.kind === 'assistant' && AUTH_FAILURE.test(e.text)) {
                authCache.delete(dir);
                emit(s, { kind: 'notice', status: 'auth' });
              } else if (e.kind === 'assistant' && CREDITS_NEEDED.test(e.text)) {
                emit(s, { kind: 'notice', status: 'credits', model: s.model });
              }
            }
          } else if (m.type === 'stream_event' && m.event?.type === 'content_block_delta' && m.event.delta?.type === 'text_delta') {
            s.partial += m.event.delta.text;
            broadcast(s, { kind: 'delta', text: m.event.delta.text });
          } else if (m.type === 'system' && m.subtype === 'init') {
            s.model = m.model ?? s.model;
            emit(s, { kind: 'settings', mode: s.mode, model: s.model, effort: s.effort });
          } else if (m.type === 'rate_limit_event') {
            rateLimit = m.rate_limit_info;
            if (rateLimit?.status !== 'allowed') {
              emit(s, { kind: 'notice', status: rateLimit.status, resetsAt: rateLimit.resetsAt, limit: rateLimit.rateLimitType, utilization: rateLimit.utilization });
            }
          } else if (m.type === 'result') {
            const r = mapResult(m);
            emit(s, r);
            setState(s, 'idle');
            notify(s, { kind: 'done', body: r.isError ? `Stopped: ${r.text}` : clip(s.lastText || 'Finished.', 180) });
          }
        }
      } catch (err) {
        emit(s, { kind: 'error', text: String(err?.message ?? err) });
      } finally {
        clearTimeout(s.idleTimer);
        for (const p of s.pending.values()) p.resolve({ behavior: 'deny', message: 'Session closed.' });
        setState(s, 'closed');
        if (live.get(id) === s) live.delete(id);
        for (const res of s.clients) res.end();
      }
    })();
    return s;
  }

  function send(s, { text: t, images: imgs }) {
    emit(s, { kind: 'user', text: t, ...(imgs.length && { images: imgs.length }) });
    setState(s, 'running');
    const content = imgs.length
      ? [...imgs.map((i) => ({ type: 'image', source: { type: 'base64', media_type: i.mediaType, data: i.data } })), ...(t ? [{ type: 'text', text: t }] : [])]
      : t;
    s.inbox.push({ type: 'user', message: { role: 'user', content }, parent_tool_use_id: null });
  }

  async function applySettings(s, { mode, model, effort }) {
    if (mode && mode !== s.mode) { await s.q.setPermissionMode(mode); s.mode = mode; }
    if (model && model !== s.model) { await s.q.setModel(model === 'default' ? undefined : model); s.model = model; }
    if (effort && effort !== s.effort) { await s.q.applyFlagSettings({ effortLevel: effort === 'default' ? null : effort }); s.effort = effort; }
    emit(s, { kind: 'settings', mode: s.mode, model: s.model, effort: s.effort });
  }

  const json = (res, code, body) => {
    res.writeHead(code, { 'content-type': 'application/json' });
    res.end(body === undefined ? undefined : JSON.stringify(body));
  };

  async function readJson(req) {
    let size = 0;
    const chunks = [];
    for await (const c of req) {
      size += c.length;
      if (size > MAX_BODY) throw new HttpError(413, 'Body too large.');
      chunks.push(c);
    }
    try { return JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}'); }
    catch { throw new HttpError(400, 'Invalid JSON.'); }
  }

  async function findSession(id) {
    const info = (await listAll()).find((x) => x.sessionId === id);
    return info && { ...info, cwd: info.cwd ?? transcriptCwd(id, info.dir) };
  }

  async function route(req, res) {
    const url = new URL(req.url, 'http://x');
    const [root, id, sub, subId] = url.pathname.split('/').filter(Boolean);

    if (req.method === 'GET' && root === 'info' && !id) {
      return json(res, 200, { configDir: primaryDir, dirs: dirs(), accounts: await accounts(), push: pusher.enabled, models, modes: MODES, efforts: EFFORTS, home, rateLimit });
    }
    if (req.method === 'GET' && root === 'usage' && !id) {
      const days = Math.min(90, Math.max(1, Number(url.searchParams.get('days')) || 14));
      return json(res, 200, usageByDay({ dirs: dirs(), days }));
    }
    if (req.method === 'POST' && root === 'devices' && !id) {
      const body = await readJson(req);
      const prefs = body.prefs && typeof body.prefs === 'object' ? { needsYou: body.prefs.needsYou !== false, done: body.prefs.done !== false } : undefined;
      if (!pusher.register(body.token, body.sandbox === true, prefs)) throw new HttpError(400, 'Bad device token.');
      return json(res, 204);
    }
    if (req.method === 'GET' && root === 'folders' && !id) {
      const listing = listFolders(home, url.searchParams.get('path') || home);
      if (!listing) throw new HttpError(404, 'That folder is not inside your home folder, or does not exist.');
      return json(res, 200, listing);
    }
    if (req.method === 'GET' && root === 'plan' && !id) {
      return json(res, 200, await cached('plan', 120_000, async () => {
        // Experimental SDK call (its name says the shape may change): any failure shows "unavailable".
        const read = (q) => q.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET?.({ skipBehaviors: true });
        try {
          const any = [...live.values()].find((x) => x.state !== 'closed');
          return planFromUsage(any ? await read(any.q) : await probe(home, primaryDir, read));
        } catch (err) {
          return { available: false, reason: String(err?.message ?? err) };
        }
      }));
    }

    if (root !== 'sessions') throw new HttpError(404, 'Not found.');
    if (id && !/^[0-9a-f-]{36}$/.test(id)) throw new HttpError(400, 'Bad session id.');
    const s = id && live.get(id);

    if (req.method === 'GET' && !id) {
      const list = await listAll();
      const running = scan(dirs()); // sessions running on this Mac outside this server
      const known = new Set(list.map((x) => x.sessionId));
      const fresh = [...live.values()].filter((x) => !known.has(x.id))
        .map((x) => ({ id: x.id, title: x.title, cwd: x.cwd, updated: Date.now(), state: x.state, dir: sessionDir.get(x.id) }));
      return json(res, 200, [...fresh, ...list.map((x) => {
        const mac = !live.has(x.sessionId) && running.get(x.sessionId);
        return {
          id: x.sessionId, title: x.customTitle ?? x.summary, cwd: x.cwd ?? transcriptCwd(x.sessionId, x.dir),
          branch: x.gitBranch, updated: x.lastModified, dir: x.dir,
          state: live.get(x.sessionId)?.state ?? (mac ? 'active' : null),
          ...(mac && { mac: { source: mac.source, working: Date.now() - x.lastModified < WORKING_MS, since: mac.startedAt } }),
        };
      })]);
    }

    if (req.method === 'POST' && !id) {
      const body = await readJson(req);
      const cwd = text(body, 'cwd');
      if (!path.isAbsolute(cwd) || !fs.statSync(cwd, { throwIfNoEntry: false })?.isDirectory()) {
        throw new HttpError(400, 'cwd must be an existing absolute directory on the Mac.');
      }
      const msg = message({ ...body, text: body.text ?? body.prompt });
      const n = startLive(crypto.randomUUID(), cwd, { ...settings(body), title: clip(msg.text, 60) || path.basename(cwd) });
      send(n, msg);
      return json(res, 201, { id: n.id });
    }

    if (req.method === 'GET' && id && !sub) {
      const dir = await dirOf(id);
      const stored = await inDir(dir, () => sdk.getSessionMessages(id));
      const events = s ? [...await s.history, ...s.events] : mapStored(stored);
      return json(res, 200, {
        id, state: s?.state ?? null, seq: s?.seq ?? 0, mode: s?.mode ?? null, model: s?.model ?? null, effort: s?.effort ?? null,
        usage: sumUsage(stored), events: events.slice(-300),
      });
    }

    if (req.method === 'DELETE' && id && !sub) {
      if (s) throw new HttpError(409, 'Stop the session before deleting it.');
      if (scan(dirs()).has(id)) throw new HttpError(409, 'This session is running on your Mac. Stop it first.');
      const dir = await dirOf(id);
      await inDir(dir, () => sdk.deleteSession(id));
      return json(res, 204);
    }

    if (req.method === 'GET' && sub === 'events') {
      if (!s) throw new HttpError(409, 'Session is not live.');
      const after = Number(url.searchParams.get('after') ?? req.headers['last-event-id'] ?? 0);
      res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache', connection: 'keep-alive' });
      res.write(': connected\n\n');
      for (const e of s.events) if (e.seq > after) res.write(frame(e));
      if (s.partial) res.write(frame({ kind: 'delta', text: s.partial })); // text still being written
      s.clients.add(res);
      const ping = setInterval(() => res.write(': ping\n\n'), 25_000);
      req.on('close', () => { clearInterval(ping); s.clients.delete(res); });
      return;
    }

    if (req.method === 'POST' && sub === 'messages') {
      const body = await readJson(req);
      const msg = message(body);
      let target = s;
      if (!target) {
        const info = await findSession(id);
        if (!info?.cwd) throw new HttpError(404, 'Session not found.');
        if (scan(dirs()).has(id)) throw new HttpError(409, 'This session is running on your Mac. Stop it there first, or use Stop on Mac.');
        target = startLive(id, info.cwd, { resume: true, ...settings(body), title: info.customTitle ?? info.summary, dir: info.dir });
      }
      send(target, msg);
      return json(res, 202, { id, seq: target.seq });
    }

    if (req.method === 'POST' && sub === 'permissions' && subId) {
      const body = await readJson(req);
      if (typeof body.allow !== 'boolean') throw new HttpError(400, '"allow" must be true or false.');
      const decision = { allow: body.allow, always: body.always === true, answers: answers(body), message: typeof body.message === 'string' ? clip(body.message, 4000) : undefined };
      if (!s || !decide(s, subId, decision)) throw new HttpError(404, 'No such pending request.');
      return json(res, 200, { ok: true });
    }

    if (req.method === 'POST' && sub === 'settings') {
      if (!s) throw new HttpError(409, 'Session is not live.');
      await applySettings(s, settings(await readJson(req)));
      return json(res, 200, { mode: s.mode, model: s.model, effort: s.effort });
    }

    if (req.method === 'POST' && sub === 'rename') {
      const title = text(await readJson(req), 'title').trim().slice(0, 200);
      const dir = await dirOf(id);
      await inDir(dir, () => sdk.renameSession(id, title));
      if (s) s.title = title;
      return json(res, 200, { ok: true });
    }

    // Stops a session running in the desktop app or Terminal: SIGINT, like pressing Ctrl-C there.
    // Only processes the scan just tied to this session id are signalled; the phone never sends a pid.
    if (req.method === 'POST' && sub === 'stop-mac') {
      const mac = scan(dirs()).get(id);
      if (!mac) throw new HttpError(404, 'This session is not running on your Mac.');
      for (const pid of mac.pids) signal(pid, 'SIGINT');
      return json(res, 200, { ok: true, stopped: mac.pids.length });
    }

    if (req.method === 'POST' && (sub === 'interrupt' || sub === 'close')) {
      if (!s) throw new HttpError(409, 'Session is not live.');
      if (sub === 'interrupt') await s.q.interrupt();
      else s.inbox.close();
      return json(res, 200, { ok: true });
    }

    if (req.method === 'POST' && sub === 'fork') {
      const dir = await dirOf(id);
      const { sessionId } = await inDir(dir, () => sdk.forkSession(id));
      sessionDir.set(sessionId, dir);
      return json(res, 201, { id: sessionId });
    }

    if (req.method === 'GET' && sub === 'export') {
      const dir = await dirOf(id);
      const info = (await listAll()).find((x) => x.sessionId === id);
      const md = exportMarkdown(info?.customTitle ?? info?.summary ?? 'Claude Code session', await inDir(dir, () => sdk.getSessionMessages(id)));
      res.writeHead(200, { 'content-type': 'text/markdown; charset=utf-8' });
      return res.end(md);
    }

    if (req.method === 'GET' && sub === 'changes') {
      const cwd = s?.cwd ?? (await findSession(id))?.cwd;
      if (!cwd || !fs.existsSync(cwd)) throw new HttpError(404, 'This session\'s folder is not on the Mac.');
      return json(res, 200, await changes(cwd));
    }

    if (req.method === 'GET' && sub === 'commands') {
      const info = s ? { cwd: s.cwd, dir: sessionDir.get(id) ?? primaryDir } : await findSession(id);
      if (!info?.cwd) throw new HttpError(404, 'Session not found.');
      const list = await cached(`commands|${info.dir}|${info.cwd}`, 300_000, () =>
        s ? s.q.supportedCommands() : probe(info.cwd, info.dir, (q) => q.supportedCommands()));
      // Names starting with "_" are Claude Code internals, not commands to offer.
      return json(res, 200, list.filter((c) => !c.name.startsWith('_')).map((c) => ({ name: c.name, description: c.description, argumentHint: c.argumentHint || undefined, builtin: !!c.builtin }))
        .sort((a, b) => a.name.localeCompare(b.name)));
    }

    if (req.method === 'POST' && sub === 'activity') {
      const body = await readJson(req);
      if (!HEX_TOKEN.test(body.token ?? '')) throw new HttpError(400, 'Bad Live Activity token.');
      activityTokens.set(id, { token: body.token, sandbox: body.sandbox === true });
      if (s) updateActivity(s, { force: true });
      return json(res, 204);
    }

    throw new HttpError(404, 'Not found.');
  }

  return http.createServer(async (req, res) => {
    if (!authorized(req)) return json(res, 401, { error: 'Missing or wrong token.' });
    try {
      await route(req, res);
    } catch (err) {
      const code = err instanceof HttpError ? err.code : 500;
      if (code === 500) console.error(err);
      if (!res.headersSent) json(res, code, { error: err.message });
      else res.end();
    }
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const sdk = await import('@anthropic-ai/claude-agent-sdk');
  const port = Number(process.env.PORT ?? 8787);
  const token = loadToken();
  const pusher = createPusher(STATE_DIR);
  createApp({ token, sdk, pusher }).listen(port, '127.0.0.1', () => {
    console.log(`Tether server on http://127.0.0.1:${port}`);
    console.log(`Sessions folders: ${configDirs().join(', ')}`);
    console.log(`Push notifications: ${pusher.enabled ? 'on' : `off (see README: ${path.join(STATE_DIR, 'apns.json')})`}`);
    console.log('Pair your phone: npm run pair');
  });
}
