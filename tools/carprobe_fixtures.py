"""Writes Tests/Fixtures/carprobe_classify.json: cases for the phone's car classification
(App/Sound/CarProbeClassifier.swift), with the answers of the PC's carprobe_analyze.py.

  python tools/carprobe_fixtures.py [--analyze <folder with carprobe_analyze.py>]

The folder defaults to the environment variable CARPROBE_ANALYZE_DIR, else C:\\Tools\\HarmoniaReport.
Each case is {name, meta: {positions: [...]}, kind, typeName, reasons, preset}: meta in the upload
format (name, skipped, levels, quality {snr, snrByCell}); preset is the car settings the PC would
draft (CAR_PARAMS) or null. CarProbeClassifierTests must give the same kind, reasons and preset.
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "Tests", "Fixtures", "carprobe_classify.json")

CELLS = ["B1/inphase/0", "B1/inphase/+15", "B1/inphase/-15", "B1/indep/0", "B1/anti/0", "B1/anti/+15",
         "B2/inphase/0", "B2/anti/0", "LF/inphase/0", "LF/anti/0"]


def pos(name, ref=0.0, snr=30.0, by=None, skipped=False, drop=(), **rel):
    """One position; rel: cell (with / as _, + as p, - as m) -> dB relative to the reference."""
    levels = {}
    for c in CELLS:
        key = c.replace("/", "_").replace("+", "p").replace("-", "m")
        if c == "B1/inphase/0":
            levels[c] = ref
        else:
            levels[c] = ref + rel.get(key, 0.0)
    for c in drop:
        levels.pop(c, None)
    q = {}
    if snr is not None:
        q["snr"] = snr
    if by is not None:
        q["snrByCell"] = by
    p = {"name": name, "skipped": skipped, "levels": {} if skipped else levels, "quality": q}
    return p


def door(name, side, **kw):
    """A door that follows panning: own side +6 ... -6 (12 dB apart by default)."""
    own, other = kw.pop("own", 6.0), kw.pop("other", -6.0)
    if side == "L":
        kw.setdefault("B1_inphase_p15", own)
        kw.setdefault("B1_inphase_m15", other)
    else:
        kw.setdefault("B1_inphase_p15", other)
        kw.setdefault("B1_inphase_m15", own)
    return pos(name, **kw)


def bose_car(center_anti=-8.0, rear_l=9.0, rear_r=8.5, al=4.0, ar=3.0, rear="rear-window", **extra):
    """Mazda 3 Bose like: centre drops for anti, rear rises for anti, rear does not split."""
    ps = [pos("center", B1_anti_0=center_anti, B1_anti_p15=center_anti - 1, LF_anti_0=-18.0),
          door("front-left", "L", B1_anti_0=-1.0), door("front-right", "R", B1_anti_0=-1.5),
          door("rear-left", "L", B1_anti_0=1.0), door("rear-right", "R", B1_anti_0=0.5),
          pos(rear + "-left", B1_anti_0=rear_l, B1_anti_p15=al),
          pos(rear + "-right", B1_anti_0=rear_r, B1_anti_p15=ar)]
    if rear == "rear-door":
        # no rear windows measured: the rear doors take the rear role
        ps = ps[:3] + [door("rear-left", "L", B1_anti_0=rear_l, B1_anti_p15=al),
                       door("rear-right", "R", B1_anti_0=rear_r, B1_anti_p15=ar)]
    return ps


def plain_car(max_diff=1.0, own=6.0, other=-6.0, ref=0.0):
    return [pos("center", ref=ref, B1_anti_0=-max_diff * 0.5),
            door("front-left", "L", ref=ref, own=own, other=other, B1_anti_0=max_diff),
            door("front-right", "R", ref=ref, own=own, other=other, B1_anti_0=-0.5),
            door("rear-left", "L", ref=ref, own=own, other=other, B1_anti_0=0.2),
            door("rear-right", "R", ref=ref, own=own, other=other, B1_anti_0=-0.3)]


def cases():
    out = []

    def add(name, positions):
        out.append({"name": name, "meta": {"positions": positions}})

    add("bose: Mazda 3 like", bose_car())
    add("bose: rear doors when no rear windows", bose_car(rear="rear-door"))
    add("plain: no upmixer", plain_car())
    add("plain: absolute dBFS levels", plain_car(ref=-41.37))
    add("rearSplit: rear left louder for anti left", bose_car(al=10.0, ar=2.0))
    add("manual: rear does not rise, centre drops", bose_car(rear_l=2.0, rear_r=1.0))
    add("manual: no positions", [])
    add("manual: only unknown positions", [pos("front-left-tweeter"), pos("rear-center"), pos("other")])
    add("manual: everything skipped", [pos("center", skipped=True), pos("front-left", skipped=True)])
    add("manual: no rear positions", [pos("center", B1_anti_0=-8.0), door("front-left", "L", B1_anti_0=5.0),
                                       door("front-right", "R", B1_anti_0=5.0)])
    add("manual: centre missing", [p for p in bose_car() if p["name"] != "center"])
    add("manual: rear anti+15 missing", [dict(p, levels={k: v for k, v in p["levels"].items() if k != "B1/anti/+15"})
                                         if p["name"].startswith("rear-window") else p for p in bose_car()])
    # low SNR
    low_rw = []
    for p in bose_car():
        if p["name"] == "rear-window-left":
            p = dict(p, quality={"snr": 30.0, "snrByCell": {"B1/anti/0": 5.0}})
        low_rw.append(p)
    add("low SNR: rear window anti cell untrusted -> rear doors", low_rw)
    low_ref = []
    for p in bose_car():
        if p["name"] == "center":
            p = dict(p, quality={"snr": 8.0})
        low_ref.append(p)
    add("low SNR: whole centre below 10 dB (reference untrusted)", low_ref)
    by_over = []
    for p in bose_car():
        if p["name"] == "center":
            p = dict(p, quality={"snr": 4.0, "snrByCell": {"B1/inphase/0": 25.0, "B1/anti/0": 25.0}})
        by_over.append(p)
    add("low SNR: snrByCell overrides a low snr", by_over)
    no_q = []
    for p in bose_car():
        no_q.append(dict(p, quality={}))
    add("no quality at all (trusted)", no_q)
    snr_exact = []
    for p in bose_car():
        if p["name"] == "center":
            p = dict(p, quality={"snr": 10.0})
        snr_exact.append(p)
    add("borderline SNR exactly 10 dB (trusted)", snr_exact)
    # borderlines
    add("borderline NO_UPMIX below (2.99)", plain_car(max_diff=2.99))
    add("borderline NO_UPMIX at (3.0)", plain_car(max_diff=3.0))
    add("borderline NO_UPMIX negative at (-3.0)", plain_car(max_diff=-3.0))
    add("borderline PAN_MIN at (6.0)", plain_car(own=3.0, other=-3.0))
    add("borderline PAN_MIN below (5.99)", plain_car(own=3.0, other=-2.99))
    add("borderline REAR_RISE at (6.0)", bose_car(rear_l=6.0, rear_r=6.0))
    add("borderline REAR_RISE below (5.99)", bose_car(rear_l=6.0, rear_r=5.99))
    add("borderline REAR_SPLIT at (6.0)", bose_car(al=7.0, ar=1.0))
    add("borderline REAR_SPLIT below (5.99)", bose_car(al=6.99, ar=1.0))
    add("borderline CENTER_DROP at (-3.0)", bose_car(center_anti=-3.0))
    add("borderline CENTER_DROP above (-2.99)", bose_car(center_anti=-2.99))
    add("borderline REAR_SAME below (2.99)", bose_car(al=3.99, ar=1.0))
    add("borderline REAR_SAME at (3.0)", bose_car(al=4.0, ar=1.0))
    add("borderline REAR_SAME negative side (-2.99)", bose_car(al=1.0, ar=3.99))
    # no door pan cells: plain needs at least one checked door
    no_pan = [dict(p, levels={k: v for k, v in p["levels"].items() if k not in ("B1/inphase/+15", "B1/inphase/-15")})
              for p in plain_car()]
    add("not plain: no door has the pan cells", no_pan)
    # a later position with the same name wins
    dup = bose_car() + [pos("rear-window-left", B1_anti_0=1.0, B1_anti_p15=1.0)]
    add("duplicate position: the later one wins", dup)
    add("absolute dBFS bose", [dict(p, levels={k: v - 37.25 for k, v in p["levels"].items()}) for p in bose_car()])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--analyze", default=os.environ.get("CARPROBE_ANALYZE_DIR", r"C:\Tools\HarmoniaReport"))
    ap.add_argument("--out", default=OUT)
    a = ap.parse_args()
    sys.path.insert(0, a.analyze)
    import carprobe_analyze as ca  # noqa: E402

    result = []
    for c in cases():
        t = ca.table_of(c["meta"])
        kind, why = ca.classify(t)
        params = {"bose": "concertHall", "plain": "plainStereo"}.get(kind)
        c.update({"kind": kind, "typeName": ca.TYPES[kind], "reasons": why,
                  "preset": json.loads(json.dumps(ca.CAR_PARAMS[params])) if params else None})
        result.append(c)
    kinds = sorted({c["kind"] for c in result})
    doc = {"source": "carprobe_analyze.py classify() + CAR_PARAMS", "thresholds": {
        "SNR_MIN": ca.SNR_MIN, "NO_UPMIX_MAX": ca.NO_UPMIX_MAX, "PAN_MIN": ca.PAN_MIN, "CENTER_DROP": ca.CENTER_DROP,
        "REAR_RISE": ca.REAR_RISE, "REAR_SAME": ca.REAR_SAME, "REAR_SPLIT": ca.REAR_SPLIT},
        "types": ca.TYPES, "cases": result}
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "w", encoding="utf-8", newline="\n") as f:
        json.dump(doc, f, ensure_ascii=False, indent=1, allow_nan=False)
        f.write("\n")
    counts = ", ".join(f"{k} {sum(1 for c in result if c['kind'] == k)}" for k in kinds)
    print(f"{len(result)} cases ({counts}) -> {a.out}")


if __name__ == "__main__":
    main()
