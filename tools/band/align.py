"""PC check: Body + numpy pre/post processing against demucs' apply_model.

usage: python -I align.py <song.wav> <seconds> [fixture_out.json]
Prints the difference per source in dB (error energy / reference energy).
"""
import json
import os
import sys

import numpy as np
import soundfile as sf
import torch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import band_ref as R  # noqa: E402

song, seconds = sys.argv[1], float(sys.argv[2])
wave, sr = sf.read(song, dtype="float32")
assert sr == R.SR
mix = wave[: int(seconds * sr)].T.astype(np.float64)

model, body = R.load_body()
from demucs.apply import apply_model  # noqa: E402

with torch.no_grad():
    ref = apply_model(model, torch.tensor(mix, dtype=torch.float32)[None], shifts=0, split=True,
                      overlap=0.25, progress=False)[0].numpy().astype(np.float64)


def run(x, xt):
    with torch.no_grad():
        a, b = body(torch.from_numpy(x), torch.from_numpy(xt))
    return a.numpy(), b.numpy()


mine = R.separate(mix, run)
report = {}
for s, name in enumerate(R.SOURCES):
    err = ((mine[s] - ref[s]) ** 2).sum() / max((ref[s] ** 2).sum(), 1e-20)
    report[name] = round(float(10 * np.log10(err + 1e-30)), 1)
print("diff dB vs apply_model:", json.dumps(report))
print("sum of stems vs mix dB:",
      round(float(10 * np.log10(((mine.sum(0) - mix) ** 2).sum() / (mix ** 2).sum())), 1))
