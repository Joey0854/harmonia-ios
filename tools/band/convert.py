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
# nn.MultiheadAttention's fused fast path (aten::_native_multi_head_attention) has no Core ML
# conversion; the plain path computes the same.
torch.backends.mha.set_fastpath_enabled(False)


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
fused = [n.kind() for n in traced.inlined_graph.nodes() if "native_multi_head" in n.kind()]
assert not fused, fused
again = traced(tx, txt)


def rel(a, b):
    a, b = np.asarray(a, np.float64), np.asarray(b, np.float64)
    return float(np.sqrt(((a - b) ** 2).sum() / max((b ** 2).sum(), 1e-30)))


check = {"eager_seconds": round(eager_s, 2),
         "trace_rel_spec": rel(again[0], ref[0]), "trace_rel_wave": rel(again[1], ref[1])}
print("trace:", json.dumps(check))
if trace_only:
    sys.exit(0)

import shutil  # noqa: E402

import coremltools as ct  # noqa: E402

y_ref = R.finish(ref[0].numpy(), ref[1].numpy(), stats)
# Wanted: every stem within -30 dB of torch. Tried in this order; the first that is good enough
# is kept as HTDemucsBody.mlpackage. Plain float16 is the smallest, but the group norms over
# whole segments (hundreds of thousands of values) may not survive it.
KEEP_FP32 = {"reduce_mean", "reduce_sum", "reduce_sum_square", "square", "pow", "rsqrt", "sqrt",
             "real_div", "layer_norm", "instance_norm", "batch_norm", "softmax"}
variants = [
    ("fp16", ct.precision.FLOAT16),
    ("mixed", ct.transform.FP16ComputePrecision(op_selector=lambda op: op.op_type not in KEEP_FP32)),
    # float32 computing with 8-bit weights (per channel, symmetric): a quarter of the file; on
    # iOS 16 the weights are expanded when the model loads (memory at run time: not measured)
    ("w8", ct.precision.FLOAT32),
    ("fp32", ct.precision.FLOAT32),
]
chosen = None
for name, precision in variants:
    entry = {}
    try:
        t = time.time()
        mlmodel = ct.convert(
            traced,
            inputs=[ct.TensorType(name="spec", shape=tuple(x.shape), dtype=np.float32),
                    ct.TensorType(name="wave", shape=tuple(xt.shape), dtype=np.float32)],
            outputs=[ct.TensorType(name="spec_out", dtype=np.float32),
                     ct.TensorType(name="wave_out", dtype=np.float32)],
            convert_to="mlprogram",
            compute_precision=precision,
            minimum_deployment_target=ct.target.iOS16,
        )
        if name == "w8":
            op_config = ct.optimize.coreml.OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8",
                                                                   granularity="per_channel")
            mlmodel = ct.optimize.coreml.linear_quantize_weights(
                mlmodel, config=ct.optimize.coreml.OptimizationConfig(global_config=op_config))
        entry["convert_seconds"] = round(time.time() - t, 1)
        mlmodel.short_description = "HTDemucs network body (between normalisations); see tools/band/band_ref.py"
        path = os.path.join(out_dir, name + ".mlpackage")
        mlmodel.save(path)
        del mlmodel
        entry["package_mb"] = round(sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fs in os.walk(path) for f in fs) / 1e6, 1)
        for units in ["CPU_ONLY", "CPU_AND_GPU"]:
            m = ct.models.MLModel(path, compute_units=getattr(ct.ComputeUnit, units))
            t = time.time()
            pred = m.predict({"spec": x, "wave": xt})
            secs = time.time() - t
            a, b = pred["spec_out"], pred["wave_out"]
            y_ml = R.finish(a, b, stats)
            stems = {s_name: round(float(20 * np.log10(rel(y_ml[s], y_ref[s]) + 1e-30)), 1)
                     for s, s_name in enumerate(R.SOURCES)}
            entry[units] = {"seconds": round(secs, 2), "rel_spec": rel(a, ref[0]), "rel_wave": rel(b, ref[1]),
                            "stem_error_db": stems}
            del m
        worst = max(max(entry[u]["stem_error_db"].values()) for u in ["CPU_ONLY", "CPU_AND_GPU"])
        entry["worst_db"] = worst
    except Exception as e:  # report and try the next variant
        entry["error"] = repr(e)[:800]
        worst = None
    check[name] = entry
    print(name, json.dumps(entry), flush=True)
    if worst is not None and worst < -30:
        chosen = name
        break
check["chosen"] = chosen
with open(os.path.join(out_dir, "check.json"), "w") as f:
    json.dump(check, f, indent=1)
if chosen is None:
    sys.exit("no variant matched torch within -30 dB")
shutil.copytree(os.path.join(out_dir, chosen + ".mlpackage"), os.path.join(out_dir, "HTDemucsBody.mlpackage"))
print("chosen:", chosen)
