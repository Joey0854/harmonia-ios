// Where the page's /api/queue goes (Web/standalone.js): signed in, to the app's own backend (the
// account's radio); when that fails, to the PC as before. Made-up answers only.
//   node --test "Tests/web/*.test.js"
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const F = require('./fixtures');

const WEB = path.join(__dirname, '..', '..', 'Web');
const PC = 'http://pc.invalid:8787';
const json = (o, status) => ({ status: status || 200, headers: { 'content-type': 'application/json' }, body: Buffer.from(JSON.stringify(o)).toString('base64') });

function app(opts) {
  const youtube = [], pc = [];
  const store = { ytm_pc: PC };
  const sandbox = {
    console: { log() {}, warn() {}, error() {}, info() {} },
    setTimeout, clearTimeout, setInterval, clearInterval, URL, URLSearchParams, TextEncoder, TextDecoder, Response, Headers, Request, Blob, DOMException,
    __ytmStandalone: true,
    __ytmAccount: !!opts.account,
    location: { protocol: 'ytm-app:', host: 'local', href: 'ytm-app://local/index.html' },
    navigator: {},
    document: { hidden: false, addEventListener() {} },
    addEventListener() {},
    localStorage: { getItem: (k) => (k in store ? store[k] : null), setItem: (k, v) => { store[k] = String(v); }, removeItem: (k) => { delete store[k]; } },
    __ytmLoadData: () => Promise.reject(new Error('no data in this test')),
    webkit: { messageHandlers: {
      ytm: { postMessage() {} },
      ytmHttp: { postMessage: (o) => {
        if (o.url.startsWith(PC + '/')) {
          pc.push(o.url.slice(PC.length));
          if (o.url.includes('/api/queue')) return Promise.resolve(json({ items: [], from: 'pc' }));
          return Promise.resolve(json({ ok: true }));
        }
        if (o.url.startsWith('https://music.youtube.com/youtubei/v1/next')) {
          youtube.push(JSON.parse(Buffer.from(o.body, 'base64').toString('utf8')));
          return Promise.resolve(opts.youtubeDown ? json({ error: 'down' }, 500) : json(F.nextMore(['d', 'e'], 'RADIO-CONT-THREE')));
        }
        return Promise.reject(new Error('unexpected ' + o.url));
      } },
    } },
  };
  sandbox.fetch = () => Promise.reject(new Error('real fetch'));
  sandbox.window = sandbox;
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  for (const f of ['backend.js', 'standalone.js']) vm.runInContext(fs.readFileSync(path.join(WEB, f), 'utf8'), sandbox, { filename: f });
  const get = async (url) => {
    const r = await sandbox.fetch(url);
    return { status: r.status, json: JSON.parse(await r.text()) };
  };
  return { get, youtube, pc };
}

test('signed in: the radio\'s continuation comes from the app (with the account), not the PC', async () => {
  const a = app({ account: true });
  const r = await a.get('/api/queue?c=RADIO-CONT-TWO');
  assert.equal(r.status, 200);
  assert.equal(r.json.continuation, 'RADIO-CONT-THREE');
  assert.equal(a.youtube.length, 1);
  assert.equal(a.youtube[0].continuation, 'RADIO-CONT-TWO');
  assert.deepEqual(a.pc, []);
});

test('signed in, YouTube Music not answering the app: the PC is asked instead', async () => {
  const a = app({ account: true, youtubeDown: true });
  const r = await a.get('/api/queue?videoId=' + F.vid('a'));
  assert.equal(r.status, 200);
  assert.equal(r.json.from, 'pc');
  assert.ok(a.pc.some((p) => p.startsWith('/api/queue?videoId=')), 'asked the PC: ' + a.pc.join(', '));
});

test('not signed in: the queue is the PC\'s, as before', async () => {
  const a = app({ account: false });
  const r = await a.get('/api/queue?videoId=' + F.vid('a'));
  assert.equal(r.json.from, 'pc');
  assert.equal(a.youtube.length, 0);
});
