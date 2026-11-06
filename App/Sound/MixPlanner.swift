import Foundation

/// What the PC found out about a song by listening through it (all times in seconds from the
/// start of the song; anything may be missing):
/// - `bpm`, `beat0`, `conf`: tempo, the time of one beat (the others lie at beat0 + k·60/bpm),
///   and how sure the tempo is (2 or more = usable);
/// - `bodyStart` / `bodyEnd`: where the song proper sets in / the last moment at nearly full level;
/// - `quietStart` / `tailEnd`: where the ending has become faint / where nothing audible is left;
/// - `dur`: the song's length.
public struct MixAnalysis: Equatable {
    public var bpm: Double?
    public var beat0: Double?
    public var conf: Double?
    public var dur: Double?
    public var soundStart: Double?
    public var introStart: Double?
    public var bodyStart: Double?
    public var bodyEnd: Double?
    public var outroStart: Double?
    public var quietStart: Double?
    public var tailEnd: Double?

    public init() {}

    /// From the object the page sends (`mix: { bpm, beat0, ... }`). Anything that is not a
    /// finite number counts as missing.
    public init(_ object: [String: Any]) {
        func number(_ key: String) -> Double? {
            guard let n = object[key] as? NSNumber, n.doubleValue.isFinite else { return nil }
            return n.doubleValue
        }
        bpm = number("bpm")
        beat0 = number("beat0")
        conf = number("conf")
        dur = number("dur")
        soundStart = number("soundStart")
        introStart = number("introStart")
        bodyStart = number("bodyStart")
        bodyEnd = number("bodyEnd")
        outroStart = number("outroStart")
        quietStart = number("quietStart")
        tailEnd = number("tailEnd")
    }
}

/// How the next song (B) comes in over the end of the current one (A).
///
/// The two overlap for `overlap` seconds, beginning when A is at `startA`. B is started
/// `bDelay` seconds after that, from `bOffset` seconds into itself. `end` is where A's own
/// sound ends (the overlap never reaches past it).
public struct MixPlan: Equatable {
    public var startA: Double
    public var overlap: Double
    public var end: Double
    public var bOffset: Double
    public var bDelay: Double
    /// True: beat on beat, equal-power curves, bass changes hands. False: a short touch.
    public var synced: Bool

    public init(startA: Double, overlap: Double, end: Double, bOffset: Double, bDelay: Double, synced: Bool) {
        self.startA = startA
        self.overlap = overlap
        self.end = end
        self.bOffset = bOffset
        self.bDelay = bDelay
        self.synced = synced
    }
}

public enum MixDecision: Equatable {
    case plan(MixPlan)
    /// No mix, and why (the ordinary change of song applies).
    case none(String)
}

/// Decides whether and how two songs are mixed. A pure function of what is known about them;
/// the rules were tuned by ear in the earlier browser version and are kept as they were
/// (Tests/tools/make-mix-fixtures.js holds the same rules in JavaScript; the tests compare).
public enum MixPlanner {
    /// - Parameters:
    ///   - a, b: analysis of the current and the next song (nil = unknown).
    ///   - durationA: A's real length when known, otherwise 0 (the analysis' own figure is used).
    ///   - availableB: how many seconds of B exist, otherwise 0 (the analysis' own figure is used).
    public static func plan(a: MixAnalysis?, b: MixAnalysis?, durationA: Double, availableB: Double, mixOn: Bool) -> MixDecision {
        if !mixOn { return .none("mixing is off") }
        guard let a = a else { return .none("no analysis of the current song") }
        guard let b = b else { return .none("no analysis of the next song") }
        guard let bodyEnd = a.bodyEnd, let tailEnd = a.tailEnd, let quietStart = a.quietStart,
              let bodyStart = b.bodyStart else {
            return .none("analysis incomplete")
        }
        let durA = durationA > 0 ? durationA : (a.dur ?? 0)
        let durB = availableB > 0 ? availableB : (b.dur ?? 0)
        if durA <= 0 || durB <= 0 { return .none("length unknown") }
        /* The analysis was made of a file of another length: its times would not fit. */
        if let stated = a.dur, abs(stated - durA) > 1.5 { return .none("analysis does not fit this file") }
        if durA < 30 { return .none("current song shorter than 30 s") }

        /* A's ending is left to play: A is not gone before its last sound is. */
        let end = min(durA, max(tailEnd, bodyEnd + 0.5))

        /* Beat on beat only when both tempos are sure, they agree (also at double or half),
           and A has no ending of its own after its main part. */
        var synced = false
        if let bpmA = a.bpm, let bpmB = b.bpm, a.beat0 != nil, b.beat0 != nil,
           bpmA > 0, bpmB > 0, (a.conf ?? 0) >= 2, (b.conf ?? 0) >= 2, tailEnd - bodyEnd <= 2 {
            for m in [1.0, 2.0, 0.5] {
                let ratio = bpmA / bpmB * m
                if abs(ratio - 1) <= 0.005 { synced = true }
            }
        }

        var overlap: Double
        var startA: Double
        let bOffset: Double
        let bDelay: Double
        if synced, let bpmA = a.bpm, let bpmB = b.bpm, let beatA = a.beat0, let beatB = b.beat0 {
            let pa = 60 / bpmA
            let pb = 60 / bpmB
            overlap = pa * 16
            while overlap < 4 { overlap *= 2 }
            while overlap > 8 { overlap /= 2 }
            bOffset = max(0, bodyStart - 0.3)
            bDelay = 0
            /* B's first beat at or after its starting point is made to land on a beat of A. */
            let bBeat = beatB + ((bOffset - beatB) / pb).rounded(.up) * pb
            let lead = bBeat - bOffset
            startA = beatA + ((end - overlap + lead - beatA) / pa).rounded(.up) * pa - lead
            /* Earlier by whole beats until the overlap fits before A's end. */
            while startA + overlap > end + 1e-9 { startA -= pa }
        } else {
            /* Songs that do not fit each other only touch: B comes in when A's ending has
               become faint, and B's main part lands in the middle of the overlap. */
            overlap = max(2, min(3, tailEnd - quietStart + 1.5))
            startA = end - overlap
            bOffset = max(0, bodyStart - overlap / 2)
            bDelay = max(0, overlap / 2 - bodyStart)
        }

        if startA < durA * 0.5 { return .none("the mix would begin before the middle of the song") }
        if bOffset + overlap - bDelay > durB { return .none("next song too short") }
        return .plan(MixPlan(startA: startA, overlap: overlap, end: end, bOffset: bOffset, bDelay: bDelay, synced: synced))
    }
}
