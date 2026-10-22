import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { createApp, sumUsage, mapContent, displayInput } from './server.mjs';
import { usageByDay, summarizeTranscript, transcriptCwd } from './usage.mjs';
import { apnsJwt, buildPayload, buildActivityPayload, wantsNotification } from './push.mjs';
import { listFolders, gitChanges, exportMarkdown, planFromUsage } from './extras.mjs';
import { plist, windowsLauncher } from './setup.mjs';
import { parseClaudeProcesses, parseWindowsProcesses, runningSessions, followContinued, projectFolder } from './system.mjs';
import { execFileSync } from 'node:child_process';

const TOKEN = 'test-token';
const SID = '11111111-2222-3333-4444-555555555555';
// A folder that exists on every OS (sessions can only start in a real folder).
const TMP = os.tmpdir();
const PNG = Buffer.from('fake-png-bytes').toString('base64');

// Fake SDK: one stored session; each prompt streams a delta, asks permission for Bash, then answers
// with the verdict and what it received, and reports a result. Records options and verdicts for asserts.
function fakeSdk({ lastModified = 1 } = {}) {
  const sdk = {
    calls: [], verdicts: [], options: null,
    listSessions: async () => [{ sessionId: SID, summary: 'Fix tests', cwd: TMP, gitBranch: 'main', lastModified }],
    getSessionMessages: async () => [
      { type: 'user', message: { role: 'user', content: 'hi' }, parent_tool_use_id: null },
      { type: 'assistant', message: { id: 'm1', content: [{ type: 'text', text: 'hello' }], usage: { input_tokens: 3, output_tokens: 5 } }, parent_tool_use_id: null },
    ],
    renameSession: async (id, title) => sdk.calls.push(['rename', id, title]),
    forkSession: async (id) => { sdk.calls.push(['fork', id]); return { sessionId: '77777777-2222-3333-4444-555555555555' }; },
    usage: { rate_limits_available: true, subscription_type: 'max', rate_limits: { five_hour: { utilization: 42, resets_at: '2026-10-21T15:00:00Z' }, seven_day: { utilization: 10, resets_at: null } } },
    deleteSession: async (id) => sdk.calls.push(['delete', id]),
    query({ prompt, options }) {
      sdk.options = options;
      async function* run() {
        for await (const msg of prompt) {
          const c = msg.message.content;
          const got = typeof c === 'string' ? c : c.map((b) => b.type).join('+');
          await new Promise((r) => setTimeout(r, 50)); // like real Claude, the first words come after the app has connected
          yield { type: 'stream_event', parent_tool_use_id: null, event: { type: 'content_block_delta', delta: { type: 'text_delta', text: 'thinking…' } } };
          const verdict = await options.canUseTool('Bash', { command: 'ls' }, {
            title: 'Claude wants to run ls', suggestions: [{ type: 'addRules', rules: [{ toolName: 'Bash' }], behavior: 'allow', destination: 'session' }],
          });
          sdk.verdicts.push(verdict);
          yield { type: 'assistant', parent_tool_use_id: null, message: { content: [{ type: 'text', text: `${verdict.behavior}:${got}` }] } };
          yield { type: 'result', subtype: 'success', is_error: false, total_cost_usd: 0.01, usage: { input_tokens: 1, output_tokens: 2 } };
        }
      }
      const it = run();
      it.interrupt = async () => sdk.calls.push(['interrupt']);
      it.setPermissionMode = async (m) => sdk.calls.push(['mode', m]);
      it.setModel = async (m) => sdk.calls.push(['model', m]);
      it.applyFlagSettings = async (f) => sdk.calls.push(['flags', f]);
      it.supportedCommands = async () => [{ name: 'review', description: 'Review code', argumentHint: '' }, { name: 'compact', description: 'Compact', argumentHint: '<instructions>', builtin: true }];
      it.close = () => sdk.calls.push(['close']);
      it.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET = async () => sdk.usage;
      return it;
    },
  };
  return sdk;
}

const emptyDir = () => fs.mkdtempSync(path.join(os.tmpdir(), 'cfg-'));

async function withServer(fn, { sdk = fakeSdk(), pusher, dirs = [emptyDir()], pushDelayMs = 0, scan = () => new Map(), signal = () => {}, auth = async () => ({ loggedIn: true, authMethod: 'claude.ai' }), home, changes, activityThrottleMs } = {}) {
  const server = createApp({ token: TOKEN, sdk, pusher, dirs, pushDelayMs, scan, signal, auth, home, changes, activityThrottleMs });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  const call = (p, init = {}) => fetch(base + p, {
    ...init,
    headers: { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json', ...init.headers },
  });
  const post = (p, body) => call(p, { method: 'POST', body: typeof body === 'string' ? body : JSON.stringify(body) });
  try { await fn({ call, post, base, sdk }); } finally { server.closeAllConnections(); server.close(); }
}

async function readEvents(res, onEvent) {
  const events = [];
  const dec = new TextDecoder();
  let buf = '';
  for await (const chunk of res.body) {
    buf += dec.decode(chunk);
    let i;
    while ((i = buf.indexOf('\n\n')) >= 0) {
      const frame = buf.slice(0, i); buf = buf.slice(i + 2);
      const data = frame.split('\n').find((l) => l.startsWith('data: '));
      if (data) { const e = JSON.parse(data.slice(6)); events.push(e); if (await onEvent(e)) return events; }
    }
  }
  return events;
}

// Starts a session, follows its stream and answers the one permission request with `decision`.
async function runTurn({ call, post }, startBody, decision) {
  const { id } = await (await post('/sessions', { cwd: TMP, prompt: 'go', ...startBody })).json();
  const events = await readEvents(await call(`/sessions/${id}/events`), async (e) => {
    if (e.kind === 'permission') await post(`/sessions/${id}/permissions/${e.id}`, decision);
    return e.kind === 'result';
  });
  return { id, events };
}

test('rejects missing and wrong tokens', async () => {
  await withServer(async ({ call, base }) => {
    assert.equal((await fetch(base + '/sessions')).status, 401);
    assert.equal((await fetch(base + '/info')).status, 401);
    assert.equal((await call('/sessions', { headers: { authorization: 'Bearer nope' } })).status, 401);
    assert.equal((await call('/sessions')).status, 200);
  });
});

test('lists sessions, marks ones running on the Mac, returns history with usage', async () => {
  const dir = emptyDir();
  await withServer(async ({ call }) => {
    const list = await (await call('/sessions')).json();
    assert.deepEqual(list[0], { id: SID, title: 'Fix tests', cwd: TMP, branch: 'main', updated: 1, dir, state: null });
    const detail = await (await call(`/sessions/${SID}`)).json();
    assert.deepEqual(detail.events.map((e) => e.kind), ['user', 'assistant']);
    assert.equal(detail.usage.output, 5);
  }, { dirs: [dir] });
  // Running in the desktop app, transcript just written: "On Mac", working.
  const scan = () => new Map([[SID, { pids: [42], source: 'desktop', cwd: TMP, startedAt: 5 }]]);
  await withServer(async ({ call }) => {
    const s = (await (await call('/sessions')).json())[0];
    assert.equal(s.state, 'active');
    assert.deepEqual(s.mac, { source: 'desktop', working: true, since: 5 });
  }, { sdk: fakeSdk({ lastModified: Date.now() }), scan });
  // A transcript written recently but no process: not running (no more guessing from file times).
  await withServer(async ({ call }) => {
    assert.equal((await (await call('/sessions')).json())[0].state, null);
  }, { sdk: fakeSdk({ lastModified: Date.now() }) });
});

test('validates input at the boundary', async () => {
  await withServer(async ({ call, post }) => {
    const bad = async (p, body) => assert.equal((await post(p, body)).status, 400, JSON.stringify(body));
    await bad('/sessions', '{bad');
    await bad('/sessions', { cwd: 'relative', prompt: 'x' });
    await bad('/sessions', { cwd: '/definitely/missing', prompt: 'x' });
    await bad('/sessions', { cwd: TMP, prompt: '  ' });
    await bad('/sessions', { cwd: TMP, prompt: 'x', mode: 'bypassPermissions' });
    await bad('/sessions', { cwd: TMP, prompt: 'x', model: 'opus; rm -rf' });
    await bad('/sessions', { cwd: TMP, prompt: 'x', images: [{ mediaType: 'image/svg+xml', data: PNG }] });
    await bad('/sessions', { cwd: TMP, prompt: 'x', images: [{ mediaType: 'image/png', data: 'not base64!' }] });
    await bad('/sessions', { cwd: TMP, prompt: 'x', images: Array(5).fill({ mediaType: 'image/png', data: PNG }) });
    await bad(`/sessions/${SID}/permissions/x`, { allow: 'yes' });
    await bad(`/sessions/${SID}/permissions/x`, { allow: true, answers: ['a'] });
    await bad('/devices', { token: 'zz' });
    assert.equal((await call('/sessions/not-a-uuid')).status, 400);
  });
});

test('live session: prompt is in history, permission goes to the phone, approval resumes the turn', async () => {
  await withServer(async ({ call, post, sdk }) => {
    const { id } = await (await post('/sessions', { cwd: TMP, prompt: 'go', mode: 'plan', model: 'sonnet' })).json();
    assert.equal(sdk.options.permissionMode, 'plan');
    assert.equal(sdk.options.model, 'sonnet');
    assert.equal(sdk.options.includePartialMessages, true);
    // The app loads history first, then follows the stream after detail.seq: the prompt must be in that history.
    const detail = await (await call(`/sessions/${id}`)).json();
    assert.deepEqual(detail.events[0], { kind: 'user', text: 'go', seq: 1 });
    assert.equal(detail.mode, 'plan');
    const events = await readEvents(await call(`/sessions/${id}/events`), async (e) => {
      if (e.kind === 'permission') {
        assert.equal(e.title, 'Claude wants to run ls');
        assert.equal(e.canAlways, true);
        assert.deepEqual(e.input, { command: 'ls' });
        await post(`/sessions/${id}/permissions/${e.id}`, { allow: true });
      }
      return e.kind === 'result';
    });
    assert.deepEqual(events.map((e) => e.kind), ['user', 'delta', 'status', 'permission', 'permissionResolved', 'status', 'assistant', 'result']);
    assert.equal(events.find((e) => e.kind === 'delta').seq, undefined, 'streaming text is not buffered');
    assert.equal(events.find((e) => e.kind === 'assistant').text, 'allow:go');
    assert.equal(sdk.verdicts[0].updatedPermissions, undefined);
    assert.equal(events.at(-1).cost, 0.01);
  });
});

test('a stream opened mid-reply first gets the text written so far', async () => {
  await withServer(async ({ call, post }) => {
    const { id } = await (await post('/sessions', { cwd: TMP, prompt: 'go' })).json();
    await new Promise((r) => setTimeout(r, 120)); // the delta has gone out to nobody; the permission is pending
    const events = await readEvents(await call(`/sessions/${id}/events`), async (e) => e.kind === 'delta');
    assert.deepEqual(events.at(-1), { kind: 'delta', text: 'thinking…' });
  });
});

test('always allow, deny with feedback, and question answers reach the SDK', async () => {
  await withServer(async (ctx) => {
    await runTurn(ctx, {}, { allow: true, always: true });
    assert.deepEqual(ctx.sdk.verdicts[0].updatedPermissions, [{ type: 'addRules', rules: [{ toolName: 'Bash' }], behavior: 'allow', destination: 'session' }]);
    const { events } = await runTurn(ctx, {}, { allow: false, message: 'use git status instead' });
    assert.deepEqual(ctx.sdk.verdicts[1], { behavior: 'deny', message: 'use git status instead' });
    assert.equal(events.find((e) => e.kind === 'assistant').text, 'deny:go');
    await runTurn(ctx, {}, { allow: true, answers: { 'Which DB?': 'Postgres' } });
    assert.deepEqual(ctx.sdk.verdicts[2].updatedInput, { command: 'ls', answers: { 'Which DB?': 'Postgres' } });
  });
});

test('photos are sent as image blocks before the text', async () => {
  await withServer(async (ctx) => {
    const { events } = await runTurn(ctx, { images: [{ mediaType: 'image/png', data: PNG }] }, { allow: true });
    assert.deepEqual(events[0], { kind: 'user', text: 'go', images: 1, seq: 1 });
    assert.equal(events.find((e) => e.kind === 'assistant').text, 'allow:image+text');
  });
});

test('mode and model switch on a live session; rename; delete refused while live', async () => {
  await withServer(async ({ post, call, sdk }) => {
    const { id } = await (await post('/sessions', { cwd: TMP, prompt: 'go' })).json();
    const r = await (await post(`/sessions/${id}/settings`, { mode: 'acceptEdits', model: 'default' })).json();
    assert.deepEqual(r, { mode: 'acceptEdits', model: 'default', effort: 'default' });
    assert.deepEqual(sdk.calls.slice(0, 2), [['mode', 'acceptEdits'], ['model', undefined]]);
    assert.equal((await post(`/sessions/${id}/settings`, { mode: 'yolo' })).status, 400);
    assert.equal((await post(`/sessions/${SID}/settings`, { mode: 'plan' })).status, 409);
    assert.equal((await post(`/sessions/${id}/rename`, { title: '  Better name ' })).status, 200);
    assert.deepEqual(sdk.calls.at(-1), ['rename', id, 'Better name']);
    assert.equal((await call(`/sessions/${id}`, { method: 'DELETE' })).status, 409);
    assert.equal((await call(`/sessions/${SID}`, { method: 'DELETE' })).status, 204);
    assert.deepEqual(sdk.calls.at(-1), ['delete', SID]);
  });
});

test('pushes go out only when no one is watching the session', async () => {
  const sent = [];
  const pusher = { enabled: true, register: (t) => /^[0-9a-f]{64}$/.test(t), notify: async (p) => { sent.push(p); } };
  await withServer(async ({ post, call }) => {
    assert.equal((await post('/devices', { token: 'a'.repeat(64), sandbox: true })).status, 204);
    assert.equal((await (await call('/info')).json()).push, true);
    // Nobody is streaming: the permission request becomes a push with the request id for lock-screen actions.
    const { id } = await (await post('/sessions', { cwd: TMP, prompt: 'go' })).json();
    await new Promise((r) => setTimeout(r, 200));
    assert.equal(sent[0].kind, 'permission');
    assert.equal(sent[0].sessionId, id);
    assert.ok(sent[0].requestId);
    await post(`/sessions/${id}/permissions/${sent[0].requestId}`, { allow: true });
    await new Promise((r) => setTimeout(r, 200));
    assert.deepEqual([sent[1].kind, sent[1].body], ['done', 'allow:go']);
    // Watching in the app: no pushes.
    await runTurn({ call, post }, {}, { allow: true });
    assert.equal(sent.length, 2);
  }, { pusher, pushDelayMs: 30 });
});

test('usage by day reads transcripts, counts each message once, groups by project and model', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'usage-'));
  const folder = path.join(dir, 'projects', '-Users-me-app');
  fs.mkdirSync(folder, { recursive: true });
  const now = new Date('2026-10-19T12:00:00');
  const at = (d) => new Date(`2026-10-${d}T10:00:00`).toISOString();
  const line = (o) => JSON.stringify(o);
  fs.writeFileSync(path.join(folder, 's.jsonl'), [
    line({ type: 'user', cwd: '/Users/me/app', timestamp: at(18) }),
    line({ type: 'assistant', timestamp: at(18), message: { id: 'a', model: 'claude-opus-5-5', usage: { input_tokens: 0, output_tokens: 0, iterations: [{ input_tokens: 2, output_tokens: 20 }] } } }),
    line({ type: 'assistant', timestamp: at(18), message: { id: 'a', model: 'claude-opus-5-5', usage: { input_tokens: 9, output_tokens: 9 } } }),
    line({ type: 'assistant', timestamp: at(19), message: { id: 'b', model: 'claude-sonnet-5-5', usage: { input_tokens: 1, output_tokens: 5, cache_read_input_tokens: 100 } } }),
    'not json',
  ].join('\n'));
  const u = usageByDay({ dirs: [dir], days: 3, now: now.getTime() });
  assert.deepEqual(u.days.map((d) => [d.date, d.output]), [['2026-10-17', 0], ['2026-10-18', 20], ['2026-10-19', 5]]);
  assert.deepEqual(u.projects, [{ name: 'app', input: 3, output: 25, cacheRead: 100, cacheWrite: 0 }]);
  assert.deepEqual(u.models, [{ name: 'claude-opus-5-5', output: 20 }, { name: 'claude-sonnet-5-5', output: 5 }]);
  assert.equal(summarizeTranscript('').cwd, undefined);
});

test('usage endpoint serves the summary', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'usage-'));
  await withServer(async ({ call }) => {
    const u = await (await call('/usage?days=7')).json();
    assert.equal(u.days.length, 7);
  }, { dirs: [dir] });
});

test('APNs JWT verifies with the key; payload carries lock-screen actions only for permissions', () => {
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'P-256' });
  const jwt = apnsJwt({ keyPem: privateKey.export({ type: 'pkcs8', format: 'pem' }), keyId: 'KEY123', teamId: 'TEAM1' }, 1_700_000_000_000);
  const [h, p, sig] = jwt.split('.');
  assert.deepEqual(JSON.parse(Buffer.from(h, 'base64url')), { alg: 'ES256', kid: 'KEY123' });
  assert.deepEqual(JSON.parse(Buffer.from(p, 'base64url')), { iss: 'TEAM1', iat: 1_700_000_000 });
  assert.ok(crypto.verify('sha256', Buffer.from(`${h}.${p}`), { key: publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(sig, 'base64url')));
  const perm = buildPayload({ kind: 'permission', title: 'app', body: 'Bash: ls', sessionId: SID, requestId: 'r1' });
  assert.equal(perm.aps.category, 'PERMISSION');
  assert.equal(perm.requestId, 'r1');
  assert.equal(buildPayload({ kind: 'done', title: 'app', body: 'ok', sessionId: SID }).aps.category, undefined);
});

test('sumUsage counts each message once and prefers iterations', () => {
  const u = sumUsage([
    { type: 'assistant', message: { id: 'a', usage: { input_tokens: 0, output_tokens: 0, iterations: [{ input_tokens: 2, output_tokens: 21, cache_read_input_tokens: 100 }] } } },
    { type: 'assistant', message: { id: 'a', usage: { input_tokens: 9, output_tokens: 9 } } },
    { type: 'assistant', message: { id: 'b', usage: { input_tokens: 1, output_tokens: 1, cache_creation_input_tokens: 7 } } },
    { type: 'user', message: { usage: { input_tokens: 50 } } },
  ]);
  assert.deepEqual(u, { input: 3, output: 22, cacheRead: 100, cacheWrite: 7 });
});

test('mapContent: text, tools with diff input, harness messages as meta, images counted', () => {
  assert.deepEqual(mapContent('assistant', { content: [
    { type: 'thinking', thinking: '' },
    { type: 'text', text: 'ok' },
    { type: 'tool_use', name: 'Edit', input: { file_path: '/a.swift', old_string: 'a', new_string: 'b', replace_all: false } },
  ] }), [
    { kind: 'assistant', text: 'ok' },
    { kind: 'tool', name: 'Edit', text: '/a.swift', input: { file_path: '/a.swift', old_string: 'a', new_string: 'b' } },
  ]);
  assert.deepEqual(mapContent('user', { content: [{ type: 'tool_result', content: 'x' }] }), []);
  assert.equal(mapContent('user', { content: 'x'.repeat(16000) })[0].text.length, 4001);
  assert.equal(mapContent('user', { content: '<task-notification>done</task-notification>' })[0].kind, 'meta');
  assert.deepEqual(mapContent('user', { content: [{ type: 'image' }, { type: 'text', text: 'look' }] }), [{ kind: 'user', text: 'look', images: 1 }]);
  assert.equal(displayInput('Read', { file_path: '/x' }), undefined);
  assert.equal(displayInput('ExitPlanMode', { plan: '# Plan' }).plan, '# Plan');
});

test('launchd plist is valid and runs this server at login with the user PATH', { skip: process.platform !== 'darwin' && 'macOS only' }, () => {
  const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'plist-')), 'a.plist');
  fs.writeFileSync(file, plist());
  assert.match(execFileSync('plutil', ['-lint', file], { encoding: 'utf8' }), /OK/);
  const parsed = JSON.parse(execFileSync('plutil', ['-convert', 'json', '-o', '-', file], { encoding: 'utf8' }));
  assert.equal(fs.realpathSync(parsed.ProgramArguments[0]), fs.realpathSync(process.execPath));
  assert.ok(!parsed.ProgramArguments[0].includes('/Cellar/'), 'stable node path');
  assert.equal(parsed.ProgramArguments[1], path.join(import.meta.dirname, 'server.mjs'));
  assert.equal(parsed.RunAtLoad, true);
  assert.equal(parsed.KeepAlive, true);
  assert.equal(parsed.EnvironmentVariables.PATH, process.env.PATH);
});

test('folder is read from the transcript when the SDK list has none (first message holds a big photo)', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'cwd-'));
  const id = '99999999-2222-3333-4444-555555555555';
  fs.mkdirSync(path.join(dir, 'projects', '-private-tmp'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'projects', '-private-tmp', `${id}.jsonl`), [
    JSON.stringify({ type: 'queue-operation' }),
    JSON.stringify({ type: 'user', cwd: '/Users/me/my "odd" app', message: { content: [{ type: 'image', source: { data: 'x'.repeat(200_000) } }] } }),
  ].join('\n'));
  assert.equal(transcriptCwd(id, dir), '/Users/me/my "odd" app');
  assert.equal(transcriptCwd('00000000-0000-0000-0000-000000000000', dir), undefined);
  const sdk = fakeSdk();
  sdk.listSessions = async () => [{ sessionId: id, summary: 'photo', lastModified: 1 }];
  await withServer(async ({ call }) => {
    assert.equal((await (await call('/sessions')).json())[0].cwd, '/Users/me/my "odd" app');
  }, { sdk, dirs: [dir] });
});

// Real `ps -axo pid=,ppid=,etime=,command=` shapes (paths shortened): the desktop app, a desktop session
// (wrapper + child), a Terminal session, an npm-installed CLI, and things that only look similar.
const PS = `  301     1 02:12:00 /Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=/Users/me/.claude-instances/work
  398   301 02:11:28 /Users/me/.claude-instances/work/claude-code/2.1.295/abc/claude.app/Contents/MacOS/claude --output-format stream-json --resume=b9ebbf56-23d0-4892-8c7e-8e15a2ea6188
  399   398 02:11:28 /Users/me/.claude-instances/work/claude-code/2.1.295/abc/claude.app/Contents/MacOS/claude --output-format stream-json --resume=b9ebbf56-23d0-4892-8c7e-8e15a2ea6188
  500   480 1-03:00:05 claude
  510   480    00:10 node /opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js --session-id 11111111-2222-3333-4444-555555555555
  600     1    05:00 /Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)
  700   480    00:01 grep claude
  800  4242    00:30 /opt/homebrew/bin/claude --resume=99999999-2222-3333-4444-555555555555`;

test('finds Claude Code processes: one per session, desktop vs Terminal, ids from --resume/--session-id', () => {
  const now = 1_000_000_000;
  const rows = parseClaudeProcesses(PS, now).map(({ pid, sessionId, source, startedAt }) => ({ pid, sessionId, source, startedAt }));
  assert.deepEqual(rows, [
    { pid: 398, sessionId: 'b9ebbf56-23d0-4892-8c7e-8e15a2ea6188', source: 'desktop', startedAt: now - (2 * 3600 + 11 * 60 + 28) * 1000 },
    { pid: 500, sessionId: undefined, source: 'terminal', startedAt: now - (86400 + 3 * 3600 + 5) * 1000 },
    { pid: 510, sessionId: '11111111-2222-3333-4444-555555555555', source: 'terminal', startedAt: now - 10_000 },
    { pid: 800, sessionId: '99999999-2222-3333-4444-555555555555', source: 'terminal', startedAt: now - 30_000 },
  ]);
});

test('running sessions: Terminal sessions without an id match the newest transcript in their folder; this server\'s own children are skipped', () => {
  const dir = emptyDir();
  const folder = path.join(dir, 'projects', projectFolder('/Users/me/R.O.A.D. app'));
  fs.mkdirSync(folder, { recursive: true });
  fs.writeFileSync(path.join(folder, 'aaaaaaaa-0000-0000-0000-000000000000.jsonl'), '');
  const old = path.join(folder, 'bbbbbbbb-0000-0000-0000-000000000000.jsonl');
  fs.writeFileSync(old, '');
  fs.utimesSync(old, new Date(0), new Date(0));
  const cwdOf = () => ({ 398: '/Users/me/work', 500: '/Users/me/R.O.A.D. app', 510: '/nowhere' });
  const running = runningSessions([dir], { ps: PS, cwdOf, excludeParent: 4242, platform: 'darwin' });
  assert.deepEqual([...running.keys()].sort(), ['11111111-2222-3333-4444-555555555555', 'aaaaaaaa-0000-0000-0000-000000000000', 'b9ebbf56-23d0-4892-8c7e-8e15a2ea6188']);
  assert.deepEqual(running.get('b9ebbf56-23d0-4892-8c7e-8e15a2ea6188').pids, [398]);
  assert.equal(running.get('aaaaaaaa-0000-0000-0000-000000000000').source, 'terminal');
  assert.equal(projectFolder('/Users/me/my_app'), '-Users-me-my-app');
});

test('stop on Mac signals only the processes running that session; continuing it from the phone waits until it stops', async () => {
  const signals = [];
  const scan = () => new Map([[SID, { pids: [398, 399], source: 'desktop', cwd: TMP, startedAt: 1 }]]);
  await withServer(async ({ post, call }) => {
    assert.equal((await post(`/sessions/${SID}/messages`, { text: 'hi' })).status, 409);
    assert.equal((await call(`/sessions/${SID}`, { method: 'DELETE' })).status, 409);
    const r = await post(`/sessions/${SID}/stop-mac`, {});
    assert.deepEqual(await r.json(), { ok: true, stopped: 2 });
    assert.deepEqual(signals, [[398, 'SIGINT'], [399, 'SIGINT']]);
    assert.equal((await post('/sessions/22222222-2222-3333-4444-555555555555/stop-mac', {})).status, 404);
    assert.equal((await post('/sessions/not-an-id/stop-mac', {})).status, 400);
    assert.equal(signals.length, 2);
  }, { scan, signal: (pid, sig) => { if (sig === 0) throw new Error('exited'); signals.push([pid, sig]); } });
});

test('every sessions folder is listed; a session resumes with its own folder; login state per folder', async () => {
  const work = emptyDir(), home = emptyDir();
  const sdk = fakeSdk();
  const ids = { [work]: '33333333-2222-3333-4444-555555555555', [home]: '44444444-2222-3333-4444-555555555555' };
  sdk.listSessions = async () => [{ sessionId: ids[process.env.CLAUDE_CONFIG_DIR], summary: 's', cwd: TMP, lastModified: ids[process.env.CLAUDE_CONFIG_DIR] === ids[home] ? 2 : 1 }];
  const auth = async (d) => ({ loggedIn: d === home, authMethod: d === home ? 'claude.ai' : 'none' });
  await withServer(async ({ call, post }) => {
    const list = await (await call('/sessions')).json();
    assert.deepEqual(list.map((s) => [s.id, s.dir]), [[ids[home], home], [ids[work], work]]);
    await post(`/sessions/${ids[home]}/messages`, { text: 'go' });
    assert.equal(sdk.options.env.CLAUDE_CONFIG_DIR, home);
    assert.equal(sdk.options.resume, ids[home]);
    const info = await (await call('/info')).json();
    assert.deepEqual(info.accounts, [{ dir: work, loggedIn: false, method: 'none' }, { dir: home, loggedIn: true, method: 'claude.ai' }]);
    assert.deepEqual(info.dirs, [work, home]);
  }, { sdk, dirs: [work, home], auth });
});

test('a login failure from Claude becomes a clear notice', async () => {
  const sdk = fakeSdk();
  sdk.query = ({ prompt }) => {
    async function* run() {
      for await (const _ of prompt) { // like a real session, it stays open for the next message
        yield { type: 'assistant', parent_tool_use_id: null, message: { content: [{ type: 'text', text: 'Failed to authenticate: OAuth session expired and could not be refreshed' }] } };
        yield { type: 'result', subtype: 'success', is_error: true, total_cost_usd: 0 };
      }
    }
    return Object.assign(run(), { interrupt: async () => {} });
  };
  await withServer(async ({ call, post }) => {
    const { id } = await (await post('/sessions', { cwd: TMP, prompt: 'go' })).json();
    const events = await readEvents(await call(`/sessions/${id}/events`), async (e) => e.kind === 'result');
    assert.deepEqual(events.find((e) => e.kind === 'notice'), { kind: 'notice', status: 'auth', seq: 3 });
  }, { sdk });
});

test('usage adds up every sessions folder', () => {
  const mk = (out) => {
    const dir = emptyDir();
    fs.mkdirSync(path.join(dir, 'projects', 'p'), { recursive: true });
    fs.writeFileSync(path.join(dir, 'projects', 'p', 's.jsonl'), JSON.stringify({ type: 'assistant', cwd: '/x/app', timestamp: new Date().toISOString(), message: { id: 'm' + out, usage: { output_tokens: out } } }));
    return dir;
  };
  const u = usageByDay({ dirs: [mk(5), mk(7)], days: 1 });
  assert.equal(u.days[0].output, 12);
});

test('effort: set when starting, changed live, validated', async () => {
  await withServer(async ({ post, sdk }) => {
    assert.equal((await post('/sessions', { cwd: TMP, prompt: 'x', effort: 'huge' })).status, 400);
    const { id } = await (await post('/sessions', { cwd: TMP, prompt: 'go', effort: 'low' })).json();
    assert.equal(sdk.options.effort, 'low');
    assert.deepEqual(await (await post(`/sessions/${id}/settings`, { effort: 'max' })).json(), { mode: 'default', effort: 'max' });
    assert.deepEqual(sdk.calls.at(-1), ['flags', { effortLevel: 'max' }]);
    await post(`/sessions/${id}/settings`, { effort: 'default' });
    assert.deepEqual(sdk.calls.at(-1), ['flags', { effortLevel: null }]);
  });
  await withServer(async ({ post, sdk }) => {
    await post('/sessions', { cwd: TMP, prompt: 'go' });
    assert.equal('effort' in sdk.options, false, 'no effort sent unless chosen');
  });
});

test('fork copies a session; export gives the full transcript as Markdown', async () => {
  await withServer(async ({ post, call, sdk }) => {
    const r = await post(`/sessions/${SID}/fork`, {});
    assert.equal(r.status, 201);
    assert.deepEqual(await r.json(), { id: '77777777-2222-3333-4444-555555555555' });
    assert.deepEqual(sdk.calls.at(-1), ['fork', SID]);
    const md = await (await call(`/sessions/${SID}/export`)).text();
    assert.equal(md, '# Fix tests\n\n**You:** hi\n\nhello\n');
  });
  const long = 'y'.repeat(9000);
  assert.ok(exportMarkdown('t', [{ type: 'assistant', message: { content: [{ type: 'text', text: long }, { type: 'tool_use', name: 'Bash', input: { command: 'npm test\nmore' } }] } }]).includes(long + '\n\n> Bash: `npm test`'), 'not clipped; tool one line');
});

test('folder picker lists only folders inside home; no escaping by .. or symlink', async () => {
  const home = fs.realpathSync(emptyDir());
  fs.mkdirSync(path.join(home, 'b-app', '.git'), { recursive: true });
  fs.mkdirSync(path.join(home, 'A-site'));
  fs.mkdirSync(path.join(home, '.hidden'));
  fs.writeFileSync(path.join(home, 'file.txt'), '');
  const outside = fs.realpathSync(emptyDir());
  fs.symlinkSync(outside, path.join(home, 'link-out'));
  const l = listFolders(home, home);
  assert.deepEqual(l.dirs.map((d) => [d.name, d.repo]), [['A-site', false], ['b-app', true]]);
  assert.equal(l.parent, null);
  assert.equal(listFolders(home, path.join(home, 'b-app')).parent, home);
  assert.equal(listFolders(home, path.join(home, 'b-app')).repo, true);
  assert.equal(listFolders(home, path.join(home, '..')), null);
  assert.equal(listFolders(home, path.join(home, 'link-out')), null);
  assert.equal(listFolders(home, '/etc'), null);
  assert.equal(listFolders(home, path.join(home, 'nope')), null);
  await withServer(async ({ call }) => {
    assert.equal((await (await call(`/folders?path=${encodeURIComponent(home)}`)).json()).dirs.length, 2);
    assert.equal((await call('/folders?path=%2Fetc')).status, 404);
  }, { home });
});

test('changes view: modified, added, deleted, renamed and untracked files from git', async () => {
  const repo = fs.realpathSync(emptyDir());
  const git = (...a) => execFileSync('git', ['-C', repo, ...a], { env: { ...process.env, GIT_AUTHOR_NAME: 't', GIT_AUTHOR_EMAIL: 't@t', GIT_COMMITTER_NAME: 't', GIT_COMMITTER_EMAIL: 't@t' } });
  git('init', '-q', '-b', 'main');
  fs.writeFileSync(path.join(repo, 'a.txt'), 'one\ntwo\n');
  fs.writeFileSync(path.join(repo, 'gone.txt'), 'x\n');
  fs.writeFileSync(path.join(repo, 'old name.txt'), 'same\n');
  git('add', '.'); git('commit', '-qm', 'init');
  fs.writeFileSync(path.join(repo, 'a.txt'), 'one\nTWO\nthree\n');
  fs.rmSync(path.join(repo, 'gone.txt'));
  git('mv', 'old name.txt', 'new name.txt');
  fs.writeFileSync(path.join(repo, 'new.js'), 'let x = 1\n');
  fs.writeFileSync(path.join(repo, 'pic.png'), Buffer.from([0x89, 0x50, 0x4e, 0x47, 0, 0, 0, 13, 10, 10, 10]));
  const c = await gitChanges(repo);
  assert.equal(c.repo, true);
  assert.equal(c.branch, 'main');
  assert.deepEqual(c.files.map((f) => [f.path, f.status, f.added, f.removed]), [
    ['a.txt', 'modified', 2, 1], ['gone.txt', 'deleted', 0, 1], ['new name.txt', 'renamed', null, null], ['new.js', 'added', 2, 0],
    ['pic.png', 'added', null, null],
  ]);
  assert.equal(c.files[4].diff, '');
  assert.match(c.files[0].diff, /-two\n\+TWO\n\+three/);
  assert.equal(c.files[3].diff, '+let x = 1\n+');
  assert.deepEqual(await gitChanges(fs.realpathSync(emptyDir())), { repo: false, files: [] });
  await withServer(async ({ call }) => {
    assert.equal((await (await call(`/sessions/${SID}/changes`)).json()).files.length, 5);
  }, { changes: () => gitChanges(repo) });
});

test('slash commands come from a short probe process when the session is not running', async () => {
  await withServer(async ({ call, sdk }) => {
    const list = await (await call(`/sessions/${SID}/commands`)).json();
    assert.deepEqual(list, [
      { name: 'compact', description: 'Compact', argumentHint: '<instructions>', builtin: true },
      { name: 'review', description: 'Review code', builtin: false },
    ]);
    assert.ok(sdk.calls.some((c) => c[0] === 'close'), 'probe process is closed');
    assert.equal(sdk.options.cwd, TMP);
    const before = sdk.calls.length;
    await call(`/sessions/${SID}/commands`);
    assert.equal(sdk.calls.length, before, 'cached');
  });
});

test('plan meter reads plan limits; unavailable when the account has none', async () => {
  await withServer(async ({ call }) => {
    assert.deepEqual(await (await call('/plan')).json(), {
      available: true, subscription: 'max', fiveHour: { utilization: 42, resetsAt: '2026-10-21T15:00:00Z' }, sevenDay: { utilization: 10, resetsAt: null },
    });
  });
  const sdk = fakeSdk();
  sdk.usage = { rate_limits_available: false, subscription_type: null, rate_limits: null };
  await withServer(async ({ call }) => {
    assert.deepEqual(await (await call('/plan')).json(), { available: false, subscription: null });
  }, { sdk });
  assert.deepEqual(planFromUsage(undefined), { available: false, subscription: null });
});

test('notification choices per phone; Live Activity follows the session', async () => {
  assert.equal(wantsNotification({}, 'done'), true);
  assert.equal(wantsNotification({ prefs: { done: false, needsYou: true } }, 'done'), false);
  assert.equal(wantsNotification({ prefs: { done: false, needsYou: true } }, 'permission'), true);
  assert.equal(wantsNotification({ prefs: { needsYou: false, done: true } }, 'question'), false);
  const p = buildActivityPayload({ status: 'waiting', title: 't' }, { alert: { title: 't', body: 'Bash: ls' }, now: 1_700_000_000_000 });
  assert.deepEqual(p.aps, { timestamp: 1_700_000_000, event: 'update', 'content-state': { status: 'waiting', title: 't' }, alert: { title: 't', body: 'Bash: ls' }, sound: 'default' });
  assert.equal(buildActivityPayload({}, { end: true, now: 0 }).aps['dismissal-date'], 900);

  const sent = [], registered = [];
  const pusher = { enabled: true, register: (...a) => registered.push(a) > 0, notify: async () => {}, activity: async (t, state, o) => { sent.push({ t, state, o }); } };
  await withServer(async ({ post, call }) => {
    assert.equal((await post('/devices', { token: 'b'.repeat(64), prefs: { done: false } })).status, 204);
    assert.deepEqual(registered[0], ['b'.repeat(64), false, { needsYou: true, done: false }]);
    const { id } = await (await post('/sessions', { cwd: TMP, prompt: 'go' })).json();
    assert.equal((await post(`/sessions/${id}/activity`, { token: 'nope' })).status, 400);
    assert.equal((await post(`/sessions/${id}/activity`, { token: 'c'.repeat(64), sandbox: true })).status, 204);
    await readEvents(await call(`/sessions/${id}/events`), async (e) => {
      if (e.kind === 'permission') await post(`/sessions/${id}/permissions/${e.id}`, { allow: true });
      return e.kind === 'result';
    });
    const waiting = sent.find((x) => x.state.status === 'waiting');
    assert.deepEqual(waiting.t, { token: 'c'.repeat(64), sandbox: true });
    assert.equal(waiting.state.detail, 'Claude wants to run ls');
    assert.ok(waiting.state.requestId);
    assert.equal(waiting.o.alert.body, 'Claude wants to run ls');
    assert.equal(sent.at(-1).state.status, 'idle');
  }, { pusher, activityThrottleMs: 0 });
});

test('a model that needs usage credits becomes a clear notice', async () => {
  const sdk = fakeSdk();
  sdk.query = ({ prompt }) => {
    async function* run() {
      for await (const _ of prompt) {
        yield { type: 'assistant', parent_tool_use_id: null, message: { content: [{ type: 'text', text: 'Fable 5.1 requires usage credits. Switch to another model, or manage usage credits.' }] } };
        yield { type: 'result', subtype: 'success', is_error: true, total_cost_usd: 0 };
      }
    }
    return Object.assign(run(), { interrupt: async () => {} });
  };
  await withServer(async ({ call, post }) => {
    const { id } = await (await post('/sessions', { cwd: TMP, prompt: 'go' })).json();
    const events = await readEvents(await call(`/sessions/${id}/events`), async (e) => e.kind === 'result');
    assert.equal(events.find((e) => e.kind === 'notice')?.status, 'credits');
  }, { sdk });
});

test('a continued session is shown as running under its newest copy', () => {
  const base = { dir: '/c', cwd: '/w', firstPrompt: 'build an app', createdAt: 1000 };
  const list = [ // newest first, like listSessions
    { ...base, sessionId: 'new', createdAt: 1100, lastModified: 9000 },
    { ...base, sessionId: 'fork-elsewhere', cwd: '/other', lastModified: 8500 },
    { ...base, sessionId: 'old', lastModified: 8000 },
    { ...base, sessionId: 'unrelated', firstPrompt: 'other', lastModified: 7000 },
    { ...base, sessionId: 'stale', lastModified: 100 },
  ];
  const run = (startedAt) => ({ pids: [1], source: 'desktop', startedAt });
  assert.deepEqual([...followContinued(new Map([['old', run(5000)]]), list).keys()], ['new']);
  // A copy written before the process started is not its continuation.
  assert.deepEqual([...followContinued(new Map([['stale', run(9500)]]), list).keys()], ['stale']);
  // Another process running the newer copy, or this server running it, keeps the ids apart.
  assert.deepEqual([...followContinued(new Map([['old', run(5000)], ['new', run(5000)]]), list).keys()].sort(), ['new', 'old']);
  assert.deepEqual([...followContinued(new Map([['old', run(5000)]]), list, new Set(['new'])).keys()], ['old']);
  // Sessions missing from the list, or without a first prompt, stay as they are.
  assert.deepEqual([...followContinued(new Map([['gone', run(5000)]]), list).keys()], ['gone']);
  assert.deepEqual([...followContinued(new Map([['old', run(5000)]]), list.map((x) => ({ ...x, firstPrompt: undefined }))).keys()], ['old']);
  // Reopened in the desktop app: a transcript with the same title, written since the process started.
  const reopened = [
    { dir: '/c', cwd: '/w', sessionId: 'fresh', customTitle: 'Perf', createdAt: 1_000, lastModified: 900_000 },
    { dir: '/c', cwd: '/w', sessionId: 'other', customTitle: 'Other', createdAt: 700_000, lastModified: 890_000 },
    { dir: '/c', cwd: '/w', sessionId: 'quiet', customTitle: 'Perf', createdAt: 2_000, lastModified: 500_000 },
    { dir: '/c', cwd: '/w', sessionId: 'orig', customTitle: 'Perf', createdAt: 900, lastModified: 400_000 },
  ];
  assert.deepEqual([...followContinued(new Map([['orig', run(600_000)]]), reopened).keys()], ['fresh']);
  // A same-titled transcript last written before the process started is not where it writes.
  assert.deepEqual([...followContinued(new Map([['orig', run(600_000)]]), reopened.filter((x) => x.sessionId !== 'fresh')).keys()], ['orig']);
});

test('Stop on Mac follows up with SIGTERM when Ctrl-C does not end the process', async () => {
  const signals = [];
  const scan = () => new Map([[SID, { pids: [398], source: 'terminal', cwd: TMP, startedAt: 0 }]]);
  const sdk = fakeSdk();
  sdk.listSessions = async () => [{ sessionId: SID, summary: 's', cwd: TMP, lastModified: 1 }];
  await withServer(async ({ post }) => {
    assert.deepEqual(await (await post(`/sessions/${SID}/stop-mac`, {})).json(), { ok: true, stopped: 1 });
    assert.deepEqual(signals.filter(([, sig]) => sig !== 0), [[398, 'SIGINT'], [398, 'SIGTERM']]);
  }, { scan, sdk, signal: (pid, sig) => signals.push([pid, sig]) });
});

test('Windows processes: desktop app and terminal sessions from Win32_Process JSON', () => {
  const id = 'aaaaaaaa-1111-2222-3333-444444444444';
  // Windows PowerShell 5.1 writes dates as /Date(ms)/; the desktop app runs a wrapper and a child with the same arguments.
  const ps51 = JSON.stringify([
    { ProcessId: 100, ParentProcessId: 4, CreationDate: '/Date(1792600000000)/',
      CommandLine: `"C:\\Users\\dev\\AppData\\Roaming\\Claude\\claude-code\\2.1.295\\claude.exe" --output-format stream-json --resume=${id}` },
    { ProcessId: 101, ParentProcessId: 100, CreationDate: '/Date(1792600000100)/',
      CommandLine: `"C:\\Users\\dev\\AppData\\Roaming\\Claude\\claude-code\\2.1.295\\claude.exe" --output-format stream-json --resume=${id}` },
    { ProcessId: 200, ParentProcessId: 50, CreationDate: '/Date(1792600500000)/',
      CommandLine: 'C:\\Users\\dev\\.local\\bin\\claude.exe --resume bbbbbbbb-1111-2222-3333-444444444444' },
    // npm install: node running cli.js; and unrelated node and Claude desktop processes
    { ProcessId: 300, ParentProcessId: 60, CreationDate: '/Date(1792600900000)/',
      CommandLine: '"C:\\Program Files\\nodejs\\node.exe" C:\\Users\\dev\\AppData\\Roaming\\npm\\node_modules\\@anthropic-ai\\claude-code\\cli.js' },
    { ProcessId: 400, ParentProcessId: 60, CreationDate: '/Date(1792600900000)/', CommandLine: '"C:\\Program Files\\nodejs\\node.exe" server.js' },
    { ProcessId: 500, ParentProcessId: 1, CreationDate: '/Date(1792600900000)/', CommandLine: '"C:\\Users\\dev\\AppData\\Local\\AnthropicClaude\\app-1.0\\Claude.exe"' },
  ]);
  const rows = parseWindowsProcesses(ps51);
  assert.deepEqual(rows.map((r) => [r.pid, r.source, r.sessionId ?? null]), [
    [100, 'desktop', id], [200, 'terminal', 'bbbbbbbb-1111-2222-3333-444444444444'], [300, 'terminal', null],
  ]);
  assert.equal(rows[0].startedAt, 1792600000000);
  // PowerShell 7 writes ISO dates, and a single process comes back as an object, not an array.
  const ps7 = JSON.stringify({ ProcessId: 7, ParentProcessId: 1, CreationDate: '2026-10-22T09:00:00+00:00', CommandLine: `claude.exe --resume=${id}` });
  assert.deepEqual(parseWindowsProcesses(ps7).map((r) => [r.pid, r.startedAt]), [[7, Date.parse('2026-10-22T09:00:00+00:00')]]);
  assert.deepEqual(parseWindowsProcesses(''), []);
  assert.deepEqual(parseWindowsProcesses('not json'), []);
  // runningSessions on Windows: by --resume id; a session without an id cannot be matched to a folder there.
  const running = runningSessions([], { platform: 'win32', winJson: ps51, excludeParent: 0 });
  assert.deepEqual([...running.keys()].sort(), [id, 'bbbbbbbb-1111-2222-3333-444444444444']);
  assert.deepEqual(running.get(id).pids, [100]);
});

test('Windows login item: hidden Startup launcher that restarts the server', () => {
  const w = windowsLauncher({ node: 'C:\\Program Files\\nodejs\\node.exe', dir: 'C:\\Users\\dev\\tether\\server', state: 'C:\\Users\\dev\\.tether',
    env: { PORT: '8787', CLAUDE_CONFIG_DIR: 'C:\\Users\\dev\\.claude-100%' } });
  const lines = w.cmd.split('\r\n');
  assert.equal(w.cmdPath, 'C:\\Users\\dev\\.tether\\start.cmd');
  assert.ok(lines.includes('set "PORT=8787"'));
  assert.ok(lines.includes('set "CLAUDE_CONFIG_DIR=C:\\Users\\dev\\.claude-100%%"'), 'percent signs escaped for cmd');
  assert.ok(lines.includes('cd /d "C:\\Users\\dev\\tether\\server"'));
  const run = lines.indexOf(':loop');
  assert.equal(lines[run + 1], '"C:\\Program Files\\nodejs\\node.exe" "C:\\Users\\dev\\tether\\server\\server.mjs" >> "C:\\Users\\dev\\.tether\\server.log" 2>&1');
  assert.equal(lines[run + 3], 'goto loop');
  // hidden window (style 0), not waiting
  assert.equal(w.vbs, 'CreateObject("WScript.Shell").Run """C:\\Users\\dev\\.tether\\start.cmd""", 0, False\r\n');
  // without CLAUDE_CONFIG_DIR no empty variable is set
  assert.ok(!windowsLauncher({ env: {} }).cmd.includes('CLAUDE_CONFIG_DIR'));
});
