"""Builds Tests/Fixtures/band.json from tools/band/band_ref.py (numpy, double precision).

usage: python -I Tests/tools/make-band-fixtures.py
The test signal is not stored: BandTests.swift makes the same samples (TestRandom + sines).
The "network" is a fake with a fixed rule, so no model is needed:
    spec_out[s*4 + j] = spec[j] * (s + 1) / 10,  wave_out[s*2 + c] = wave[c] * (4 - s) / 10
"""
import json
import os
import sys

import numpy as np

here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(here, "..", "..", "tools", "band"))
import band_ref as R  # noqa: E402


def random(seed, n):
    out = np.zeros(n, np.float32)
    state = np.uint32(seed)
    a, c = np.uint32(1664525), np.uint32(1013904223)
    with np.errstate(over="ignore"):
        for i in range(n):
            state = state * a + c
            out[i] = np.float32(np.int32(state.view(np.int32)) >> 8) / np.float32(8388608)
    return out


def signal(n):
    k = np.arange(n)
    left = (0.3 * np.sin(2 * np.pi * 220 * k / R.SR)).astype(np.float32) + np.float32(0.2) * random(11, n)
    right = (0.25 * np.sin(2 * np.pi * 331 * k / R.SR + 1)).astype(np.float32) + np.float32(0.2) * random(22, n)
    return np.stack([left, right]).astype(np.float64)


def fake(x, xt):
    spec = np.concatenate([x[0] * (s + 1) / 10 for s in range(4)])[None].astype(np.float32)
    wave = np.concatenate([xt[0] * (4 - s) / 10 for s in range(4)])[None].astype(np.float32)
    return spec, wave


total = 20 * R.SR
mix = signal(total)
seg = mix[:, :R.SEGMENT]
out = {"rule": "see make-band-fixtures.py"}

z = R.spec(seg[0])
points = []
for f in [0, 1, 5, 100, 1000, 2047]:
    for t in [0, 1, 2, 100, 334, 335]:
        points.append([f, t, float(z[f, t].real), float(z[f, t].imag)])
out["spectrum"] = {"points": points, "max": float(np.abs(z).max())}
x, xt, stats = R.prepare(seg)
out["stats"] = [float(v) for v in stats]

stems = R.finish(*fake(x, xt), stats)
where = [0, 1, 1000, 171990, R.SEGMENT - 1]
out["segment"] = {"at": where,
                  "values": [[[float(stems[s, c, i]) for i in where] for c in range(2)] for s in range(4)],
                  "rms": [[float(np.sqrt((stems[s, c] ** 2).mean())) for c in range(2)] for s in range(4)]}

full = R.separate(mix, fake)
where = [0, 100000, 257985, 300000, 515970, 600000, 773955, total - 1]
out["stream"] = {"length": total, "at": where,
                 "values": [[[float(full[s, c, i]) for i in where] for c in range(2)] for s in range(4)],
                 "rms": [[float(np.sqrt((full[s, c] ** 2).mean())) for c in range(2)] for s in range(4)]}

path = os.path.join(here, "..", "Fixtures", "band.json")
with open(path, "w") as f:
    json.dump(out, f, indent=1)
print("wrote", path)
