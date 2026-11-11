import Foundation

/*
 The phone's own reading of a car measurement: what kind of sound system the car has, and the
 car settings to use for it. An exact port of classify(), table_of(), val() and the preset table
 (CAR_PARAMS, _track) of the PC's carprobe_analyze.py, thresholds and Chinese wording included,
 so that the phone and the PC always agree. Tests/Fixtures/carprobe_classify.json (made by
 tools/carprobe_fixtures.py from the Python code) holds the answers; CarProbeClassifierTests
 compares every case.

 Input: the positions of one measuring session (position code, levels, quality), as the upload
 has them. Levels may be absolute or relative: each is taken relative to the same position's
 "B1/inphase/0". A cell whose SNR (snrByCell, else the position's snr) is below 10 dB is not
 trusted; when that is the reference, nothing of that position is.
 */

/// One measured (or skipped) position, in the upload's terms.
public struct CarProbePosition {
    public var name: String
    public var skipped: Bool
    /// cell id -> dB
    public var levels: [String: Double]
    /// the whole position's SNR, dB
    public var snr: Double?
    /// cell id -> SNR, dB (used before `snr`)
    public var snrByCell: [String: Double]

    public init(name: String, skipped: Bool = false, levels: [String: Double], snr: Double? = nil,
                snrByCell: [String: Double] = [:]) {
        self.name = name
        self.skipped = skipped
        self.levels = levels
        self.snr = snr
        self.snrByCell = snrByCell
    }

    /// From the upload format { name, skipped, levels, quality: { snr, snrByCell } }; numbers
    /// that are not numbers (or are true / false) are left out, as the Python code does.
    public init(json p: [String: Any]) {
        func number(_ v: Any?) -> Double? {
            guard let n = v as? NSNumber, !CarProbeClassifier.isBool(n), n.doubleValue.isFinite else { return nil }
            return n.doubleValue
        }
        func numbers(_ v: Any?) -> [String: Double] {
            var out: [String: Double] = [:]
            for (k, x) in (v as? [String: Any]) ?? [:] { if let d = number(x) { out[k] = d } }
            return out
        }
        let q = p["quality"] as? [String: Any] ?? [:]
        self.init(name: p["name"] as? String ?? "", skipped: (p["skipped"] as? NSNumber)?.boolValue ?? false,
                  levels: numbers(p["levels"]), snr: number(q["snr"]), snrByCell: numbers(q["snrByCell"]))
    }
}

public enum CarProbeKind: String {
    case plain, bose, rearSplit, manual
}

public struct CarProbeClassification {
    public let kind: CarProbeKind
    /// in Chinese, as the PC writes them into rules.md
    public let reasons: [String]
    /// car settings in the page's carMixSetting().car format (not yet whitelisted; pass them
    /// through CarPresetVerifier.sanitize before use); nil when there is no automatic preset
    public let preset: [String: Any]?
    /// CAR_PARAMS key ("concertHall", "plainStereo") or nil
    public let presetKey: String?
    public var typeName: String { return CarProbeClassifier.typeNames[kind.rawValue] ?? kind.rawValue }
}

public enum CarProbeClassifier {
    public static let reference = "B1/inphase/0"
    public static let cells = ["B1/inphase/0", "B1/inphase/+15", "B1/inphase/-15", "B1/indep/0", "B1/anti/0",
                               "B1/anti/+15", "B2/inphase/0", "B2/anti/0", "LF/inphase/0", "LF/anti/0"]
    /// position code -> (Chinese label, role, side)
    public static let positions: [String: (label: String, role: String, side: String)] = [
        "center": ("中置（擋風玻璃中央）", "center", ""),
        "front-left": ("左前門", "door", "L"),
        "front-right": ("右前門", "door", "R"),
        "rear-left": ("左後門", "door", "L"),
        "rear-right": ("右後門", "door", "R"),
        "rear-window-left": ("左後窗／左後方", "rear", "L"),
        "rear-window-right": ("右後窗／右後方", "rear", "R")
    ]
    public static let snrMin = 10.0
    /* thresholds (dB), from the Mazda3 Bose measurements of 2026-11-10 */
    public static let noUpmixMax = 3.0
    public static let panMin = 6.0
    public static let centerDrop = 3.0
    public static let rearRise = 6.0
    public static let rearSame = 3.0
    public static let rearSplit = 6.0

    public static let typeNames: [String: String] = [
        "plain": "一般立體聲車（無上混）",
        "bose": "Bose 型上混（中置＋門板＋後方包圍）",
        "rearSplit": "新類型：後方分左右，需人工",
        "manual": "無法自動判斷，需人工"
    ]

    static func isBool(_ n: NSNumber) -> Bool {
        return CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID()
    }

    // MARK: presets (CAR_PARAMS)

    private static func track(_ pan: Double, _ send: Double, _ rear: Bool, _ width: Double = 0) -> [String: Any] {
        return ["pan": pan, "send": send, "rear": rear, "width": width]
    }
    private static func params(ambDb: Double) -> [String: Any] {
        return [
            "tracks": ["vocals": track(0, -6, true), "drums": track(-2, -40, true),
                       "bass": track(0, -40, true), "other": track(4, 0, true, 1)] as [String: Any],
            "amb": ["on": true, "rt60": 1.8, "pre": 20.0, "lo": 250.0, "hi": 4000.0, "hf": 1.0, "lowFront": true,
                    "split": 250.0, "style": "decorrelated", "gate": 1.0, "dryGate": false, "db": ambDb] as [String: Any],
            "early": ["on": true, "db": -10.0, "min": 15.0, "max": 30.0] as [String: Any],
            "xover": 150.0
        ]
    }
    /// carprobe_analyze.CAR_PARAMS
    public static let presets: [String: [String: Any]] = [
        "concertHall": params(ambDb: -12),
        "plainStereo": params(ambDb: -15)
    ]
    /// which preset a kind gets (as analyze() drafts it)
    public static func presetKey(for kind: CarProbeKind) -> String? {
        switch kind {
        case .bose: return "concertHall"
        case .plain: return "plainStereo"
        default: return nil
        }
    }

    // MARK: the table (table_of)

    struct Entry {
        let label: String
        let role: String
        let side: String
        /// cell -> dB relative to the reference (nil: not measured or not trusted reference)
        let rel: [String: Double]
        let bad: Set<String>
    }

    static func snr(of p: CarProbePosition, cell: String) -> Double? {
        if let v = p.snrByCell[cell] { return v }
        return p.snr
    }

    /// Measured positions by name (a later position with the same name wins).
    static func table(_ list: [CarProbePosition]) -> [String: Entry] {
        var out: [String: Entry] = [:]
        for p in list where !p.skipped {
            let info = positions[p.name] ?? (p.name, "other", "")
            var bad = Set<String>()
            for c in p.levels.keys {
                if let s = snr(of: p, cell: c), s < snrMin { bad.insert(c) }
            }
            var rel: [String: Double] = [:]
            if let ref = p.levels[reference], !bad.contains(reference) {
                for c in cells { if let v = p.levels[c] { rel[c] = v - ref } }
            }
            out[p.name] = Entry(label: info.label, role: info.role, side: info.side, rel: rel, bad: bad)
        }
        return out
    }

    /// Trusted relative value or nil.
    static func val(_ t: [String: Entry], _ pos: String, _ cell: String) -> Double? {
        guard let e = t[pos], !e.bad.contains(cell) else { return nil }
        return e.rel[cell]
    }

    // MARK: classify

    static func f1(_ v: Double, sign: Bool = true) -> String {
        return String(format: sign ? "%+.1f" : "%.1f", v)
    }
    static func g(_ v: Double) -> String {
        return String(format: "%g", v)
    }

    /// (kind, reasons), exactly as carprobe_analyze.classify().
    static func classify(_ t: [String: Entry]) -> (CarProbeKind, [String]) {
        var why: [String] = []
        let measured = t.keys.filter { t[$0]!.role != "other" }
        if measured.isEmpty {
            return (.manual, ["沒有任何可辨認的位置（位置名稱需用 POSITIONS 裡的名字）"])
        }
        func anti(_ pos: String) -> Double? { return val(t, pos, "B1/anti/0") }

        /* 1. no upmixer */
        var known: [Double] = []
        for n in measured { if let d = anti(n) { known.append(d) } }
        var doorsOk = true
        var doorsChecked = 0
        for n in measured {
            let e = t[n]!
            guard e.role == "door" else { continue }
            guard let l = val(t, n, "B1/inphase/+15"), let r = val(t, n, "B1/inphase/-15") else { continue }
            doorsChecked += 1
            let own = e.side == "L" ? l - r : r - l
            if own < panMin { doorsOk = false }
        }
        if known.count == measured.count && known.allSatisfy({ abs($0) < noUpmixMax }) && doorsChecked > 0 && doorsOk {
            let biggest = known.map { abs($0) }.max() ?? 0
            return (.plain, ["所有位置的中頻反相與同相相差都小於 \(g(noUpmixMax)) dB（最大 \(f1(biggest, sign: false)) dB）",
                             "門板跟著左右擺位（\(doorsChecked) 個門板，自己那一側大至少 \(g(panMin)) dB）"])
        }

        /* rear pair: rear windows / rear satellites if measured, else the rear doors */
        var rl = "rear-window-left", rr = "rear-window-right"
        if !(anti(rl) != nil && anti(rr) != nil) {
            rl = "rear-left"
            rr = "rear-right"
        }
        let al = val(t, rl, "B1/anti/+15"), ar = val(t, rr, "B1/anti/+15")
        let cAnti = anti("center")
        guard let raL = anti(rl), let raR = anti(rr) else {
            return (.manual, ["缺少後方左右兩個位置的中頻反相數值（或訊噪比不足）"])
        }
        let rearUp = raL >= rearRise && raR >= rearRise
        why.append("後方（\(t[rl]!.label)／\(t[rr]!.label)）反相比同相 \(f1(raL))／\(f1(raR)) dB")
        if let al = al, let ar = ar {
            why.append("「反相偏左」時後方左減後方右 = \(f1(al - ar)) dB")
        }
        if let c = cAnti {
            why.append("中置反相比同相 \(f1(c)) dB")
        }

        /* 2. rear split left / right (new) */
        if rearUp, let al = al, let ar = ar, al - ar >= rearSplit {
            return (.rearSplit, why)
        }
        /* 3. Bose-like */
        if rearUp, let c = cAnti, c <= -centerDrop, let al = al, let ar = ar, abs(al - ar) < rearSame {
            return (.bose, why)
        }
        /* 4. other */
        if cAnti == nil { why.append("缺少中置數值（或訊噪比不足）") }
        if al == nil || ar == nil { why.append("缺少後方「反相偏左」數值（或訊噪比不足）") }
        if !rearUp { why.append("後方反相沒有比同相高至少 \(g(rearRise)) dB") }
        return (.manual, why)
    }

    /// The whole reading of one session.
    public static func classify(_ positions: [CarProbePosition]) -> CarProbeClassification {
        let (kind, why) = classify(table(positions))
        let key = presetKey(for: kind)
        return CarProbeClassification(kind: kind, reasons: why, preset: key.flatMap { presets[$0] }, presetKey: key)
    }
}
