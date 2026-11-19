// The page's autoplay and paged lists (Web/index.html), run in Node with stand-ins for the page.
//   node --test "Tests/web/*.test.js"
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { item, vid, chip } = require('./fixtures');

const html = fs.readFileSync(path.join(__dirname, '..', '..', 'Web', 'index.html'), 'utf8');

// the source between two markers (exactly once each)
function between(a, b) {
  const i = html.indexOf(a), j = html.indexOf(b);
  assert.ok(i >= 0 && j > i && html.indexOf(a, i + 1) < 0, 'markers ' + a + ' / ' + b);
  return html.slice(i, j + b.length);
}
// a top-level function of the page, up to its closing brace at the start of a line
function fnSrc(name) {
  const head = '\nfunction ' + name + '(';
  const i = html.indexOf(head);
  assert.ok(i >= 0 && html.indexOf(head, i + 1) < 0, 'function ' + name);
  const j = html.indexOf('\n}\n', i);
  return html.slice(i, j + 3);
}

const RADIO = html.slice(html.indexOf('var extending = false;'), html.indexOf('/* RADIO-END */') + 15);
const EXTEND = fnSrc('extendQueue');
// parts of the page that an older page does not have yet
const maybe = (name) => (html.includes('\nfunction ' + name + '(') ? fnSrc(name) : '');

// a fresh page: the radio part, extendQueue, saveState / restoreState, with stand-ins
function page(answers, opts) {
  opts = opts || {};
  const asked = [];
  const store = {};
  const toasts = [];
  const ctx = {
    console, Promise, JSON, Math, Date, Array, Object, encodeURIComponent,
    S: { queue: [], index: -1, shuffle: false, repeat: 'off' },
    HIST: { list: () => (opts.history || []).map((n) => ({ videoId: vid(n) })) },
    isSong: (it) => !!it && (it.kind === 'song' || it.kind === 'video') && !!it.videoId,
    enc: encodeURIComponent,
    api: (p) => {
      asked.push(p);
      const a = answers(p, asked.length);
      return a instanceof Error ? Promise.reject(a) : Promise.resolve(a);
    },
    toasts, toast(m) { toasts.push(m); }, listFollow() {}, playTrack() {},
    renderQueue() {}, prefetch() {}, shuffleUpcoming() {}, renderPlayer() {}, updateProgress() {},
    curTime: () => 12, parseDur: () => 210,
    lsSet: (k, v) => { store[k] = v; }, lsGet: (k) => (k in store ? store[k] : null),
  };
  vm.createContext(ctx);
  vm.runInContext(RADIO + EXTEND + maybe('pickChip') + fnSrc('playFromList') + fnSrc('playAll') + 'var lastSave = 0;' + fnSrc('saveState') + fnSrc('restoreState') +
    '\nthis.extendQueue = extendQueue; this.saveState = saveState; this.restoreState = restoreState;' +
    'this.radioMore = radioMore; this.radioPick = radioPick; this.makeListSource = makeListSource; this.listTake = listTake;' +
    'this.pickChip = typeof pickChip === "function" ? pickChip : undefined; this.playFromList = playFromList; this.playAll = playAll;' +
    'this.isChipBusy = function () { return typeof chipBusy !== "undefined" && chipBusy; };' +
    'this.listMerge = listMerge; this.radioSeenAdd = radioSeenAdd; this.isExtending = function () { return extending; };', ctx);
  return { ctx, asked, store };
}
// waits until extendQueue has finished (it runs on promises)
async function settle(p) {
  for (let i = 0; i < 200 && p.ctx.isExtending(); i++) await new Promise((r) => setTimeout(r, 1));
  await new Promise((r) => setTimeout(r, 1));
}
const ids = (list) => Array.from(list, (x) => x.videoId.replace(/_+$/, ''));
const answer = (names, cont) => ({ items: names.map((n) => item(n)), continuation: cont || '' });

test('extendQueue goes on with the radio\'s continuation instead of starting a new radio', async () => {
  const p = page((q) => (q === '/api/queue?c=TOKEN-ONE-xx' ? answer(['c', 'd', 'e'], 'TOKEN-TWO-xx') : new Error('unexpected ' + q)));
  const S = p.ctx.S;
  S.queue = [item('a'), item('b')];
  S.index = 0;
  S.radioQ = S.queue;
  S.radioCont = 'TOKEN-ONE-xx';
  p.ctx.extendQueue();
  await settle(p);
  assert.deepEqual(p.asked, ['/api/queue?c=TOKEN-ONE-xx']);
  assert.ok(!p.asked.some((q) => q.includes('videoId=')), 'no new radio');
  assert.deepEqual(ids(S.queue), ['a', 'b', 'c', 'd', 'e']);
  assert.equal(S.radioCont, 'TOKEN-TWO-xx');
  assert.equal(S.radioQ, S.queue);
  // and the next time with the new token
  S.index = 3;
  p.ctx.extendQueue();
  await settle(p);
  assert.equal(p.asked[1], '/api/queue?c=TOKEN-TWO-xx');
});

test('without a radio, one is started from the last song and its continuation is kept', async () => {
  const p = page((q) => (q === '/api/queue?videoId=' + vid('b') ? answer(['b', 'c', 'd', 'e'], 'TOKEN-NEW-xx') : new Error('unexpected ' + q)));
  const S = p.ctx.S;
  S.queue = [item('a'), item('b')];
  S.index = 0;
  p.ctx.extendQueue();
  await settle(p);
  assert.deepEqual(p.asked, ['/api/queue?videoId=' + vid('b')]);
  assert.deepEqual(ids(S.queue), ['a', 'b', 'c', 'd', 'e']);
  assert.equal(S.radioCont, 'TOKEN-NEW-xx');
  assert.equal(S.radioQ, S.queue);
  assert.deepEqual(Array.from(S.radioSeen, (x) => x.replace(/_+$/, '')), ['b', 'c', 'd', 'e']);
});

test('songs heard lately and songs this radio offered before are not queued again', async () => {
  const p = page(() => answer(['h1', 's1', 'n1', 'n2', 'n3', 'a'], 'TOKEN-NEXT-x'), { history: ['h1', 'h2'] });
  const S = p.ctx.S;
  S.queue = [item('a'), item('b')];
  S.index = 0;
  S.radioQ = S.queue;
  S.radioCont = 'TOKEN-ONE-xx';
  S.radioSeen = [vid('s1')];
  p.ctx.extendQueue();
  await settle(p);
  assert.deepEqual(ids(S.queue), ['a', 'b', 'n1', 'n2', 'n3']);
  assert.equal(p.asked.length, 1);
  assert.ok(S.radioSeen.includes(vid('h1')) && S.radioSeen.includes(vid('n3')), 'offered songs remembered');
});

test('another version of a queued song is not queued (title containment, same artist)', () => {
  const p = page(() => ({}));
  const queue = [item('a', { title: 'Watch me!', subtitle: 'YOASOBI' })];
  const kept = p.ctx.radioPick(queue, [item('x', { title: 'YOASOBI「Watch me!」Official Music Video', subtitle: 'YOASOBI' }), item('y')], {}, []);
  assert.deepEqual(ids(kept), ['y']);
});

test('too few new songs after the filter: the next part of the radio is asked for', async () => {
  const p = page((q) => {
    if (q === '/api/queue?c=TOKEN-ONE-xx') return answer(['h1', 's1', 'n1'], 'TOKEN-TWO-xx');
    if (q === '/api/queue?c=TOKEN-TWO-xx') return answer(['h2', 'n2'], 'TOKEN-THREE');
    if (q === '/api/queue?c=TOKEN-THREE') return answer(['n3', 'n4'], 'TOKEN-FOUR-');
    return new Error('unexpected ' + q);
  }, { history: ['h1', 'h2'] });
  const S = p.ctx.S;
  S.queue = [item('a')];
  S.index = 0;
  S.radioQ = S.queue;
  S.radioCont = 'TOKEN-ONE-xx';
  S.radioSeen = [vid('s1')];
  p.ctx.extendQueue();
  await settle(p);
  assert.deepEqual(p.asked, ['/api/queue?c=TOKEN-ONE-xx', '/api/queue?c=TOKEN-TWO-xx', '/api/queue?c=TOKEN-THREE']);
  assert.deepEqual(ids(S.queue), ['a', 'n1', 'n2', 'n3', 'n4']);
  assert.equal(S.radioCont, 'TOKEN-FOUR-');
});

test('at most four requests; then songs from the history may come back so the queue goes on', async () => {
  let n = 0;
  const p = page(() => answer(['h1', 'h2'], 'TOKEN-' + (++n) + '-xxxxx'), { history: ['h1', 'h2'] });
  const S = p.ctx.S;
  S.queue = [item('a')];
  S.index = 0;
  S.radioQ = S.queue;
  S.radioCont = 'TOKEN-0-xxxxx';
  p.ctx.extendQueue();
  await settle(p);
  assert.equal(p.asked.length, 4);
  assert.deepEqual(ids(S.queue), ['a', 'h1', 'h2']);
});

test('everything the radio gives was offered before: those songs come back rather than none', async () => {
  // a radio restored after a restart: its token has run out, and the new radio from the last song
  // gives only songs it offered before (the queue kept fewer songs than the seen list)
  const p = page((q) => (q.startsWith('/api/queue?c=') ? new Error('HTTP 400')
    : q.startsWith('/api/queue?videoId=') ? answer(['s1', 's2', 's3', 'a'], '') : new Error('unexpected ' + q)));
  const S = p.ctx.S;
  S.queue = [item('a')];
  S.index = 0;
  S.radioQ = S.queue;
  S.radioCont = 'TOKEN-OLD-xx';
  S.radioSeen = [vid('s1'), vid('s2'), vid('s3')];
  p.ctx.extendQueue();
  await settle(p);
  assert.deepEqual(ids(S.queue), ['a', 's1', 's2', 's3']);
});

test('a continuation that no longer works: a new radio from the last song', async () => {
  const p = page((q) => (q.startsWith('/api/queue?c=') ? new Error('HTTP 400') : answer(['b', 'c', 'd', 'e'], 'TOKEN-NEW-xx')));
  const S = p.ctx.S;
  S.queue = [item('a'), item('b')];
  S.index = 1;
  S.radioQ = S.queue;
  S.radioCont = 'TOKEN-OLD-xx';
  p.ctx.extendQueue();
  await settle(p);
  assert.deepEqual(p.asked, ['/api/queue?c=TOKEN-OLD-xx', '/api/queue?videoId=' + vid('b')]);
  assert.deepEqual(ids(S.queue), ['a', 'b', 'c', 'd', 'e']);
  assert.equal(S.radioCont, 'TOKEN-NEW-xx');
});

test('a radio filter (params) is passed on when a new radio is started', async () => {
  const p = page(() => answer(['c', 'd', 'e'], ''));
  const r = await p.ctx.radioMore({ queue: [item('a')], cont: '', seed: item('a'), params: 'CHIP-PARAMS', api: p.ctx.api });
  assert.equal(p.asked[0], '/api/queue?videoId=' + vid('a') + '&params=CHIP-PARAMS');
  assert.equal(r.fresh, true);
  assert.equal(r.items.length, 3);
});

test('the seen list keeps the newest 300 ids', () => {
  const p = page(() => ({}));
  const many = Array.from({ length: 320 }, (_, i) => item('m' + i));
  const seen = p.ctx.radioSeenAdd([], many);
  assert.equal(seen.length, 300);
  assert.equal(seen[299], vid('m319'));
  assert.ok(!seen.includes(vid('m0')));
});

test('saveState keeps the radio\'s continuation and seen songs; restoreState brings them back', async () => {
  const p = page((q) => (q === '/api/queue?c=TOKEN-SAVED-' ? answer(['x', 'y', 'z'], 'TOKEN-AFTER-') : new Error('unexpected ' + q)));
  const S = p.ctx.S;
  S.queue = [item('a'), item('b'), item('c')];
  S.index = 1;
  S.cur = S.queue[1];
  S.ready = true;
  S.radioQ = S.queue;
  S.radioCont = 'TOKEN-SAVED-';
  S.radioSeen = [vid('a'), vid('b'), vid('c'), vid('x')];
  S.radioParams = 'CHIP';
  p.ctx.saveState(true);
  const saved = JSON.parse(p.store.ytm_state);
  assert.deepEqual(saved.radio, { cont: 'TOKEN-SAVED-', seen: [vid('a'), vid('b'), vid('c'), vid('x')], params: 'CHIP' });

  // the page started again
  const p2 = page((q) => (q === '/api/queue?c=TOKEN-SAVED-&params=CHIP' || q === '/api/queue?c=TOKEN-SAVED-' ? answer(['x', 'y', 'z'], 'TOKEN-AFTER-') : new Error('unexpected ' + q)));
  p2.store.ytm_state = p.store.ytm_state;
  p2.ctx.restoreState();
  const S2 = p2.ctx.S;
  assert.equal(S2.radioQ, S2.queue);
  assert.equal(S2.radioCont, 'TOKEN-SAVED-');
  assert.deepEqual(Array.from(S2.radioSeen), [vid('a'), vid('b'), vid('c'), vid('x')]);
  assert.equal(S2.radioParams, 'CHIP');
  p2.ctx.extendQueue();
  await settle(p2);
  assert.ok(p2.asked[0].startsWith('/api/queue?c=TOKEN-SAVED-'), 'goes on with the saved radio: ' + p2.asked[0]);
  assert.deepEqual(ids(S2.queue), ['a', 'b', 'c', 'y', 'z'], 'x was offered before the restart');
});

test('a queue that does not own the radio saves no radio', () => {
  const p = page(() => ({}));
  const S = p.ctx.S;
  S.queue = [item('a')];
  S.index = 0;
  S.cur = S.queue[0];
  S.radioQ = [item('other')];
  S.radioCont = 'TOKEN-OTHER-';
  p.ctx.saveState(true);
  assert.equal(JSON.parse(p.store.ytm_state).radio, null);
});

test('a list in pages: merged without duplicates; the queue goes on with the next page, then the radio', async () => {
  const pages = {
    'LIST-TWO-xxx': { sections: [{ title: '', items: [item('l3'), item('l2'), item('l4')] }], next: 'LIST-THREE-x' },
    'LIST-THREE-x': { sections: [{ title: '', items: [item('l4'), item('l5')] }], next: '' },
  };
  const loads = [];
  const p = page((q) => (q === '/api/queue?videoId=' + vid('l5') ? answer(['r1', 'r2', 'r3'], 'RADIO-CONT-x') : new Error('unexpected ' + q)));
  const list = [item('l1'), item('l2'), item('l3')];
  const src = p.ctx.makeListSource(list, 'LIST-TWO-xxx', (t) => { loads.push(t); return Promise.resolve(pages[t]); });
  const S = p.ctx.S;
  S.queue = list.slice(1);
  S.index = 0;
  S.listSrc = src;
  S.listQ = S.queue;
  S.listPos = list.length;
  p.ctx.extendQueue();
  await settle(p);
  assert.deepEqual(loads, ['LIST-TWO-xxx']);
  assert.deepEqual(ids(list), ['l1', 'l2', 'l3', 'l4'], 'the page\'s list gets only the new song');
  assert.deepEqual(ids(S.queue), ['l2', 'l3', 'l4']);
  assert.equal(src.next, 'LIST-THREE-x');
  S.index = 1;
  p.ctx.extendQueue();
  await settle(p);
  assert.deepEqual(loads, ['LIST-TWO-xxx', 'LIST-THREE-x']);
  assert.deepEqual(ids(S.queue), ['l2', 'l3', 'l4', 'l5']);
  assert.equal(src.next, '');
  // the list is at its end: the radio from its last song
  S.index = 3;
  p.ctx.extendQueue();
  await settle(p);
  assert.deepEqual(p.asked, ['/api/queue?videoId=' + vid('l5')]);
  assert.deepEqual(ids(S.queue), ['l2', 'l3', 'l4', 'l5', 'r1', 'r2', 'r3']);
});

test('pages loaded by scrolling are queued too, without loading them again', async () => {
  const p = page(() => new Error('no radio expected'));
  const list = [item('l1'), item('l2')];
  let loads = 0;
  const src = p.ctx.makeListSource(list, 'LIST-TWO-xxx', () => { loads++; return Promise.resolve({ sections: [{ items: [item('l3'), item('l4'), item('l5'), item('l6')] }], next: 'LIST-THREE-x' }); });
  const S = p.ctx.S;
  S.queue = list.slice();
  S.index = 0;
  S.listSrc = src;
  S.listQ = S.queue;
  S.listPos = 2;
  await src.more(); // the browse page scrolled to the end
  p.ctx.extendQueue();
  await settle(p);
  assert.equal(loads, 1);
  assert.deepEqual(ids(S.queue), ['l1', 'l2', 'l3', 'l4', 'l5', 'l6']);
  assert.equal(S.listPos, 6);
});

test('a list source gives up after three failed pages; one page at a time', async () => {
  const p = page(() => ({}));
  let calls = 0;
  const src = p.ctx.makeListSource([item('a')], 'LIST-TWO-xxx', () => { calls++; return Promise.reject(new Error('HTTP 502')); });
  const a = src.more(), b = src.more();
  assert.equal(a, b, 'the same request while one is running');
  await a.catch(() => {});
  await src.more().catch(() => {});
  assert.equal(src.next, 'LIST-TWO-xxx');
  await src.more().catch(() => {});
  assert.equal(calls, 3);
  assert.equal(src.next, '');
  assert.deepEqual(Array.from(await src.more()), []);
});

test('the same token again ends the list instead of loading the same page for ever', async () => {
  const p = page(() => ({}));
  const list = [item('a')];
  const src = p.ctx.makeListSource(list, 'LIST-SAME-xx', () => Promise.resolve({ sections: [{ items: [item('b')] }], next: 'LIST-SAME-xx' }));
  await src.more();
  assert.equal(src.next, '');
  assert.deepEqual(ids(list), ['a', 'b']);
});

// ---- filter chips, the end of a chosen list, lists with repeated songs

const CHIPS = [chip('All', 'RDATfakeall', 'fakeAll%3D', true), chip('Familiar', 'RDATfakefam', 'fakeFam%3D')]
  .map((c) => {
    const r = c.chipCloudChipRenderer;
    const w = r.navigationEndpoint.queueUpdateCommand.fetchContentsCommand.watchEndpoint;
    return { title: r.text.runs[0].text, selected: r.isSelected, playlistId: w.playlistId, params: w.params };
  });
const CHIP_PATH = (n) => '/api/queue?videoId=' + vid(n) + '&playlistId=RDATfakefam&params=fakeFam%253D';

async function chipSettle(p) {
  for (let i = 0; i < 200 && p.ctx.isChipBusy(); i++) await new Promise((r) => setTimeout(r, 1));
  await new Promise((r) => setTimeout(r, 1));
}

test('radioMore hands on the chips of the radio\'s first answer', async () => {
  const p = page(() => Object.assign(answer(['b', 'c', 'd'], ''), { chips: CHIPS }));
  const r = await p.ctx.radioMore({ queue: [item('a')], cont: '', seed: item('a'), api: p.ctx.api });
  assert.equal(r.chips.length, 2);
  assert.equal(r.chips[1].params, 'fakeFam%3D');
});

test('picking a chip replaces only the songs after the playing one; the radio goes on with that answer\'s token', async () => {
  const p = page((q) => (q === CHIP_PATH('b') ? answer(['b', 'x1', 'x2', 'x3', 'a', 'd'], 'CHIP-TOKEN-xx') : new Error('unexpected ' + q)));
  const S = p.ctx.S;
  S.queue = [item('a'), item('b'), item('c'), item('d')];
  S.index = 1;
  S.radioQ = S.queue;
  S.radioCont = 'OLD-TOKEN-xxx';
  S.chips = CHIPS;
  const q = S.queue;
  p.ctx.pickChip(1);
  await chipSettle(p);
  assert.deepEqual(p.asked, [CHIP_PATH('b')]);
  assert.equal(S.queue, q, 'the same queue, changed in place');
  // a (before) and b (playing) stay; the old c is gone, d comes back from the answer; b and a are not queued twice
  assert.deepEqual(ids(S.queue), ['a', 'b', 'x1', 'x2', 'x3', 'd']);
  assert.equal(S.radioCont, 'CHIP-TOKEN-xx');
  assert.equal(S.radioParams, 'fakeFam%3D');
  assert.equal(S.radioPid, 'RDATfakefam');
  assert.deepEqual(Array.from(S.chips, (c) => c.title + c.selected), ['Allfalse', 'Familiartrue']);
  // the next extension goes on with the chip answer's token
  S.index = 4;
  p.ctx.extendQueue();
  await settle(p);
  assert.ok(p.asked[1].startsWith('/api/queue?c=CHIP-TOKEN-xx'), p.asked[1]);
});

test('picking a chip: a failure keeps the queue and says so; an answer of only known songs still gives songs', async () => {
  const p = page(() => new Error('offline'));
  const S = p.ctx.S;
  S.queue = [item('a'), item('b'), item('c')];
  S.index = 0;
  S.radioQ = S.queue;
  S.radioCont = 'OLD-TOKEN-xxx';
  S.chips = CHIPS;
  p.ctx.pickChip(1);
  await chipSettle(p);
  assert.deepEqual(ids(S.queue), ['a', 'b', 'c']);
  assert.equal(S.radioCont, 'OLD-TOKEN-xxx');
  assert.equal(S.chips[1].selected, false);
  assert.equal(p.ctx.toasts.length, 1);
  // everything the answer has was heard lately: those songs come back rather than none
  const p2 = page(() => answer(['a', 'h1', 'h2'], ''), { history: ['h1', 'h2'] });
  const S2 = p2.ctx.S;
  S2.queue = [item('a'), item('z')];
  S2.index = 0;
  S2.radioQ = S2.queue;
  S2.chips = CHIPS;
  p2.ctx.pickChip(1);
  await chipSettle(p2);
  assert.deepEqual(ids(S2.queue), ['a', 'h1', 'h2']);
});

test('a chosen list that runs out goes on with its automix; without one, with a radio from the last song', async () => {
  const AM = { playlistId: 'RDAMPLfake', params: 'fakeAm%3D' };
  const run = async (automix, cont) => {
    const p = page(() => answer(['c', 'd', 'e'], 'TOKEN-NEW-xx'));
    const S = p.ctx.S;
    S.queue = [item('a'), item('b')];
    S.index = 1;
    S.radioQ = S.queue;
    S.radioCont = cont || '';
    S.automixQ = S.queue;
    S.automix = automix;
    p.ctx.extendQueue();
    await settle(p);
    return p;
  };
  const withAm = await run(AM);
  assert.deepEqual(withAm.asked, ['/api/queue?videoId=' + vid('b') + '&playlistId=RDAMPLfake&params=fakeAm%253D']);
  assert.deepEqual(ids(withAm.ctx.S.queue), ['a', 'b', 'c', 'd', 'e']);
  assert.equal(withAm.ctx.S.automix, null, 'used once');
  assert.equal(withAm.ctx.S.radioCont, 'TOKEN-NEW-xx');
  assert.equal(withAm.ctx.S.radioPid, 'RDAMPLfake');
  assert.equal(withAm.ctx.S.radioParams, 'fakeAm%3D');
  const without = await run(null);
  assert.deepEqual(without.asked, ['/api/queue?videoId=' + vid('b')]);
  // the list's own continuation, when it has one, comes first
  const own = await run(AM, 'LIST-TOKEN-xx');
  assert.deepEqual(own.asked, ['/api/queue?c=LIST-TOKEN-xx']);
  // an automix that cannot be had is dropped; the next time is a radio from the last song
  const bad = page((q) => (q.includes('RDAMPLfake') ? new Error('gone') : answer(['c', 'd', 'e'], '')));
  const S = bad.ctx.S;
  S.queue = [item('a'), item('b')];
  S.index = 1;
  S.radioQ = S.queue;
  S.automixQ = S.queue;
  S.automix = AM;
  bad.ctx.extendQueue();
  await settle(bad);
  assert.equal(S.automix, null);
  bad.ctx.extendQueue();
  await settle(bad);
  assert.equal(bad.asked[1], '/api/queue?videoId=' + vid('b'));
  assert.deepEqual(ids(S.queue), ['a', 'b', 'c', 'd', 'e']);
});

test('a list with repeated songs is queued with each once, the first stays', () => {
  const p = page(() => ({}));
  const l = ['l1', 'l2', 'l1', 'l3', 'l2'].map((n) => item(n));
  p.ctx.playFromList(l, l[1]);
  assert.deepEqual(ids(p.ctx.S.queue), ['l2', 'l3']);
  p.ctx.playFromList(l, l[0]);
  assert.deepEqual(ids(p.ctx.S.queue), ['l1', 'l2', 'l3']);
  p.ctx.playAll(l, null);
  assert.deepEqual(ids(p.ctx.S.queue), ['l1', 'l2', 'l3']);
});

test('the chips and the chosen one are saved with the radio and come back after a restart', () => {
  const p = page(() => ({}));
  const S = p.ctx.S;
  S.queue = [item('a'), item('b')];
  S.index = 0;
  S.cur = S.queue[0];
  S.ready = true;
  S.radioQ = S.queue;
  S.radioCont = 'TOKEN-SAVED-';
  S.radioSeen = [vid('a')];
  S.radioParams = 'fakeFam%3D';
  S.radioPid = 'RDATfakefam';
  S.chips = CHIPS.map((c) => Object.assign({}, c, { selected: c.title === 'Familiar' }));
  p.ctx.saveState(true);
  const p2 = page(() => ({}));
  p2.store.ytm_state = p.store.ytm_state;
  p2.ctx.restoreState();
  const S2 = p2.ctx.S;
  assert.deepEqual(JSON.parse(JSON.stringify(S2.chips)), JSON.parse(JSON.stringify(S.chips)));
  assert.equal(S2.chips[1].selected, true);
  assert.equal(S2.radioPid, 'RDATfakefam');
  assert.equal(S2.radioParams, 'fakeFam%3D');
  // a queue that does not own the radio keeps no chips
  S.radioQ = [];
  p.ctx.saveState(true);
  assert.equal(JSON.parse(p.store.ytm_state).radio, null);
});
