// The app's own backend (Web/backend.js) answering /api/queue and /api/browse, with YouTube Music
// replaced by made-up answers (Tests/web/fixtures.js).
//   node --test "Tests/web/*.test.js"
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const F = require('./fixtures');

const WEB = path.join(__dirname, '..', '..', 'Web');

// The backend in a sandbox like the app's page; every request to YouTube Music goes to youtube(endpoint, body, url).
function backend(youtube) {
  const sent = [];
  const sandbox = {
    console: { log() {}, warn() {}, error() {}, info() {} },
    setTimeout, clearTimeout, setInterval, clearInterval, URL, URLSearchParams, TextEncoder, TextDecoder, Response, Headers,
    __ytmStandalone: true,
    location: { protocol: 'ytm-app:', host: 'local', href: 'ytm-app://local/index.html' },
    navigator: {},
    document: { hidden: false, addEventListener() {} },
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
    __ytmLoadData: () => Promise.reject(new Error('no data in this test')),
    webkit: { messageHandlers: { ytmHttp: { postMessage: (o) => {
      const m = /^https:\/\/music\.youtube\.com\/youtubei\/v1\/(\w+)/.exec(o.url);
      if (!m) return Promise.reject(new Error('unexpected request ' + o.url));
      const body = o.body ? JSON.parse(Buffer.from(o.body, 'base64').toString('utf8')) : null;
      sent.push({ endpoint: m[1], body, url: o.url });
      const json = youtube(m[1], body, o.url);
      if (!json) return Promise.resolve({ status: 404, headers: {}, body: '' });
      return Promise.resolve({ status: 200, headers: { 'content-type': 'application/json' }, body: Buffer.from(JSON.stringify(json)).toString('base64') });
    } } } },
  };
  sandbox.window = sandbox;
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(path.join(WEB, 'backend.js'), 'utf8'), sandbox, { filename: 'backend.js' });
  const B = sandbox.__ytmBackend;
  assert.ok(B && typeof B.dispatch === 'function', 'backend started');
  const get = async (url) => {
    const r = await B.dispatch({ method: 'GET', url, headers: {}, body: null });
    return { status: r.status, json: JSON.parse(Buffer.from(r.body).toString('utf8')) };
  };
  return { get, sent };
}
const ids = (items) => items.map((x) => x.videoId.replace(/_+$/, ''));

test('/api/queue: a radio and its continuation token', async () => {
  const b = backend((ep, body) => (ep === 'next' && body.videoId === F.vid('a') ? F.nextFirst(['a', 'b', 'c'], 'RADIO-CONT-TWO') : null));
  const r = await b.get('/api/queue?videoId=' + F.vid('a'));
  assert.equal(r.status, 200);
  assert.deepEqual(ids(r.json.items), ['a', 'b', 'c']);
  assert.equal(r.json.continuation, 'RADIO-CONT-TWO');
  assert.equal(b.sent[0].body.playlistId, 'RDAMVM' + F.vid('a'));
  assert.equal(b.sent[0].body.params, undefined);
});

test('/api/queue: a song offered with its music video is queued once, in its first answer and in a continuation', async () => {
  const b = backend((ep, body) => {
    if (ep === 'next' && body.continuation === 'RADIO-CONT-TWO') return F.nextMore([F.wrappedSong('d'), 'e'], '');
    if (ep === 'next' && body.videoId === F.vid('a')) return F.nextFirst(['a', F.wrappedSong('b'), 'c'], 'RADIO-CONT-TWO');
    return null;
  });
  const r = await b.get('/api/queue?videoId=' + F.vid('a'));
  assert.deepEqual(ids(r.json.items), ['a', 'b', 'c']);
  const more = await b.get('/api/queue?c=RADIO-CONT-TWO');
  assert.deepEqual(ids(more.json.items), ['d', 'e']);
});

test('/api/queue?c=: the rest of the same radio, by its token (no new radio)', async () => {
  const b = backend((ep, body) => (ep === 'next' && body.continuation === 'RADIO-CONT-TWO' ? F.nextMore(['d', 'e'], 'RADIO-CONT-THREE') : null));
  const r = await b.get('/api/queue?c=RADIO-CONT-TWO');
  assert.equal(r.status, 200);
  assert.deepEqual(ids(r.json.items), ['d', 'e']);
  assert.equal(r.json.continuation, 'RADIO-CONT-THREE');
  assert.equal(b.sent.length, 1);
  assert.equal(b.sent[0].body.videoId, undefined);
  assert.equal(b.sent[0].body.playlistId, undefined);
});

test('/api/queue: params are passed on to YouTube Music; bad ones are refused', async () => {
  const b = backend(() => F.nextFirst(['a', 'b', 'c'], ''));
  const r = await b.get('/api/queue?videoId=' + F.vid('a') + '&params=wAEB8gECGAE%3D');
  assert.equal(r.status, 200);
  assert.equal(b.sent[0].body.params, 'wAEB8gECGAE=');
  const bad = await b.get('/api/queue?videoId=' + F.vid('a') + '&params=' + encodeURIComponent('a b<c>'));
  assert.equal(bad.status, 400);
});

test('/api/browse: the list\'s own continuation, not the page\'s', async () => {
  const b = backend((ep, body) => (ep === 'browse' && body.browseId === 'VLPLtest' ? F.browseFirst(['l1', 'l2', 'l3'], 'LIST-CONT-TWO', 'PAGE-CONT-XYZ') : null));
  const r = await b.get('/api/browse?id=VLPLtest');
  assert.equal(r.status, 200);
  assert.equal(r.json.title, 'My list');
  assert.deepEqual(ids(r.json.sections[0].items), ['l1', 'l2', 'l3']);
  assert.equal(r.json.next, 'LIST-CONT-TWO');
});

test('/api/browse?c=: further pages in both forms; merged by the page without duplicates', async () => {
  const b = backend((ep, body) => {
    if (ep !== 'browse') return null;
    if (body.browseId === 'VLLM') return F.browseFirst(['l1', 'l2'], 'LIST-CONT-TWO');
    if (body.continuation === 'LIST-CONT-TWO') return F.browseMore(['l2', 'l3', 'l4'], 'LIST-CONT-THREE');
    if (body.continuation === 'LIST-CONT-THREE') return F.browseMoreOld(['l4', 'l5'], '');
    return null;
  });
  const first = await b.get('/api/browse?id=VLLM');
  const two = await b.get('/api/browse?id=VLLM&c=LIST-CONT-TWO');
  assert.equal(two.status, 200);
  assert.deepEqual(ids(two.json.sections[0].items), ['l2', 'l3', 'l4']);
  assert.equal(two.json.next, 'LIST-CONT-THREE');
  // the token goes both ways YouTube Music has taken it (body and query string)
  const asked = b.sent.find((s) => s.body && s.body.continuation === 'LIST-CONT-TWO');
  assert.match(asked.url, /ctoken=LIST-CONT-TWO/);
  const three = await b.get('/api/browse?id=VLLM&c=LIST-CONT-THREE');
  assert.deepEqual(ids(three.json.sections[0].items), ['l4', 'l5']);
  assert.equal(three.json.next, '');

  // the page's merge (Web/index.html, listMerge) over these answers
  const html = fs.readFileSync(path.join(WEB, 'index.html'), 'utf8');
  const fn = html.slice(html.indexOf('\nfunction listMerge('), html.indexOf('\n}\n', html.indexOf('\nfunction listMerge(')) + 3);
  const ctx = vm.createContext({ isSong: (it) => !!it && it.kind === 'song' && !!it.videoId });
  vm.runInContext(fn + ';this.listMerge = listMerge;', ctx);
  const have = {};
  const all = [];
  for (const page of [first.json, two.json, three.json]) all.push(...ctx.listMerge(have, page.sections));
  assert.deepEqual(ids(all), ['l1', 'l2', 'l3', 'l4', 'l5']);
});

test('/api/browse?c=: a bad token is refused', async () => {
  const b = backend(() => null);
  const r = await b.get('/api/browse?id=VLLM&c=' + encodeURIComponent('<x>'));
  assert.equal(r.status, 400);
  assert.equal(b.sent.length, 0);
});
