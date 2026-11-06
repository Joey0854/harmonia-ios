import Foundation

/// One second-order filter section (direct form II transposed), in double precision.
public struct Biquad {
    public var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    private var z1 = 0.0, z2 = 0.0

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    @inline(__always)
    public mutating func step(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    /// The two "K-weighting" sections of ITU-R BS.1770 for any sample rate (the standard lists
    /// numbers for 48 kHz only; these formulas give those numbers at 48 kHz and are the ones
    /// ffmpeg and libebur128 use).
    public static func kWeighting(sampleRate: Double) -> [Biquad] {
        var f0 = 1681.974450955533
        let gain = 3.999843853973347
        var q = 0.7071752369554196
        var k = tan(Double.pi * f0 / sampleRate)
        let vh = pow(10.0, gain / 20)
        let vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        let shelf = Biquad(b0: (vh + vb * k / q + k * k) / a0,
                           b1: 2 * (k * k - vh) / a0,
                           b2: (vh - vb * k / q + k * k) / a0,
                           a1: 2 * (k * k - 1) / a0,
                           a2: (1 - k / q + k * k) / a0)
        f0 = 38.13547087602444
        q = 0.5003270373238773
        k = tan(Double.pi * f0 / sampleRate)
        a0 = 1 + k / q + k * k
        let highPass = Biquad(b0: 1, b1: -2, b2: 1,
                              a1: 2 * (k * k - 1) / a0,
                              a2: (1 - k / q + k * k) / a0)
        return [shelf, highPass]
    }
}

/// Integrated loudness of a stereo signal as ITU-R BS.1770-4 / EBU R 128 define it:
/// K-weighting, blocks of 400 ms every 100 ms, blocks under −70 LUFS ignored, then blocks more
/// than 10 LU under the average of the rest ignored.
///
/// Feed the song piece by piece with `add`, then ask `integrated`.
public final class LoudnessMeter {
    private var left: [Biquad]
    private var right: [Biquad]
    private let hop: Int
    private var sum = 0.0
    private var count = 0
    /// Mean square (both channels added) of every finished 100 ms stretch.
    private var hops: [Double] = []

    public init(sampleRate: Double) {
        left = Biquad.kWeighting(sampleRate: sampleRate)
        right = left
        hop = max(1, Int((sampleRate / 10).rounded()))
    }

    public func add(left l: [Float], right r: [Float]) {
        let n = min(l.count, r.count)
        var l0 = left[0], l1 = left[1], r0 = right[0], r1 = right[1]
        var sum = self.sum
        var count = self.count
        for i in 0..<n {
            let a = l1.step(l0.step(Double(l[i])))
            let b = r1.step(r0.step(Double(r[i])))
            sum += a * a + b * b
            count += 1
            if count == hop {
                hops.append(sum / Double(hop))
                sum = 0
                count = 0
            }
        }
        left[0] = l0
        left[1] = l1
        right[0] = r0
        right[1] = r1
        self.sum = sum
        self.count = count
    }

    /// Loudness in LUFS, or nil when the signal is too short or too quiet to measure.
    public func integrated() -> Double? {
        if hops.count < 4 { return nil }
        func loudness(_ power: Double) -> Double { return -0.691 + 10 * log10(power) }
        var blocks: [Double] = []
        blocks.reserveCapacity(hops.count)
        for i in 0...(hops.count - 4) {
            blocks.append((hops[i] + hops[i + 1] + hops[i + 2] + hops[i + 3]) / 4)
        }
        let audible = blocks.filter { $0 > 0 && loudness($0) > -70 }
        if audible.isEmpty { return nil }
        let threshold = loudness(audible.reduce(0, +) / Double(audible.count)) - 10
        let kept = audible.filter { loudness($0) > threshold }
        if kept.isEmpty { return nil }
        return loudness(kept.reduce(0, +) / Double(kept.count))
    }
}
