import Accelerate
import Foundation

/// Changes the sample rate of a signal without letting through anything above the new upper
/// limit (windowed-sinc filter, one set of weights per fractional position).
///
/// The defaults (32, 0.97, Kaiser 9) are those of ffmpeg's resampler, so the envelope file
/// comes out the same as on the PC. Works on a stream: call `process` for each piece and
/// `finish` once at the end.
public final class Resampler {
    private let p: Int          // output samples ...
    private let q: Int          // ... per this many input samples
    private let half: Int
    private let taps: Int
    private var kernels: [[Float]] = []
    private var buffer: [Float]
    /// Position in the whole input of `buffer[0]`.
    private var bufferStart: Int
    private var totalIn = 0
    private var nextOut = 0

    public init(from source: Int, to target: Int, filterSize: Int = 32, cutoff: Double = 0.97) {
        let g = Resampler.gcd(max(1, source), max(1, target))
        p = max(1, target) / g
        q = max(1, source) / g
        let factor = min(1.0, Double(p) / Double(q) * cutoff)
        half = Int((Double(filterSize) / factor / 2).rounded(.up))
        taps = 2 * half + 1
        let beta = 9.0
        kernels.reserveCapacity(p)
        for phase in 0..<p {
            var k = [Double](repeating: 0, count: taps)
            var sum = 0.0
            for j in 0..<taps {
                let d = Double(j - half) - Double(phase) / Double(p)
                let a = Double.pi * d * factor
                var y = a == 0 ? 1.0 : sin(a) / a
                let w = d / Double(half + 1)
                y *= Resampler.bessel(beta * (max(0, 1 - w * w)).squareRoot())
                k[j] = y
                sum += y
            }
            /* Weights that add up to one: a steady level stays exactly the same level. */
            kernels.append(k.map { Float($0 / sum) })
        }
        buffer = [Float](repeating: 0, count: half)
        bufferStart = -half
    }

    public func process(_ input: [Float]) -> [Float] {
        buffer.append(contentsOf: input)
        totalIn += input.count
        return run(limit: Int.max)
    }

    /// The last few samples, which needed to see the end of the input.
    public func finish() -> [Float] {
        let wanted = totalIn * p / q
        buffer.append(contentsOf: [Float](repeating: 0, count: half + 1))
        return run(limit: wanted)
    }

    private func run(limit: Int) -> [Float] {
        var out: [Float] = []
        let end = bufferStart + buffer.count
        let start = bufferStart
        let half = self.half, taps = self.taps, p = self.p, q = self.q
        var m = nextOut
        buffer.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            while m < limit {
                let i = m * q / p
                if i + half >= end { break }
                let kernel = kernels[(m * q) % p]
                var value: Float = 0
                vDSP_dotpr(base + (i - half - start), 1, kernel, 1, &value, vDSP_Length(taps))
                out.append(value)
                m += 1
            }
        }
        nextOut = m
        /* Forget the input that no later output can need. */
        let keepFrom = m * q / p - half
        let drop = min(max(0, keepFrom - bufferStart), buffer.count)
        if drop > 0 {
            buffer.removeFirst(drop)
            bufferStart += drop
        }
        return out
    }

    /// A whole signal in one go.
    public static func convert(_ input: [Float], from source: Int, to target: Int,
                               filterSize: Int = 32, cutoff: Double = 0.97) -> [Float] {
        if source == target { return input }
        let r = Resampler(from: source, to: target, filterSize: filterSize, cutoff: cutoff)
        var out = r.process(input)
        out.append(contentsOf: r.finish())
        return out
    }

    /// An impulse response for use at another sample rate.
    ///
    /// Besides the change of rate the values are multiplied by source/target: a filter adds up
    /// its taps, and at the lower rate there are fewer taps covering the same stretch of time,
    /// so each must weigh more for the filter to be as loud as before. (Checked by a test that
    /// compares the frequency response before and after.)
    public static func convertImpulseResponse(_ ir: [Float], from source: Int, to target: Int) -> [Float] {
        if source == target { return ir }
        let scale = Float(source) / Float(target)
        return convert(ir, from: source, to: target, filterSize: 64, cutoff: 0.96).map { $0 * scale }
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var x = a, y = b
        while y != 0 { (x, y) = (y, x % y) }
        return x
    }

    /// Modified Bessel function of the first kind, order zero (for the Kaiser window).
    private static func bessel(_ x: Double) -> Double {
        var sum = 1.0, term = 1.0
        let quarter = x * x / 4
        for k in 1..<60 {
            term *= quarter / Double(k * k)
            sum += term
            if term < 1e-12 * sum { break }
        }
        return sum
    }
}
