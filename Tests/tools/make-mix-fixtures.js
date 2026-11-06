/* Builds Tests/Fixtures/mix-analysis.json (what the PC server found out about 11 real songs) and
   Tests/Fixtures/mix-expected.json (the mix plan for every ordered pair of them). Run on the PC
   with the ytm-remote server up:
     node Tests/tools/make-mix-fixtures.js            (fetch the analyses, then plan)
     node Tests/tools/make-mix-fixtures.js --offline  (plan from the stored analyses)
   plan() below is the reference for App/Sound/MixPlanner.swift: the same rules, written
   independently in JavaScript. The Swift test must agree with it to the millisecond. */
'use strict';
const fs = require('fs');
const path = require('path');
const http = require('http');

const OUT = path.join(__dirname, '..', 'Fixtures');
const IDS = ['3Fz17pPuI4k', 'nhOhFOoURnE', 'IwQGnXpskoY', 'vMt0XYO3L8U', 'qaVli_4qiVs', 'FIEt1VxlDvs',
  '6Axc3ezh290', 'kb1Kihiiw7k', '78masZti800', '7BpOywfaiFs', '9B0yX0UIN9M'];

const num = (v) => typeof v === 'number' && isFinite(v);

function plan(a, b, durationA, availableB, mixOn) {
  if (!mixOn) return { none: 'mixing is off' };
  if (!a) return { none: 'no analysis of the current song' };
  if (!b) return { none: 'no analysis of the next song' };
  if (!num(a.bodyEnd) || !num(a.tailEnd) || !num(a.quietStart) || !num(b.bodyStart)) return { none: 'analysis incomplete' };
  const durA = durationA > 0 ? durationA : (num(a.dur) ? a.dur : 0);
  const durB = availableB > 0 ? availableB : (num(b.dur) ? b.dur : 0);
  if (durA <= 0 || durB <= 0) return { none: 'length unknown' };
  if (num(a.dur) && Math.abs(a.dur - durA) > 1.5) return { none: 'analysis does not fit this file' };
  if (durA < 30) return { none: 'current song shorter than 30 s' };

  const end = Math.min(durA, Math.max(a.tailEnd, a.bodyEnd + 0.5));
  let synced = false;
  if (num(a.bpm) && num(b.bpm) && num(a.beat0) && num(b.beat0) && a.bpm > 0 && b.bpm > 0 &&
      (num(a.conf) ? a.conf : 0) >= 2 && (num(b.conf) ? b.conf : 0) >= 2 && a.tailEnd - a.bodyEnd <= 2) {
    for (const m of [1, 2, 0.5]) {
      const ratio = a.bpm / b.bpm * m;
      if (Math.abs(ratio - 1) <= 0.005) synced = true;
    }
  }
  let overlap, startA, bOffset, bDelay;
  if (synced) {
    const pa = 60 / a.bpm, pb = 60 / b.bpm;
    overlap = pa * 16;
    while (overlap < 4) overlap *= 2;
    while (overlap > 8) overlap /= 2;
    bOffset = Math.max(0, b.bodyStart - 0.3);
    bDelay = 0;
    const bBeat = b.beat0 + Math.ceil((bOffset - b.beat0) / pb) * pb;
    const lead = bBeat - bOffset;
    startA = a.beat0 + Math.ceil((end - overlap + lead - a.beat0) / pa) * pa - lead;
    while (startA + overlap > end + 1e-9) startA -= pa;
  } else {
    overlap = Math.max(2, Math.min(3, a.tailEnd - a.quietStart + 1.5));
    startA = end - overlap;
    bOffset = Math.max(0, b.bodyStart - overlap / 2);
    bDelay = Math.max(0, overlap / 2 - b.bodyStart);
  }
  if (startA < durA * 0.5) return { none: 'the mix would begin before the middle of the song' };
  if (bOffset + overlap - bDelay > durB) return { none: 'next song too short' };
  return { startA, overlap, end, bOffset, bDelay, synced };
}

function get(url) {
  return new Promise((resolve, reject) => {
    http.get(url, (r) => {
      const parts = [];
      r.on('data', (c) => parts.push(c));
      r.on('end', () => r.statusCode === 200 ? resolve(Buffer.concat(parts).toString('utf8')) : reject(new Error(url + ' -> HTTP ' + r.statusCode)));
    }).on('error', reject);
  });
}

(async () => {
  const file = path.join(OUT, 'mix-analysis.json');
  let songs;
  if (process.argv.includes('--offline')) {
    songs = JSON.parse(fs.readFileSync(file, 'utf8'));
  } else {
    songs = {};
    for (const id of IDS) songs[id] = JSON.parse(await get('http://127.0.0.1:8787/api/mix/' + id));
    fs.writeFileSync(file, JSON.stringify(songs, null, 1) + '\n');
  }
  const pairs = [];
  for (const a of IDS) for (const b of IDS) {
    if (a === b) continue;
    pairs.push({ a, b, result: plan(songs[a], songs[b], songs[a].dur, songs[b].dur, true) });
  }
  /* The real songs happen to give no beat-matched pair (those with fitting tempos have endings
     of their own). So the same pairs once more with A's ending taken away, plus a few with other
     things changed; these entries carry the changed analysis with them. */
  const real = pairs.length;
  for (const a of IDS) for (const b of IDS) {
    if (a === b) continue;
    const aInfo = Object.assign({}, songs[a], { bodyEnd: songs[a].tailEnd - 1 });
    const r = plan(aInfo, songs[b], aInfo.dur, songs[b].dur, true);
    if (r.synced) pairs.push({ a, b, aInfo, bInfo: songs[b], durationA: aInfo.dur, availableB: songs[b].dur, result: r });
  }
  const extra = (a, b, changeA, changeB, durationA, availableB) => {
    const aInfo = Object.assign({}, songs[a], changeA), bInfo = Object.assign({}, songs[b], changeB);
    pairs.push({ a, b, aInfo, bInfo, durationA, availableB, result: plan(aInfo, bInfo, durationA, availableB, true) });
  };
  extra('kb1Kihiiw7k', '78masZti800', { bodyEnd: 206.5 }, { bpm: 199.98 }, 0, 0);          // B at double tempo
  extra('kb1Kihiiw7k', '78masZti800', { bodyEnd: 206.5 }, { bpm: 50 }, 0, 0);              // B at half tempo
  extra('kb1Kihiiw7k', '78masZti800', { bodyEnd: 206.5 }, { bpm: 99.99, conf: 1.9 }, 0, 0); // tempo fits, not sure enough
  extra('kb1Kihiiw7k', '78masZti800', { bodyEnd: 206.5 }, { bpm: 100.6 }, 0, 0);           // 0.6 % apart
  extra('kb1Kihiiw7k', '78masZti800', {}, {}, 214, 0);                                     // file of another length
  extra('kb1Kihiiw7k', '78masZti800', {}, {}, 0, 2.5);                                     // next song too short
  extra('kb1Kihiiw7k', '78masZti800', { tailEnd: 100, bodyEnd: 99, quietStart: 99 }, {}, 0, 0); // before the middle
  fs.writeFileSync(path.join(OUT, 'mix-expected.json'), JSON.stringify(pairs, null, 1) + '\n');
  const show = [['nhOhFOoURnE', '3Fz17pPuI4k'], ['IwQGnXpskoY', 'vMt0XYO3L8U'], ['7BpOywfaiFs', '9B0yX0UIN9M'],
    ['9B0yX0UIN9M', '7BpOywfaiFs'], ['FIEt1VxlDvs', '6Axc3ezh290'], ['qaVli_4qiVs', 'FIEt1VxlDvs']];
  const f = (v) => typeof v === 'number' ? v.toFixed(3) : String(v);
  for (const [a, b] of show) {
    const r = pairs.find((p) => p.a === a && p.b === b).result;
    console.log(a + ' -> ' + b + ': ' + (r.none ? 'none (' + r.none + ')' : ['startA', 'overlap', 'end', 'bOffset', 'bDelay', 'synced'].map((k) => k + ' ' + f(r[k])).join(', ')));
  }
  console.log(real + ' real pairs, ' + (pairs.length - real) + ' changed ones');
  const planned = pairs.filter((p) => !p.result.none);
  console.log(pairs.length + ' pairs: ' + planned.length + ' plans (' + planned.filter((p) => p.result.synced).length + ' beat-matched), ' + (pairs.length - planned.length) + ' without');
  const reasons = {};
  for (const p of pairs) if (p.result.none) reasons[p.result.none] = (reasons[p.result.none] || 0) + 1;
  console.log(JSON.stringify(reasons));
})().catch((e) => { console.error(e); process.exit(1); });
