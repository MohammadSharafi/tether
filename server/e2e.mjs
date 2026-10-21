// End-to-end check against the running server and a real Claude Code session.
// Starts a session in a temp folder, approves the Write it asks for, waits for
// the result, then checks the file exists. Costs a few cents of usage.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { loadToken } from './server.mjs';

const base = process.env.SERVER ?? 'http://127.0.0.1:8787';
const headers = { authorization: `Bearer ${loadToken()}`, 'content-type': 'application/json' };
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tether-e2e-'));
const timer = setTimeout(() => { console.log('E2E_TIMEOUT'); process.exit(1); }, 180_000);

const start = await fetch(`${base}/sessions`, {
  method: 'POST', headers,
  // A model every paid plan includes; override with E2E_MODEL.
  body: JSON.stringify({ cwd: dir, model: process.env.E2E_MODEL ?? 'sonnet', prompt: 'Use the Write tool to create hello.txt containing the word hi. Then reply DONE.' }),
});
const { id } = await start.json();
console.log('session', id, start.status);

const res = await fetch(`${base}/sessions/${id}/events`, { headers });
let buf = '', asked = 0, result = null;
const dec = new TextDecoder();
outer: for await (const chunk of res.body) {
  buf += dec.decode(chunk);
  let i;
  while ((i = buf.indexOf('\n\n')) >= 0) {
    const data = buf.slice(0, i).split('\n').find((l) => l.startsWith('data: '));
    buf = buf.slice(i + 2);
    if (!data) continue;
    const e = JSON.parse(data.slice(6));
    console.log(e.kind, e.name ?? '', (e.text ?? e.state ?? '').slice(0, 80));
    if (e.kind === 'permission') {
      asked++;
      await fetch(`${base}/sessions/${id}/permissions/${e.id}`, { method: 'POST', headers, body: '{"allow":true}' });
    }
    if (e.kind === 'result') { result = e; break outer; }
  }
}
clearTimeout(timer);
const listed = (await (await fetch(`${base}/sessions`, { headers })).json()).some((s) => s.id === id);
await fetch(`${base}/sessions/${id}/close`, { method: 'POST', headers });
const wrote = fs.existsSync(path.join(dir, 'hello.txt'));
console.log({ asked, wrote, listed, cost: result?.cost, isError: result?.isError });
console.log(asked > 0 && wrote && listed && result && !result.isError ? 'E2E_OK' : 'E2E_FAIL');
