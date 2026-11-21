// A stand-in for the console's POST /api/v1/app-reports, for the libraries' tests: it records every request, checks it
// against the wire contract, and answers what a test asks for (204, 429 with Retry-After, 500, 422, ...). It only ever
// listens on 127.0.0.1; no test talks to a real Cyber Rakshak host.
//
//   node tests/sdk/fake-server.mjs        prints {"url":"http://127.0.0.1:PORT"} and serves until stdin closes
//
// Control (for tests in any language):
//   POST /__control/reset                         forget requests and planned answers
//   POST /__control/plan  {"responses":[{"status":429,"retryAfter":"1"},{"status":204,"delayMs":0}]}
//                                                 the next report requests get these answers, in order (then 204)
//   GET  /__control/requests                      every report request so far
//   GET  /__control/wait?count=N&timeout=MS       the same, once N have arrived (or the time is up)
import { createServer } from 'node:http';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

export const REPORT_PATH = '/api/v1/app-reports';
const SDK_NAMES = ['cyberrakshak-node', 'cyberrakshak-react-native', 'cyberrakshak-php', 'cyberrakshak-python', 'cyberrakshak-shell', 'cyberrakshak-android', 'cyberrakshak-ios'];
const PLATFORMS = ['mobile', 'server', 'script', 'desktop', 'other'];
const KINDS = ['exception', 'crash', 'promise', 'log', 'http', 'script'];
const TOP_KEYS = ['sdk', 'platform', 'runtime', 'release', 'environment', 'errors'];
const ERROR_KEYS = ['kind', 'message', 'stack', 'route', 'level', 'count', 'at', 'context'];
const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|[+-]\d{2}:?\d{2})$/;

const length = (s) => [...s].length; // characters, as the console counts them

/** What is wrong with a request, by the contract; an empty list when nothing is. */
export function checkContract(method, path, headers, raw) {
  const v = [];
  if (method !== 'POST') v.push('method is ' + method);
  if (path !== REPORT_PATH) v.push('path is ' + path);
  if (!/^Bearer crk_[A-Za-z0-9]{32}$/.test(headers.authorization || '')) v.push('Authorization is not "Bearer crk_<32>"');
  if (!/^application\/json\b/i.test(headers['content-type'] || '')) v.push('Content-Type is ' + headers['content-type']);
  if (raw.length > 65536) v.push('body is ' + raw.length + ' bytes (over 64 KB)');
  const text = raw.toString('utf8');
  try {
    new TextDecoder('utf-8', { fatal: true }).decode(raw);
  } catch {
    v.push('body is not valid UTF-8');
  }
  if (/crk_[A-Za-z0-9]{32}/.test(text)) v.push('the key is inside the body');
  // A lone UTF-16 surrogate escape is not text: the console's JSON reader refuses the whole body.
  if (/\\u[dD][89abAB][0-9a-fA-F]{2}(?!\\u[dD][c-fC-F][0-9a-fA-F]{2})|(?<!\\u[dD][89abAB][0-9a-fA-F]{2})\\u[dD][c-fC-F][0-9a-fA-F]{2}/.test(text)) v.push('body holds a lone surrogate');
  let body;
  try {
    body = JSON.parse(text);
  } catch (e) {
    v.push('body is not JSON: ' + e.message);
    return { violations: v, body: null };
  }
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    v.push('body is not an object');
    return { violations: v, body };
  }
  for (const k of Object.keys(body)) if (!TOP_KEYS.includes(k)) v.push('unknown top-level key ' + k);
  const sdk = body.sdk;
  if (!sdk || typeof sdk !== 'object') v.push('sdk missing');
  else {
    if (typeof sdk.name !== 'string' || length(sdk.name) > 40 || !SDK_NAMES.includes(sdk.name)) v.push('sdk.name is ' + JSON.stringify(sdk.name));
    if (sdk.version !== '1.1.0') v.push('sdk.version is ' + JSON.stringify(sdk.version));
  }
  if (!PLATFORMS.includes(body.platform)) v.push('platform is ' + JSON.stringify(body.platform));
  if (body.runtime !== undefined && (typeof body.runtime !== 'string' || length(body.runtime) > 60)) v.push('runtime is ' + JSON.stringify(body.runtime));
  if (body.release !== undefined && !(typeof body.release === 'string' && /^[A-Za-z0-9._+\-]{1,60}$/.test(body.release))) v.push('release is ' + JSON.stringify(body.release));
  if (body.environment !== undefined && !(typeof body.environment === 'string' && /^[a-z0-9_-]{1,30}$/.test(body.environment))) v.push('environment is ' + JSON.stringify(body.environment));
  if (!Array.isArray(body.errors) || body.errors.length < 1 || body.errors.length > 10) {
    v.push('errors is not a list of 1 to 10');
    return { violations: v, body };
  }
  body.errors.forEach((e, i) => {
    const at = 'errors[' + i + '] ';
    if (!e || typeof e !== 'object' || Array.isArray(e)) {
      v.push(at + 'is not an object');
      return;
    }
    for (const k of Object.keys(e)) if (!ERROR_KEYS.includes(k)) v.push(at + 'unknown key ' + k);
    if (!KINDS.includes(e.kind)) v.push(at + 'kind is ' + JSON.stringify(e.kind));
    if (typeof e.message !== 'string' || !e.message.trim() || length(e.message) > 4000) v.push(at + 'message is empty, not a string or over 4000');
    if (e.stack !== undefined && e.stack !== null && (typeof e.stack !== 'string' || length(e.stack) > 16000)) v.push(at + 'stack over 16000 or not a string');
    if (e.route !== undefined && e.route !== null && (typeof e.route !== 'string' || length(e.route) > 200)) v.push(at + 'route over 200 or not a string');
    if (typeof e.route === 'string' && /[?]/.test(e.route)) v.push(at + 'route holds a query string');
    if (e.level !== undefined && e.level !== null && !['error', 'warning'].includes(e.level)) v.push(at + 'level is ' + JSON.stringify(e.level));
    if (e.count !== undefined && e.count !== null && !(Number.isInteger(e.count) && e.count >= 1 && e.count <= 100000)) v.push(at + 'count is ' + JSON.stringify(e.count));
    if (e.at !== undefined && e.at !== null && !(typeof e.at === 'string' && e.at.length <= 40 && ISO.test(e.at) && !Number.isNaN(Date.parse(e.at)))) v.push(at + 'at is ' + JSON.stringify(e.at));
    if (e.context !== undefined && e.context !== null) {
      if (typeof e.context !== 'object' || Array.isArray(e.context)) v.push(at + 'context is not an object');
      else {
        const keys = Object.keys(e.context);
        if (keys.length > 20) v.push(at + 'context has ' + keys.length + ' values');
        for (const k of keys) {
          const x = e.context[k];
          if (!(x === null || ['string', 'number', 'boolean'].includes(typeof x))) v.push(at + 'context.' + k + ' is not a scalar');
        }
      }
    }
  });
  return { violations: v, body };
}

export function startFakeServer() {
  const requests = [];
  let plan = [];
  let waiters = [];

  const wake = () => {
    waiters = waiters.filter((w) => {
      if (requests.length >= w.count) {
        clearTimeout(w.timer);
        w.resolve();
        return false;
      }
      return true;
    });
  };

  const server = createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', async () => {
      const raw = Buffer.concat(chunks);
      const url = new URL(req.url, 'http://127.0.0.1');
      const json = (status, value) => {
        res.writeHead(status, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(value));
      };
      if (url.pathname === '/__control/reset') {
        requests.length = 0;
        plan = [];
        return json(200, { ok: true });
      }
      if (url.pathname === '/__control/plan') {
        try {
          plan.push(...(JSON.parse(raw.toString('utf8')).responses || []));
        } catch {
          return json(400, { ok: false });
        }
        return json(200, { ok: true, planned: plan.length });
      }
      if (url.pathname === '/__control/requests') return json(200, requests);
      if (url.pathname === '/__control/wait') {
        const count = Number(url.searchParams.get('count') || 1);
        const timeout = Number(url.searchParams.get('timeout') || 5000);
        await new Promise((resolve) => {
          if (requests.length >= count) return resolve();
          const w = { count, resolve };
          w.timer = setTimeout(() => {
            waiters = waiters.filter((x) => x !== w);
            resolve();
          }, timeout);
          waiters.push(w);
        });
        return json(200, requests);
      }

      const { violations, body } = checkContract(req.method, url.pathname, req.headers, raw);
      const answer = plan.length ? plan.shift() : { status: violations.length ? 422 : 204 };
      requests.push({
        n: requests.length + 1,
        at: Date.now(),
        method: req.method,
        path: url.pathname,
        authorization: req.headers.authorization || null,
        contentType: req.headers['content-type'] || null,
        userAgent: req.headers['user-agent'] || null,
        bytes: raw.length,
        body,
        status: answer.status,
        violations,
      });
      wake();
      if (answer.delayMs) await new Promise((r) => setTimeout(r, answer.delayMs));
      const headers = {};
      if (answer.retryAfter !== undefined) headers['Retry-After'] = String(answer.retryAfter);
      res.writeHead(answer.status, headers);
      res.end(answer.status === 204 ? undefined : answer.status >= 400 ? JSON.stringify({ message: 'fake answer ' + answer.status }) : '');
    });
  });

  return new Promise((resolveStart) => {
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      resolveStart({
        url: 'http://127.0.0.1:' + port,
        endpoint: 'http://127.0.0.1:' + port + REPORT_PATH,
        requests,
        reset() {
          requests.length = 0;
          plan = [];
        },
        plan(...responses) {
          plan.push(...responses);
        },
        wait(count, timeout = 5000) {
          return new Promise((resolve) => {
            if (requests.length >= count) return resolve(requests);
            const w = { count, resolve: () => resolve(requests) };
            w.timer = setTimeout(() => {
              waiters = waiters.filter((x) => x !== w);
              resolve(requests);
            }, timeout);
            waiters.push(w);
          });
        },
        close() {
          return new Promise((r) => {
            server.closeAllConnections?.();
            server.close(() => r());
          });
        },
      });
    });
  });
}

if (process.argv[1] && resolve(process.argv[1]).toLowerCase() === fileURLToPath(import.meta.url).toLowerCase()) {
  const fake = await startFakeServer();
  process.stdout.write(JSON.stringify({ url: fake.url }) + '\n');
  process.stdin.resume();
  process.stdin.on('end', () => fake.close().then(() => process.exit(0)));
  process.stdin.on('close', () => fake.close().then(() => process.exit(0)));
}
