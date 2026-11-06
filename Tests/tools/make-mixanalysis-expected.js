// Prints what the original PC analysis (analysePcm in Web/backend.js) says about a made-up song.
// Tests/SoundCoreTests/MixAnalyzerTests.swift builds the same song and expects the same answer.
//   node Tests/tools/make-mixanalysis-expected.js
const fs = require('fs');
const path = require('path');
const src = fs.readFileSync(path.join(__dirname, '..', '..', 'Web', 'backend.js'), 'utf8');
const a = src.indexOf('function analysePcm(x) {');
const b = src.indexOf('function getMixInfo(id) {');
if (a < 0 || b < 0) throw new Error('analysePcm not found');
const analysePcm = new Function(src.slice(a, b) + '\nreturn analysePcm;')();

// 3 s silence, 5 s soft pad, 52 s loud with a kick drum every half second (120 bpm, first
// beat at 8.1 s), then a 10 s fade out
function song(sr) {
  const total = 70 * sr;
  const out = new Int16Array(total);
  for (let i = 0; i < total; i++) {
    const t = i / sr;
    let v = 0;
    if (t >= 3 && t < 8) v = 0.02 * Math.sin(2 * Math.PI * 220 * t);
    if (t >= 8) {
      let amp = 1;
      if (t >= 60) amp = Math.max(0, 1 - (t - 60) / 10);
      const since = (t - 8.1) % 0.5;
      const kick = t >= 8.1 ? 0.8 * Math.sin(2 * Math.PI * 60 * since) * Math.exp(-since * 20) : 0;
      v = amp * (kick + 0.15 * Math.sin(2 * Math.PI * 330 * t));
    }
    out[i] = Math.trunc(v * 32767);
  }
  return out;
}
console.log(JSON.stringify(analysePcm(song(11025))));
