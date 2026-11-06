import Foundation

/// The song as plain mono samples at 11025 Hz, made from the stereo the decoder delivers (the
/// average of what falls into each output sample). That is plenty for finding the beat.
public struct Mono11k {
    public static let rate = 11025.0

    private let ratio: Double
    private var position = 0.0
    private var edge: Double
    private var sum = 0.0
    public private(set) var samples: [Int16] = []

    public init(sampleRate: Double) {
        ratio = max(1, sampleRate / Mono11k.rate)
        edge = ratio
    }

    public mutating func add(left: [Float], right: [Float]) {
        let n = min(left.count, right.count)
        for i in 0..<n {
            let x = (Double(left[i]) + Double(right[i])) / 2
            var start = position
            let end = position + 1
            while end > edge {
                sum += x * (edge - start)
                emit(sum / ratio)
                start = edge
                edge += ratio
                sum = 0
            }
            sum += x * (end - start)
            position = end
        }
    }

    private mutating func emit(_ value: Double) {
        let v = (value * 32768).rounded(.towardZero)
        samples.append(Int16(max(-32768, min(32767, v))))
    }
}

/// Tempo, first beat and the parts of a song, from its mono 11025 Hz samples. The same method as
/// the PC server used (`analysePcm`), so what the PC used to say about a song is now found on the
/// phone: the tempo and where the beats sit, how sure that is, and where the song proper starts,
/// where its main part stops, where the ending has become faint and where nothing is left.
public enum MixAnalyzer {
    private static func round(_ x: Double, _ places: Double) -> Double {
        let k = pow(10, places)
        return (x * k).rounded() / k
    }

    /// Nil for a song shorter than 20 s.
    public static func analyze(_ x: [Int16]) -> MixAnalysis? {
        let sr = Mono11k.rate
        let hop = 64
        let fps = sr / Double(hop)
        let n = x.count / hop
        guard x.count >= Int(sr) * 20, n > 8 else { return nil }

        /* energy of each short step, for the whole signal and for the bass alone */
        var eFull = [Double](repeating: 0, count: n)
        var eLow = [Double](repeating: 0, count: n)
        let a = exp(-2 * Double.pi * 180 / sr)
        var lp = 0.0
        for i in 0..<n {
            var f = 0.0, l = 0.0
            for j in 0..<hop {
                let v = Double(x[i * hop + j]) / 32768
                lp = lp * a + v * (1 - a)
                f += v * v
                l += lp * lp
            }
            eFull[i] = f
            eLow[i] = l
        }

        /* "something just started here": how much louder each step is than a moment before */
        let win = 4
        var on = [Double](repeating: 0, count: n)
        var wf = 0.0, wl = 0.0
        var sf = [Double](repeating: 0, count: n)
        var sl = [Double](repeating: 0, count: n)
        for i in 0..<n {
            wf += eFull[i]
            wl += eLow[i]
            if i >= win {
                wf -= eFull[i - win]
                wl -= eLow[i - win]
            }
            sf[i] = log(1e-6 + wf)
            sl[i] = log(1e-7 + wl)
        }
        for i in 2..<n {
            on[i] = max(0, sf[i] - sf[i - 2]) * 0.5 + max(0, sl[i] - sl[i - 2])
        }

        /* remove the slowly changing part, so loud passages do not outweigh quiet ones */
        let half = Int((fps * 0.4).rounded())
        var flat = [Double](repeating: 0, count: n)
        var run = 0.0
        for i in 0..<n {
            run += on[i]
            if i >= 2 * half { run -= on[i - 2 * half] }
            let c = i - half
            if c >= 0 { flat[c] = max(0, on[c] - run / Double(min(i + 1, 2 * half))) }
        }

        let from = Int((Double(n) * 0.15).rounded(.down))
        let to = Int((Double(n) * 0.85).rounded(.down))

        /* rough tempo: which delay makes the pattern line up with itself best */
        var bestLag = 0
        var bestAc = -1.0
        let lagMin = Int((fps * 60 / 185).rounded(.down))
        let lagMax = Int((fps * 60 / 70).rounded(.up))
        if lagMin >= 1 && lagMax >= lagMin {
            for lag in lagMin...lagMax {
                var ac = 0.0
                var i = from
                while i + 2 * lag < to {
                    ac += flat[i] * (flat[i + lag] + 0.5 * flat[i + 2 * lag])
                    i += 2
                }
                let bpm = fps * 60 / Double(lag)
                let lg = log2(bpm / 122) / 0.55
                ac *= exp(-0.5 * lg * lg)
                if ac > bestAc {
                    bestAc = ac
                    bestLag = lag
                }
            }
        }
        guard bestLag > 0 else { return nil }
        let rough = fps * 60 / Double(bestLag)

        /* exact tempo and where the beats sit: a regular grid laid over the song */
        func at(_ pos: Double) -> Double {
            let i = Int(pos.rounded(.down))
            if i < 0 || i + 1 >= n { return 0 }
            let fr = pos - Double(i)
            return flat[i] * (1 - fr) + flat[i + 1] * fr
        }
        var bestScore = -1.0
        var bestBpm = rough
        var bestPhase = 0.0
        var meanAtBest = 1.0
        var bpm = rough * 0.965
        while bpm <= rough * 1.035 {
            let period = fps * 60 / bpm
            var sum = 0.0, top = -1.0, topPhase = 0.0, count = 0.0
            var ph = 0.0
            while ph < period {
                var sc = 0.0
                var pos = Double(from) + ph
                while pos < Double(to) {
                    sc += at(pos)
                    pos += period
                }
                sum += sc
                count += 1
                if sc > top {
                    top = sc
                    topPhase = ph
                }
                ph += 1
            }
            if top > bestScore {
                bestScore = top
                bestBpm = bpm
                bestPhase = fmod(Double(from) + topPhase, period)
                meanAtBest = sum / count
            }
            bpm += 0.05
        }
        let period = fps * 60 / bestBpm

        /* loudness over time, to find the parts of the song */
        let block = Int((fps * 0.5).rounded())
        var db: [Double] = []
        var at0 = 0
        while at0 + block <= n {
            var e = 0.0
            for j in 0..<block { e += eFull[at0 + j] }
            db.append(10 * log10(1e-9 + e / Double(block * hop)))
            at0 += block
        }
        guard !db.isEmpty else { return nil }
        let sorted = db.sorted()
        let pick = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.85).rounded(.down)))]
        let level = pick == 0 ? -30 : pick
        let m = db.count - 1
        var last = m
        while last > 0 && db[last] < level - 12 { last -= 1 }
        var full = m
        while full > 0 && db[full] < level - 6 { full -= 1 }
        var quiet = m
        while quiet > 0 && db[quiet] < level - 24 { quiet -= 1 }
        var tail = m
        while tail > 0 && db[tail] < level - 38 { tail -= 1 }
        var first = 0
        while first < m && db[first] < level - 25 { first += 1 }
        var sound = 0
        while sound < m && db[sound] < level - 48 { sound += 1 }
        var body = 0
        while body < m && db[body] < level - 16 { body += 1 }
        /* a long soft opening (more than 20 s) is part of the song and is not skipped */
        if Double(body) * 0.5 > 20 { body = Double(first) * 0.5 > 20 ? sound : first }

        let dur = Double(x.count) / sr
        var result = MixAnalysis()
        result.bpm = round(bestBpm, 2)
        result.beat0 = round(fmod(bestPhase, period) / fps, 3)
        result.conf = round(bestScore / max(1e-9, meanAtBest), 2)
        result.dur = round(dur, 2)
        result.introStart = round(Double(first) * 0.5, 1)
        result.soundStart = round(Double(sound) * 0.5, 1)
        result.bodyStart = round(Double(body) * 0.5, 1)
        result.bodyEnd = round(min(dur, Double(full + 1) * 0.5), 1)
        result.outroStart = round(min(dur, Double(last + 1) * 0.5), 1)
        result.quietStart = round(min(dur, Double(quiet + 1) * 0.5), 1)
        result.tailEnd = round(min(dur, Double(tail + 1) * 0.5), 1)
        return result
    }
}
