import Foundation

/// How loud a song is, a tenth of a second at a time (the root mean square of each tenth).
public struct LevelTrack {
    public static let frameSeconds = 0.1

    private let frameLength: Int
    private var count = 0
    private var sum = 0.0
    private var levels: [Float] = []

    public init(sampleRate: Double) {
        frameLength = max(1, Int((sampleRate * LevelTrack.frameSeconds).rounded()))
    }

    public mutating func add(left: [Float], right: [Float]) {
        let n = min(left.count, right.count)
        for i in 0..<n {
            let x = (Double(left[i]) + Double(right[i])) / 2
            sum += x * x
            count += 1
            if count == frameLength {
                levels.append(Float((sum / Double(count)).squareRoot()))
                count = 0
                sum = 0
            }
        }
    }

    public func finish() -> [Float] {
        var out = levels
        if count > frameLength / 2 { out.append(Float((sum / Double(count)).squareRoot())) }
        return out
    }
}

/// Where the parts of a song are, found from its loudness alone: where the sound starts, where
/// the main part starts and ends, where the ending has become faint and where the last sound is.
/// That is enough for the planner to let one song come in over the end of another. (No tempo is
/// found, so such mixes are never beat-matched; a PC that knows the tempo can still say so.)
public enum MixStructure {
    /// `levels`: root mean square per `frameSeconds`. Nil when the song is silent or too short.
    public static func analyze(levels: [Float], frameSeconds: Double = LevelTrack.frameSeconds) -> MixAnalysis? {
        let n = levels.count
        guard n >= 10 else { return nil }
        /* decibels, smoothed over half a second */
        let db = levels.map { 20 * log10(Double(max($0, 1e-6))) }
        let w = 5
        var smooth = [Double](repeating: -120, count: n)
        for i in 0..<n {
            let a = max(0, i - w / 2), b = min(n - 1, i + w / 2)
            var s = 0.0
            for j in a...b { s += db[j] }
            smooth[i] = s / Double(b - a + 1)
        }
        let audible = smooth.filter { $0 > -70 }.sorted()
        guard audible.count >= 10 else { return nil }
        let reference = audible[min(audible.count - 1, Int(Double(audible.count - 1) * 0.9))]
        let bodyLevel = reference - 6
        let quietLevel = reference - 18
        let soundLevel = max(reference - 40, -70)

        guard let first = smooth.firstIndex(where: { $0 > soundLevel }),
              let last = smooth.lastIndex(where: { $0 > soundLevel }) else { return nil }

        /* runs of at least two seconds at the main level */
        let need = max(1, Int((2.0 / frameSeconds).rounded()))
        var bodyFirst: Int?
        var bodyLast: Int?
        var i = 0
        while i < n {
            if smooth[i] >= bodyLevel {
                var j = i
                while j + 1 < n && smooth[j + 1] >= bodyLevel { j += 1 }
                if j - i + 1 >= need {
                    if bodyFirst == nil { bodyFirst = i }
                    bodyLast = j
                }
                i = j + 1
            } else {
                i += 1
            }
        }
        guard let bf = bodyFirst, let bl = bodyLast else { return nil }

        let bodyEnd = Double(bl + 1) * frameSeconds
        var quiet = last
        if bl + 1 <= last {
            for k in (bl + 1)...last where smooth[k] < quietLevel { quiet = k; break }
        }
        var result = MixAnalysis()
        result.dur = Double(n) * frameSeconds
        result.soundStart = Double(first) * frameSeconds
        result.introStart = result.soundStart
        result.bodyStart = Double(bf) * frameSeconds
        result.bodyEnd = bodyEnd
        result.outroStart = bodyEnd
        result.quietStart = Double(quiet) * frameSeconds
        result.tailEnd = Double(last + 1) * frameSeconds
        return result
    }
}
