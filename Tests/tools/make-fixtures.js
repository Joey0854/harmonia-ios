/* Builds the files in Tests/Fixtures. Run on the PC (needs ffmpeg and the ytm-remote server):
     node Tests/tools/make-fixtures.js
   The test signal itself is NOT stored: it is made from whole-number arithmetic only, so the
   Swift test (TestSignal.swift) produces exactly the same samples. `checksum` proves it. */
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');
const { execFileSync, spawnSync } = require('child_process');

const OUT = path.join(__dirname, '..', 'Fixtures');
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'ytm-fix-'));
const RATE = 48000, SECONDS = 6, N = RATE * SECONDS;
const IR_QUERY = '?b=dh&w=40&v=50&h=85&t=120&o=30&g=30';

/* ---- the test signal: keep in step with Tests/SoundCoreTests/TestSignal.swift ---- */
function makeSignal() {
  const L = new Int16Array(N), R = new Int16Array(N);
  let sa = 12345 >>> 0, sb = 987654321 >>> 0, pa = 0, pb = 0;
  for (let n = 0; n < N; n++) {
    sa = (Math.imul(sa, 1664525) + 1013904223) >>> 0;
    sb = (Math.imul(sb, 22695477) + 1) >>> 0;
    const na = ((sa >>> 16) & 0xFFFF) - 32768, nb = ((sb >>> 16) & 0xFFFF) - 32768;
    pa = (pa + 8947849 + 2454 * n) >>> 0;
    pb = (pb + 715000000 - 2454 * n) >>> 0;
    const qa = pa >>> 16, qb = pb >>> 16;
    const ta = qa < 32768 ? qa * 2 - 32768 : (65535 - qa) * 2 - 32768;
    const tb = qb < 32768 ? qb * 2 - 32768 : (65535 - qb) * 2 - 32768;
    /* Noise comes in bursts of 0.5 s every 0.75 s, each a different strength; the sweeps
       stop after 4 s, and 4.0 - 4.75 s is silent. */
    const ka = Math.floor(n / 36000), kb = Math.floor((n + 12000) / 36000);
    const ampA = (n % 36000) < 24000 ? 1 + (ka * 3) % 6 : 0;
    const ampB = ((n + 12000) % 36000) < 24000 ? 1 + (kb * 5) % 6 : 0;
    const quiet = n >= 192000 && n < 228000;
    const sweep = n < 192000;
    L[n] = quiet ? 0 : ((na * ampA) >> 4) + (sweep ? (ta >> 2) : 0);
    R[n] = quiet ? 0 : ((nb * ampB) >> 4) + (sweep ? (tb >> 2) : 0);
  }
  return { L, R };
}
function checksum(sig) {
  let h = 0;
  for (let n = 0; n < N; n++) {
    h = (Math.imul(h, 31) + (sig.L[n] & 0xFFFF)) >>> 0;
    h = (Math.imul(h, 31) + (sig.R[n] & 0xFFFF)) >>> 0;
  }
  return h;
}
function wav16(channels, rate) {
  const n = channels[0].length, c = channels.length;
  const b = Buffer.alloc(44 + n * c * 2);
  b.write('RIFF', 0); b.writeUInt32LE(36 + n * c * 2, 4); b.write('WAVEfmt ', 8);
  b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(c, 22); b.writeUInt32LE(rate, 24);
  b.writeUInt32LE(rate * c * 2, 28); b.writeUInt16LE(c * 2, 32); b.writeUInt16LE(16, 34);
  b.write('data', 36); b.writeUInt32LE(n * c * 2, 40);
  for (let i = 0; i < n; i++) for (let k = 0; k < c; k++) b.writeInt16LE(channels[k][i], 44 + (i * c + k) * 2);
  return b;
}
function get(url) {
  return new Promise((resolve, reject) => {
    http.get(url, (r) => {
      if (r.statusCode !== 200) { r.resume(); return reject(new Error(url + ' -> HTTP ' + r.statusCode)); }
      const parts = [];
      r.on('data', (c) => parts.push(c));
      r.on('end', () => resolve(Buffer.concat(parts)));
    }).on('error', reject);
  });
}
function ffmpeg(args) {
  const r = spawnSync('ffmpeg', ['-hide_banner', '-nostats', '-y'].concat(args), { cwd: TMP, encoding: 'utf8', maxBuffer: 1 << 28 });
  if (r.status !== 0) throw new Error('ffmpeg failed: ' + r.stderr.slice(-600));
  return r.stderr;
}
/* Sets the length fields the way YouTube's files have them: the movie header already holds the
   full length although the samples are all in fragments (iOS then reports twice the length). */
function patchDurations(file, units) {
  const b = fs.readFileSync(file);
  const walk = (o, end) => {
    while (o + 8 <= end) {
      const s = b.readUInt32BE(o), t = b.toString('latin1', o + 4, o + 8);
      if (s < 8) break;
      if (t === 'moov' || t === 'trak' || t === 'mdia') walk(o + 8, o + s);
      if ((t === 'mvhd' || t === 'mdhd') && b[o + 8] === 0) {
        const scale = b.readUInt32BE(o + 20);
        b.writeUInt32BE(Math.round(units * scale), o + 24);
      }
      if (t === 'tkhd' && b[o + 8] === 0) b.writeUInt32BE(Math.round(units * 1000), o + 28);
      o += s;
    }
  };
  walk(0, b.length);
  fs.writeFileSync(file, b);
}

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  const sig = makeSignal();
  fs.writeFileSync(path.join(TMP, 'signal.wav'), wav16([sig.L, sig.R], RATE));

  const irL = await get('http://127.0.0.1:8787/api/ir/custom/L.wav' + IR_QUERY);
  const irR = await get('http://127.0.0.1:8787/api/ir/custom/R.wav' + IR_QUERY);
  fs.writeFileSync(path.join(OUT, 'irL.wav'), irL);
  fs.writeFileSync(path.join(OUT, 'irR.wav'), irR);
  fs.writeFileSync(path.join(TMP, 'irL.wav'), irL);
  fs.writeFileSync(path.join(TMP, 'irR.wav'), irR);

  /* Expected surround output: the graph the PC server uses. */
  const graph = '[0:a]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo,asplit=2[a][b];' +
    '[a]pan=stereo|c0=c0|c1=c0[l];[b]pan=stereo|c0=c1|c1=c1[r];' +
    '[l][1:a]afir=dry=1:wet=1:irnorm=-1:irlink=0:irgain=1[ol];[r][2:a]afir=dry=1:wet=1:irnorm=-1:irlink=0:irgain=1[or];' +
    '[ol][or]amix=inputs=2:normalize=0[out]';
  ffmpeg(['-i', 'signal.wav', '-i', 'irL.wav', '-i', 'irR.wav', '-filter_complex', graph, '-map', '[out]', '-f', 'f32le', '-ar', '48000', '-ac', '2', 'expected.f32']);
  const raw = fs.readFileSync(path.join(TMP, 'expected.f32'));
  const f = new Float32Array(raw.buffer, raw.byteOffset, Math.floor(raw.length / 4));
  let peak = 0;
  for (let i = 0; i < f.length; i++) peak = Math.max(peak, Math.abs(f[i]));
  const scale = 30000 / peak;
  const s16 = Buffer.alloc(f.length * 2);
  for (let i = 0; i < f.length; i++) s16.writeInt16LE(Math.round(f[i] * scale), i * 2);
  fs.writeFileSync(path.join(OUT, 'expected-surround.s16'), s16);

  /* Loudness as ffmpeg measures it. */
  const log = ffmpeg(['-i', 'signal.wav', '-af', 'ebur128=framelog=quiet', '-f', 'null', '-']);
  const all = log.match(/I:\s+(-?[\d.]+) LUFS/g);
  const lufs = Number(/(-?[\d.]+) LUFS/.exec(all[all.length - 1])[1]);

  /* Envelope exactly as ensureEnv() in ytm-remote/server.js makes it. */
  ffmpeg(['-loglevel', 'error', '-i', 'signal.wav', '-vn', '-ac', '1', '-ar', '11025', '-f', 's16le', 'pcm.raw']);
  const pb = fs.readFileSync(path.join(TMP, 'pcm.raw'));
  const x = new Int16Array(pb.buffer, pb.byteOffset, Math.floor(pb.length / 2));
  const sr = 11025, rate = 30, n = Math.floor(x.length * rate / sr);
  const env = Buffer.alloc(n * 2);
  const aLow = Math.exp(-2 * Math.PI * 180 / sr), aLo = Math.exp(-2 * Math.PI * 400 / sr), aHi = Math.exp(-2 * Math.PI * 2800 / sr);
  let low = 0, lo = 0, hi = 0;
  for (let k = 0; k < n; k++) {
    const from = Math.floor(k * sr / rate), to = Math.floor((k + 1) * sr / rate);
    let eb = 0, em = 0;
    for (let i = from; i < to; i++) {
      const v = x[i] / 32768;
      low = low * aLow + v * (1 - aLow);
      lo = lo * aLo + v * (1 - aLo);
      hi = hi * aHi + v * (1 - aHi);
      const mid = hi - lo;
      eb += low * low;
      em += mid * mid;
    }
    const d = Math.max(1, to - from);
    env[k * 2] = Math.min(255, Math.round(255 * Math.sqrt(Math.sqrt(eb / d))));
    env[k * 2 + 1] = Math.min(255, Math.round(255 * Math.sqrt(Math.sqrt(em / d))));
  }
  fs.writeFileSync(path.join(OUT, 'expected-env.bin'), env);

  /* The same signal as AAC, once as YouTube delivers songs (fragments of about a second, a
     segment index, the full length already in the movie header) and once as a plain file. */
  ffmpeg(['-loglevel', 'error', '-i', 'signal.wav', '-ar', '44100', '-c:a', 'aac', '-b:a', '128k',
    '-movflags', '+dash+frag_keyframe+empty_moov+default_base_moof', '-frag_duration', '1000000', '-f', 'mp4', 'song-fragmented.m4a']);
  patchDurations(path.join(TMP, 'song-fragmented.m4a'), SECONDS);
  ffmpeg(['-loglevel', 'error', '-i', 'signal.wav', '-ar', '44100', '-c:a', 'aac', '-b:a', '128k', '-movflags', '+faststart', '-f', 'mp4', 'song-plain.m4a']);
  fs.copyFileSync(path.join(TMP, 'song-fragmented.m4a'), path.join(OUT, 'song-fragmented.m4a'));
  fs.copyFileSync(path.join(TMP, 'song-plain.m4a'), path.join(OUT, 'song-plain.m4a'));

  const info = {
    made: new Date().toISOString(), ffmpeg: execFileSync('ffmpeg', ['-version'], { encoding: 'utf8' }).split('\n')[0].trim(),
    sampleRate: RATE, frames: N, checksum: checksum(sig),
    surroundFrames: f.length / 2, surroundScale: scale,
    lufs: lufs, lufsCommand: 'ffmpeg -i signal.wav -af ebur128=framelog=quiet -f null -',
    envSteps: n, irQuery: IR_QUERY
  };
  fs.writeFileSync(path.join(OUT, 'fixture.json'), JSON.stringify(info, null, 2) + '\n');
  console.log(JSON.stringify(info, null, 2));
  let total = 0;
  for (const name of fs.readdirSync(OUT)) { const s = fs.statSync(path.join(OUT, name)).size; total += s; console.log(String(s).padStart(9), name); }
  console.log(String(total).padStart(9), 'total');
  console.log('work files kept in', TMP);
})().catch((e) => { console.error(e); process.exit(1); });
