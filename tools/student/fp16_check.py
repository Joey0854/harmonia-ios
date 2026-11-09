"""float16 forward of the student candidates on real music (random weights): no inf / NaN anywhere?

usage: python fp16_check.py <out.json> <song> [<song> ...] [--device cpu|cuda]
Each song: 3 segments (at 20 %, 50 %, 80 % of its length) prepared as App/Sound Demucs.separate does
(normalised STFT, n_fft 4096, hop 1024, z-scored), the model in float16; every module's output is checked
and its largest |value| recorded. Also the float32 output, for the float16-vs-float32 difference.
"""
import json
import os
import subprocess
import sys

import numpy as np
import torch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import student as S  # noqa: E402

SR, SEG, NFFT, HOP = 44100, 343980, 4096, 1024
args = [a for a in sys.argv[1:] if not a.startswith("--")]
dev = "cuda" if "--device=cuda" in sys.argv or "cuda" in sys.argv else "cpu"
out_path, songs = args[0], args[1:]
torch.set_grad_enabled(False)


def decode(p):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", p, "-f", "f32le", "-ac", "2", "-ar", str(SR), "-"],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, np.float32).reshape(-1, 2).T.copy()


def prep(seg):
    w = torch.hann_window(NFFT)
    z = torch.stft(torch.from_numpy(seg), NFFT, HOP, window=w, center=True, normalized=True,
                   return_complex=True)[:, :S.BINS, :S.FRAMES]          # [2, 2048, >=336]
    spec = torch.stack([z[0].real, z[0].imag, z[1].real, z[1].imag])[None]
    return (spec - spec.mean()) / (spec.std() + 1e-5)


report = {"device": dev, "models": {}}
for kind in ("A", "B"):
    m32 = S.build(kind).to(dev)
    m16 = S.build(kind).to(dev).half()
    peaks, bad = {}, []

    def hook(name):
        def f(_, __, out):
            if torch.is_tensor(out):
                v = out.float()
                if not torch.isfinite(v).all():
                    bad.append(name)
                peaks[name] = max(peaks.get(name, 0.0), float(v.abs().max()))
        return f

    for name, mod in m16.named_modules():
        if name:
            mod.register_forward_hook(hook(name))
    runs = []
    for p in songs:
        wave = decode(p)
        for frac in (0.2, 0.5, 0.8):
            s = int(frac * (wave.shape[1] - SEG))
            x = prep(wave[:, s:s + SEG]).to(dev)
            y16 = m16(x.half()).float()
            y32 = m32(x)
            diff = float(20 * torch.log10(torch.linalg.norm(y16 - y32) / torch.linalg.norm(y32)))
            runs.append({"song": os.path.basename(p), "at": frac, "input_absmax": round(float(x.abs().max()), 1),
                         "finite": bool(torch.isfinite(y16).all()), "fp16_vs_fp32_db": round(diff, 1)})
            print(kind, runs[-1], flush=True)
    top = sorted(peaks.items(), key=lambda kv: -kv[1])[:5]
    report["models"][kind] = {"params": S.params(m16), "runs": runs, "nonfinite_modules": sorted(set(bad)),
                              "largest_activations": {k: round(v, 1) for k, v in top},
                              "all_finite": all(r["finite"] for r in runs) and not bad}
with open(out_path, "w") as f:
    json.dump(report, f, indent=1)
print(json.dumps({k: (v["all_finite"], v["largest_activations"]) for k, v in report["models"].items()}))
