"""Converts the student candidates (random weights, seed 0) to Core ML float16 ML programs.

usage: python convert_student.py <out_dir> [--mil-only]
Writes <out_dir>/StudentA.mlpackage, StudentB.mlpackage and student-check.json. --mil-only (Windows: no Core ML
runtime there) stops at the MIL program and lists its op types, which is what the converter would emit.
On macOS it also runs each package on the CPU and compares with torch (float32), as a sanity check.
"""
import collections
import json
import os
import sys

import numpy as np
import torch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import student as S  # noqa: E402

out_dir = sys.argv[1]
mil_only = "--mil-only" in sys.argv
os.makedirs(out_dir, exist_ok=True)
torch.set_grad_enabled(False)
import coremltools as ct  # noqa: E402

rng = np.random.default_rng(3)
x = rng.standard_normal((1, 4, S.BINS, S.FRAMES)).astype(np.float32)
report = {}
for kind in ("A", "B"):
    m = S.build(kind)
    traced = torch.jit.trace(m, torch.from_numpy(x), check_trace=False)
    ref = traced(torch.from_numpy(x)).numpy()
    entry = {"params": S.params(m)}
    # float16 in and out (iOS 16+): no float32<->float16 casts left at the edges of the program
    kw = dict(inputs=[ct.TensorType(name="spec", shape=x.shape, dtype=np.float16)],
              outputs=[ct.TensorType(name="mask", dtype=np.float16)],
              minimum_deployment_target=ct.target.iOS16)
    if mil_only:
        prog = ct.convert(traced, convert_to="milinternal", **kw)
        ops = collections.Counter(op.op_type for f in prog.functions.values() for op in f.operations)
        entry["mil_ops"] = dict(ops)
    else:
        ml = ct.convert(traced, convert_to="mlprogram", compute_precision=ct.precision.FLOAT16,
                        compute_units=ct.ComputeUnit.ALL, **kw)
        ml.short_description = f"Harmonia student {kind} (random weights, pilot); see tools/student/student.py"
        path = os.path.join(out_dir, f"Student{kind}.mlpackage")
        ml.save(path)
        entry["package_mb"] = round(sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fs in os.walk(path)
                                        for f in fs) / 1e6, 1)
        try:
            cpu = ct.models.MLModel(path, compute_units=ct.ComputeUnit.CPU_ONLY)
            y = cpu.predict({"spec": x.astype(np.float16)})["mask"].astype(np.float32)
            err = np.sqrt(((y - ref) ** 2).sum() / (ref ** 2).sum())
            entry["cpu_vs_torch_db"] = round(float(20 * np.log10(err + 1e-30)), 1)
            entry["finite"] = bool(np.isfinite(y).all())
        except Exception as e:
            entry["predict_error"] = repr(e)[:400]
    report[kind] = entry
    print(kind, json.dumps(entry), flush=True)
with open(os.path.join(out_dir, "student-check.json"), "w") as f:
    json.dump(report, f, indent=1)
