"""Converts the HTDemucs network body (band_ref.Body) to Core ML and checks it against torch.

usage: python convert.py <out_dir> [--trace-only]
Writes <out_dir>/HTDemucsBody.mlpackage and <out_dir>/check.json. With --trace-only (no
coremltools, e.g. on Windows) it only checks that the traced module matches the eager one.
The input is a fixed test signal (sines and noise), the same one Tests/tools uses.
"""
import json
import os
import sys
import time

import numpy as np
import torch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import band_ref as R  # noqa: E402

out_dir = sys.argv[1]
trace_only = "--trace-only" in sys.argv
os.makedirs(out_dir, exist_ok=True)
torch.set_grad_enabled(False)


def test_signal():
    n = np.arange(R.SEGMENT)
    rng = np.random.default_rng(7)
    left = 0.3 * np.sin(2 * np.pi * 220 * n / R.SR) + 0.1 * rng.standard_normal(R.SEGMENT)
    right = 0.25 * np.sin(2 * np.pi * 331 * n / R.SR + 1) + 0.1 * rng.standard_normal(R.SEGMENT)
    beat = (np.sin(2 * np.pi * 2 * n / R.SR) > 0.95) * rng.standard_normal(R.SEGMENT) * 0.5
    return np.stack([left + beat, right + beat])


model, body = R.load_body()
x, xt, stats = R.prepare(test_signal())
tx, txt = torch.from_numpy(x), torch.from_numpy(xt)
t = time.time()
ref = body(tx, txt)
eager_s = time.time() - t
traced = torch.jit.trace(body, (tx, txt), check_trace=False)
again = traced(tx, txt)


def rel(a, b):
    a, b = np.asarray(a, np.float64), np.asarray(b, np.float64)
    return float(np.sqrt(((a - b) ** 2).sum() / max((b ** 2).sum(), 1e-30)))


check = {"eager_seconds": round(eager_s, 2),
         "trace_rel_spec": rel(again[0], ref[0]), "trace_rel_wave": rel(again[1], ref[1])}
print("trace:", json.dumps(check))
if trace_only:
    sys.exit(0)

import coremltools as ct  # noqa: E402

t = time.time()
mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="spec", shape=tuple(x.shape), dtype=np.float32),
            ct.TensorType(name="wave", shape=tuple(xt.shape), dtype=np.float32)],
    outputs=[ct.TensorType(name="spec_out", dtype=np.float32),
             ct.TensorType(name="wave_out", dtype=np.float32)],
    convert_to="mlprogram",
    compute_precision=ct.precision.FLOAT16,
    minimum_deployment_target=ct.target.iOS16,
)
check["convert_seconds"] = round(time.time() - t, 1)
mlmodel.short_description = "HTDemucs network body (between normalisations); see tools/band/band_ref.py"
path = os.path.join(out_dir, "HTDemucsBody.mlpackage")
mlmodel.save(path)

for units in ["CPU_ONLY", "CPU_AND_GPU"]:
    try:
        m = ct.models.MLModel(path, compute_units=getattr(ct.ComputeUnit, units))
        t = time.time()
        pred = m.predict({"spec": x, "wave": xt})
        secs = time.time() - t
        a, b = pred["spec_out"], pred["wave_out"]
        y_ml = R.finish(a, b, stats)
        y_ref = R.finish(ref[0].numpy(), ref[1].numpy(), stats)
        stems = {name: round(float(20 * np.log10(rel(y_ml[s], y_ref[s]) + 1e-30)), 1)
                 for s, name in enumerate(R.SOURCES)}
        check[units] = {"seconds": round(secs, 2), "rel_spec": rel(a, ref[0]), "rel_wave": rel(b, ref[1]),
                        "stem_error_db": stems}
    except Exception as e:  # report and go on: the other unit may still work
        check[units] = {"error": repr(e)[:500]}
    print(units, json.dumps(check[units]))
with open(os.path.join(out_dir, "check.json"), "w") as f:
    json.dump(check, f, indent=1)
