import Foundation

public extension Biquad {
    /// A second-order (12 dB per octave) low-pass.
    static func lowPass(frequency: Double, q: Double = 0.7071067811865476, sampleRate: Double) -> Biquad {
        let w = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w) / (2 * q)
        let c = cos(w)
        let a0 = 1 + alpha
        return Biquad(b0: (1 - c) / 2 / a0, b1: (1 - c) / a0, b2: (1 - c) / 2 / a0,
                      a1: -2 * c / a0, a2: (1 - alpha) / a0)
    }
}

/// What the car's ambient light follows, for one song: fifty times a second, how strong the
/// bass (40 - 150 Hz) and the upper range (above 1 kHz) are, and how sharply the sound has just
/// risen (onset). Made once from the decoded song (`LightEnvelopeMaker`), kept in a small file,
/// and looked up by play position while the song is heard.
///
/// Each of the three is also given a reference level for this song (the 95th percentile of its
/// audible frames), so that quietly and loudly mastered songs both use the light's full range.
public struct LightEnvelope: Equatable {
    public static let framesPerSecond = 50.0

    public var bass: [Float]
    public var mid: [Float]
    public var onset: [Float]
    public var bassRef: Float
    public var midRef: Float
    public var onsetRef: Float

    public init(bass: [Float], mid: [Float], onset: [Float], bassRef: Float, midRef: Float, onsetRef: Float) {
        self.bass = bass
        self.mid = mid
        self.onset = onset
        self.bassRef = bassRef
        self.midRef = midRef
        self.onsetRef = onsetRef
    }

    public var duration: Double { return Double(bass.count) / LightEnvelope.framesPerSecond }

    /// The three values at a time in the song, each divided by its reference (so about 0...1,
    /// a little above 1 at the loudest moments). Between frames the values are interpolated;
    /// before the start and after the end everything is 0.
    public func sample(at seconds: Double) -> (bass: Double, mid: Double, onset: Double) {
        let count = bass.count
        if count == 0 || seconds < 0 { return (0, 0, 0) }
        let x = seconds * LightEnvelope.framesPerSecond
        let i = Int(x.rounded(.down))
        if i >= count { return (0, 0, 0) }
        let j = min(i + 1, count - 1)
        let f = Float(x - Double(i))
        func at(_ a: [Float], _ ref: Float) -> Double {
            let v = a[i] + (a[j] - a[i]) * f
            return ref > 0 ? Double(v / ref) : 0
        }
        return (at(bass, bassRef), at(mid, midRef), at(onset, onsetRef))
    }

    /// Loud sections (choruses, drops): for each frame, whether the song's long-term energy
    /// (bass and upper range, each normalised, averaged over `window` seconds centred on the
    /// frame) is above its 75th percentile over the whole song.
    public func sections(window: Double = 8) -> [Bool] {
        let n = bass.count
        if n == 0 { return [] }
        var energy = [Double](repeating: 0, count: n)
        for k in 0..<n {
            let b = bassRef > 0 ? Double(bass[k] / bassRef) : 0
            let m = (midRef > 0 && k < mid.count) ? Double(mid[k] / midRef) : 0
            energy[k] = b + m
        }
        /* centred moving average through a running sum */
        let half = max(1, Int(window * LightEnvelope.framesPerSecond / 2))
        var prefix = [Double](repeating: 0, count: n + 1)
        for k in 0..<n { prefix[k + 1] = prefix[k] + energy[k] }
        var smooth = [Double](repeating: 0, count: n)
        for k in 0..<n {
            let a = max(0, k - half), b = min(n, k + half + 1)
            smooth[k] = (prefix[b] - prefix[a]) / Double(b - a)
        }
        let sorted = smooth.sorted()
        let threshold = sorted[min(n - 1, Int((Double(n - 1) * 0.75).rounded()))]
        return smooth.map { $0 > threshold }
    }

    // MARK: file

    private static let magic: UInt32 = 0x4C454E31   // "LEN1"

    /// The envelope as bytes: a header, then the three values of each frame side by side.
    public func data() -> Data {
        var words: [UInt32] = [LightEnvelope.magic, UInt32(bass.count),
                               bassRef.bitPattern, midRef.bitPattern, onsetRef.bitPattern]
        for k in 0..<bass.count {
            words.append(bass[k].bitPattern)
            words.append(k < mid.count ? mid[k].bitPattern : 0)
            words.append(k < onset.count ? onset[k].bitPattern : 0)
        }
        var out = Data(capacity: words.count * 4)
        for w in words {
            var little = w.littleEndian
            withUnsafeBytes(of: &little) { out.append(contentsOf: $0) }
        }
        return out
    }

    public init?(data: Data) {
        let bytes = [UInt8](data)
        func word(_ k: Int) -> UInt32 {
            let o = k * 4
            let a = UInt32(bytes[o]) | (UInt32(bytes[o + 1]) << 8)
            return a | (UInt32(bytes[o + 2]) << 16) | (UInt32(bytes[o + 3]) << 24)
        }
        guard bytes.count >= 20, word(0) == LightEnvelope.magic else { return nil }
        let count = Int(word(1))
        guard count >= 0, bytes.count >= 20 + count * 12 else { return nil }
        bassRef = Float(bitPattern: word(2))
        midRef = Float(bitPattern: word(3))
        onsetRef = Float(bitPattern: word(4))
        var b = [Float](repeating: 0, count: count)
        var m = [Float](repeating: 0, count: count)
        var o = [Float](repeating: 0, count: count)
        for k in 0..<count {
            b[k] = Float(bitPattern: word(5 + k * 3))
            m[k] = Float(bitPattern: word(6 + k * 3))
            o[k] = Float(bitPattern: word(7 + k * 3))
        }
        bass = b
        mid = m
        onset = o
    }
}

/// Makes a `LightEnvelope` from a song, piece by piece.
public final class LightEnvelopeMaker {
    private var bassHigh: Biquad
    private var bassLow: Biquad
    private var midHigh: Biquad
    private let frameLength: Int
    private var count = 0
    private var bassSum = 0.0
    private var midSum = 0.0
    private var allSum = 0.0
    private var bass: [Float] = []
    private var mid: [Float] = []
    private var onset: [Float] = []
    private var recent: [Double] = []

    public init(sampleRate: Double) {
        bassHigh = Biquad.highPass(frequency: 40, sampleRate: sampleRate)
        bassLow = Biquad.lowPass(frequency: 150, sampleRate: sampleRate)
        midHigh = Biquad.highPass(frequency: 1000, sampleRate: sampleRate)
        frameLength = max(1, Int((sampleRate / LightEnvelope.framesPerSecond).rounded()))
    }

    public func add(left: [Float], right: [Float]) {
        let n = min(left.count, right.count)
        var bh = bassHigh, bl = bassLow, mh = midHigh
        for i in 0..<n {
            let x = (Double(left[i]) + Double(right[i])) / 2
            let b = bl.step(bh.step(x))
            let m = mh.step(x)
            bassSum += b * b
            midSum += m * m
            allSum += x * x
            count += 1
            if count == frameLength { closeFrame() }
        }
        bassHigh = bh
        bassLow = bl
        midHigh = mh
    }

    private func closeFrame() {
        let n = Double(max(1, count))
        bass.append(Float((bassSum / n).squareRoot()))
        mid.append(Float((midSum / n).squareRoot()))
        /* Onset: how far the loudness of this frame is above that of the few frames before. */
        let level = log10(allSum / n + 1e-10)
        let before = recent.isEmpty ? level : recent.reduce(0, +) / Double(recent.count)
        onset.append(Float(max(0, level - before)))
        recent.append(level)
        if recent.count > 4 { recent.removeFirst() }
        count = 0
        bassSum = 0
        midSum = 0
        allSum = 0
    }

    public func finish() -> LightEnvelope {
        if count > frameLength / 2 { closeFrame() }
        return LightEnvelope(bass: bass, mid: mid, onset: onset,
                             bassRef: LightEnvelopeMaker.reference(bass),
                             midRef: LightEnvelopeMaker.reference(mid),
                             onsetRef: max(0.05, LightEnvelopeMaker.reference(onset)))
    }

    /// The 95th percentile of the frames that are not silent; 0 when there are none.
    public static func reference(_ values: [Float]) -> Float {
        let audible = values.filter { $0 > 1e-4 }.sorted()
        if audible.isEmpty { return 0 }
        let at = min(audible.count - 1, Int((Double(audible.count - 1) * 0.95).rounded()))
        return audible[at]
    }
}

/// Which songs are heard right now, and how much of each, for the light: the current song, and
/// during a mix also the incoming one, each weighted by its level on the mix curves.
public enum LightTiming {
    public struct Voice: Equatable {
        public let id: String
        public let position: Double
        public let weight: Double

        public init(id: String, position: Double, weight: Double) {
            self.id = id
            self.position = position
            self.weight = weight
        }
    }

    /// Where in the song the listener is: the player's position when it was read, plus the time
    /// since (while playing), minus the way to the loudspeaker (output latency) and the user's
    /// offset (positive = the light later).
    public static func heardPosition(reported: Double, elapsed: Double, playing: Bool, latency: Double, offsetMs: Double) -> Double {
        let now = reported + (playing ? max(0, elapsed) : 0)
        return now - max(0, latency) - offsetMs / 1000
    }

    /// `position` is where the current song is. With a mix under way (`plan`, `incoming`),
    /// the incoming song's position follows from it the same way the engine lines the two up.
    public static func voices(current: String, position: Double, plan: MixPlan?, incoming: String?) -> [Voice] {
        guard let plan = plan, let incoming = incoming, plan.overlap > 0 else {
            return [Voice(id: current, position: position, weight: 1)]
        }
        let x = (position - plan.startA) / plan.overlap
        let outgoing = MixCurve.outgoingGain(x)
        var list = [Voice(id: current, position: position, weight: outgoing)]
        let offset = position - plan.startA - plan.bDelay
        if offset >= 0 {
            list.append(Voice(id: incoming, position: plan.bOffset + offset, weight: MixCurve.incomingGain(x, synced: plan.synced)))
        }
        return list.filter { $0.weight > 0.001 }
    }

    /// The light's values for several songs at once: an average weighted by their levels.
    public static func combine(_ parts: [(values: (bass: Double, mid: Double, onset: Double), weight: Double)]) -> (bass: Double, mid: Double, onset: Double) {
        var total = 0.0, b = 0.0, m = 0.0, o = 0.0
        for p in parts where p.weight > 0 {
            total += p.weight
            b += p.values.bass * p.weight
            m += p.values.mid * p.weight
            o += p.values.onset * p.weight
        }
        if total <= 0 { return (0, 0, 0) }
        return (b / total, m / total, o / total)
    }
}
