// Apple Push Notification service (APNs) client: token-based auth (ES256 JWT) over HTTP/2.
// Setup: put your .p8 key path, key id, team id and the app's bundle id in ~/.tether/apns.json.
import fs from 'node:fs';
import path from 'node:path';
import http2 from 'node:http2';
import crypto from 'node:crypto';

const HOSTS = { production: 'https://api.push.apple.com', sandbox: 'https://api.sandbox.push.apple.com' };

export function apnsJwt({ keyPem, keyId, teamId }, now = Date.now()) {
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const unsigned = `${b64({ alg: 'ES256', kid: keyId })}.${b64({ iss: teamId, iat: Math.floor(now / 1000) })}`;
  const sig = crypto.sign('sha256', Buffer.from(unsigned), { key: keyPem, dsaEncoding: 'ieee-p1363' });
  return `${unsigned}.${sig.toString('base64url')}`;
}

// kind: 'permission' gets Allow/Deny actions on the lock screen; everything else just opens the session.
export function buildPayload({ kind, title, body, sessionId, requestId }) {
  return {
    aps: {
      alert: { title, body },
      sound: 'default',
      'thread-id': sessionId,
      ...(kind === 'permission' && { category: 'PERMISSION', 'interruption-level': 'time-sensitive' }),
    },
    sessionId,
    ...(requestId && { requestId }),
  };
}

// Which phones want this notification. "done" is opt-out per phone; everything else ("needs you") too.
export function wantsNotification(device, kind) {
  const prefs = { needsYou: true, done: true, ...device.prefs };
  return kind === 'done' ? prefs.done : prefs.needsYou;
}

// Live Activity update (lock screen / Dynamic Island). `state` must match the app's ContentState.
export function buildActivityPayload(state, { end = false, alert, now = Date.now() } = {}) {
  return {
    aps: {
      timestamp: Math.floor(now / 1000),
      event: end ? 'end' : 'update',
      'content-state': state,
      ...(end && { 'dismissal-date': Math.floor(now / 1000) + 15 * 60 }),
      ...(alert && { alert: { title: alert.title, body: alert.body }, sound: 'default' }),
    },
  };
}

export function createPusher(dir) {
  const configFile = path.join(dir, 'apns.json');
  const devicesFile = path.join(dir, 'devices.json');
  let config = null;
  try {
    const c = JSON.parse(fs.readFileSync(configFile, 'utf8'));
    config = { ...c, keyPem: fs.readFileSync(c.keyFile.replace(/^~/, process.env.HOME), 'utf8') };
  } catch (err) {
    if (err.code !== 'ENOENT') console.error(`Push disabled: ${configFile}: ${err.message}`);
  }
  let devices = [];
  try { devices = JSON.parse(fs.readFileSync(devicesFile, 'utf8')); } catch {}
  const save = () => fs.writeFileSync(devicesFile, JSON.stringify(devices, null, 1), { mode: 0o600 });
  let jwt = null, jwtAt = 0;

  function token() {
    // Apple rejects tokens older than an hour and throttles refreshing more than every 20 minutes.
    if (!jwt || Date.now() - jwtAt > 40 * 60_000) { jwt = apnsJwt(config); jwtAt = Date.now(); }
    return jwt;
  }

  function send(target, payload, { type = 'alert', priority = 10 } = {}) {
    return new Promise((resolve) => {
      const client = http2.connect(HOSTS[target.sandbox ? 'sandbox' : 'production']);
      client.on('error', (err) => { console.error('Push failed:', err.message); resolve(); });
      const req = client.request({
        ':method': 'POST',
        ':path': `/3/device/${target.token}`,
        authorization: `bearer ${token()}`,
        'apns-topic': type === 'liveactivity' ? `${config.bundleId}.push-type.liveactivity` : config.bundleId,
        'apns-push-type': type,
        'apns-priority': String(priority),
      });
      let status = 0, body = '';
      req.on('response', (h) => { status = h[':status']; });
      req.on('data', (c) => { body += c; });
      req.on('end', () => {
        client.close();
        if (type === 'alert' && (status === 410 || /BadDeviceToken|Unregistered/.test(body))) {
          devices = devices.filter((d) => d.token !== target.token);
          save();
        } else if (status !== 200) console.error(`Push ${status}: ${body}`);
        resolve();
      });
      req.end(JSON.stringify(payload));
    });
  }

  return {
    get enabled() { return !!config; },
    register(tokenHex, sandbox, prefs) {
      if (!/^[0-9a-f]{64,200}$/i.test(tokenHex)) return false;
      const clean = prefs && { needsYou: prefs.needsYou !== false, done: prefs.done !== false };
      devices = [...devices.filter((d) => d.token !== tokenHex), { token: tokenHex, sandbox: !!sandbox, ...(clean && { prefs: clean }) }];
      save();
      return true;
    },
    notify(p) {
      if (!config) return Promise.resolve();
      return Promise.all(devices.filter((d) => wantsNotification(d, p.kind)).map((d) => send(d, buildPayload(p))));
    },
    // Low priority for routine progress (Apple budgets these); high when the phone must act.
    activity(target, state, opts = {}) {
      if (!config) return Promise.resolve();
      return send(target, buildActivityPayload(state, opts), { type: 'liveactivity', priority: opts.alert || opts.end ? 10 : 5 });
    },
  };
}
