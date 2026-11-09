import Accelerate
import Foundation

/// Splits a stereo recording into five rough sources, by how each frequency bin is shared
/// between the two channels:
///
/// - 0 `low`: everything below 100 Hz (none above 160 Hz, a cos² fade between);
/// - 1 `center`: what both channels share and is panned to the middle (lead vocal, kick, bass);
/// - 2 `sideL`, 3 `sideR`: what both channels share but leans left / right;
/// - 4 `ambience`: what the channels do not share (reverb, wide pads, crowd).
///
/// Every source stays stereo (left, right) and the five add up to the input exactly (up to
/// rounding), so a stage that leaves each source where it was gives back the original.
///
/// Method: short-time Fourier transform, 2048 points, Hann window for analysis and synthesis,
/// hop 512 (75 % overlap; the squared windows add up to 1.5, which the output is divided by).
/// Per bin the covariance of the two channels (|L|², |R|², L·R*) is averaged over time (0.8
/// per frame) and over the bin and its two neighbours. The smaller eigenvalue of that 2×2
/// matrix is the part the channels do not share; sqrt(its share of each channel's power) is
/// the ambience mask for that channel. The rest is panned by (|R|² − |L|²) / (shared power) and
/// goes to `center` with the weight exp(−(pan / 0.18)²), the remainder to `sideL` or `sideR`.
///
/// The transform's delay is taken care of inside: output sample n belongs to input sample n.
/// Output comes in steps of 512 samples (the first ones a little later); `flush` returns the
/// rest. Not thread-safe: use one instance from one queue; do not use it after `flush`.
public final class StageSplitter {
    public static let sourceNames = ["low", "center", "sideL", "sideR", "ambience"]
    public static let sourceCount = 5
    public static let fftSize = 2048
    public static let hop = 512

    private let n = StageSplitter.fftSize
    private let hop = StageSplitter.hop
    private let bins = StageSplitter.fftSize / 2 + 1
    private let log2n: vDSP_Length = 11
    private let setup: FFTSetup

    private var window: [Float]
    private var lowWeight: [Float]
    /* Covariance averaged over time, per bin. */
    private var powerLeft: [Float]
    private var powerRight: [Float]
    private var crossRe: [Float]
    private var crossIm: [Float]
    /* The last fftSize input samples; new ones are written from fftSize - hop on. */
    private var frameLeft: [Float]
    private var frameRight: [Float]
    /* Overlap-add per source and channel: index (source * 2 + channel) * fftSize. */
    private var acc: [Float]
    /* Masks per source and channel: index (source * 2 + channel) * bins. */
    private var masks: [Float]
    private var specLRe: [Float]
    private var specLIm: [Float]
    private var specRRe: [Float]
    private var specRIm: [Float]
    /* Work space for one transform. */
    private let inRe: UnsafeMutablePointer<Float>
    private let inIm: UnsafeMutablePointer<Float>
    private let outRe: UnsafeMutablePointer<Float>
    private let outIm: UnsafeMutablePointer<Float>

    private var pending = 0
    /* Output samples that belong before input sample 0 and are dropped. */
    private var skip: Int
    private var fed = 0
    private var given = 0

    public init(sampleRate: Int) {
        let size = StageSplitter.fftSize
        let half = size / 2 + 1
        setup = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2))!
        window = (0..<size).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(size))) }
        lowWeight = (0..<half).map { (k: Int) -> Float in
            let f = Double(k) * Double(max(1, sampleRate)) / Double(size)
            if f <= 100 { return 1 }
            if f >= 160 { return 0 }
            let c = cos((f - 100) / 60 * Double.pi / 2)
            return Float(c * c)
        }
        powerLeft = [Float](repeating: 0, count: half)
        powerRight = [Float](repeating: 0, count: half)
        crossRe = [Float](repeating: 0, count: half)
        crossIm = [Float](repeating: 0, count: half)
        frameLeft = [Float](repeating: 0, count: size)
        frameRight = [Float](repeating: 0, count: size)
        acc = [Float](repeating: 0, count: StageSplitter.sourceCount * 2 * size)
        masks = [Float](repeating: 0, count: StageSplitter.sourceCount * 2 * half)
        specLRe = [Float](repeating: 0, count: half)
        specLIm = [Float](repeating: 0, count: half)
        specRRe = [Float](repeating: 0, count: half)
        specRIm = [Float](repeating: 0, count: half)
        func zeros(_ count: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: count)
            p.initialize(repeating: 0, count: count)
            return p
        }
        inRe = zeros(size)
        inIm = zeros(size)
        outRe = zeros(size)
        outIm = zeros(size)
        skip = size - StageSplitter.hop
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        for p in [inRe, inIm, outRe, outIm] { p.deallocate() }
    }

    private static func emptyOutput() -> [[[Float]]] {
        return [[[Float]]](repeating: [[], []], count: sourceCount)
    }

    /// Takes more input (both channels the same length) and returns, per source, the
    /// (left, right) output that is complete.
    public func process(left: [Float], right: [Float]) -> [[[Float]]] {
        var out = StageSplitter.emptyOutput()
        let count = min(left.count, right.count)
        for i in 0..<count {
            let at = n - hop + pending
            frameLeft[at] = left[i]
            frameRight[at] = right[i]
            fed += 1
            pending += 1
            if pending == hop {
                pending = 0
                frame(&out, limit: nil)
            }
        }
        return out
    }

    /// The output still owed for the input so far.
    public func flush() -> [[[Float]]] {
        var out = StageSplitter.emptyOutput()
        let total = fed
        while given < total {
            let at = n - hop + pending
            frameLeft[at] = 0
            frameRight[at] = 0
            pending += 1
            if pending == hop {
                pending = 0
                frame(&out, limit: total)
            }
        }
        return out
    }

    private func frame(_ out: inout [[[Float]]], limit: Int?) {
        let size = n
        /* Both channels in one transform: x = left + i·right. */
        for i in 0..<size {
            inRe[i] = frameLeft[i] * window[i]
            inIm[i] = frameRight[i] * window[i]
        }
        transform(inverse: false)
        for k in 0..<bins {
            let m = (size - k) % size
            let ar = outRe[k], ai = outIm[k], br = outRe[m], bi = -outIm[m]
            specLRe[k] = (ar + br) / 2
            specLIm[k] = (ai + bi) / 2
            specRRe[k] = (ai - bi) / 2
            specRIm[k] = -(ar - br) / 2
        }
        /* The new input of the next frame goes behind what is kept. */
        for i in 0..<(size - hop) {
            frameLeft[i] = frameLeft[i + hop]
            frameRight[i] = frameRight[i + hop]
        }

        let beta: Float = 0.8
        let eps: Float = 1e-12
        for k in 0..<bins {
            let lr = specLRe[k], li = specLIm[k], rr = specRRe[k], ri = specRIm[k]
            powerLeft[k] = beta * powerLeft[k] + (1 - beta) * (lr * lr + li * li)
            powerRight[k] = beta * powerRight[k] + (1 - beta) * (rr * rr + ri * ri)
            /* left · conj(right) */
            crossRe[k] = beta * crossRe[k] + (1 - beta) * (lr * rr + li * ri)
            crossIm[k] = beta * crossIm[k] + (1 - beta) * (li * rr - lr * ri)
        }
        for k in 0..<bins {
            let k0 = k > 0 ? k - 1 : 0
            let k1 = k < bins - 1 ? k + 1 : bins - 1
            let a = powerLeft[k0] + powerLeft[k] + powerLeft[k1]
            let b = powerRight[k0] + powerRight[k] + powerRight[k1]
            let xr = crossRe[k0] + crossRe[k] + crossRe[k1]
            let xi = crossIm[k0] + crossIm[k] + crossIm[k1]
            let half = (a + b) / 2
            let diff = (a - b) / 2
            /* The smaller eigenvalue: the part the channels do not share. */
            let small = max(0, half - (diff * diff + xr * xr + xi * xi).squareRoot())
            let ambLeft: Float = a > eps ? min(1, small / a).squareRoot() : 0
            let ambRight: Float = b > eps ? min(1, small / b).squareRoot() : 0
            let shared = a + b - 2 * small
            let pan: Float = shared > eps ? min(1, max(-1, (b - a) / shared)) : 0
            let q = pan / 0.18
            let centre = exp(-q * q)
            let low = lowWeight[k]
            let rest = 1 - low
            for channel in 0..<2 {
                let amb = channel == 0 ? ambLeft : ambRight
                let primary = rest * (1 - amb)
                masks[(0 * 2 + channel) * bins + k] = low
                masks[(1 * 2 + channel) * bins + k] = primary * centre
                masks[(2 * 2 + channel) * bins + k] = pan < 0 ? primary * (1 - centre) : 0
                masks[(3 * 2 + channel) * bins + k] = pan < 0 ? 0 : primary * (1 - centre)
                masks[(4 * 2 + channel) * bins + k] = rest * amb
            }
        }

        let scale = 1 / (1.5 * Float(size))
        for source in 0..<StageSplitter.sourceCount {
            let maskLeft = (source * 2) * bins
            let maskRight = (source * 2 + 1) * bins
            /* Both channels of the source in one inverse transform: z = left + i·right, with
               the mirrored half of each spectrum. */
            for k in 0..<bins {
                let gl = masks[maskLeft + k], gr = masks[maskRight + k]
                let slr = specLRe[k] * gl, sli = specLIm[k] * gl
                let srr = specRRe[k] * gr, sri = specRIm[k] * gr
                inRe[k] = slr - sri
                inIm[k] = sli + srr
                if k > 0 && k < size / 2 {
                    inRe[size - k] = slr + sri
                    inIm[size - k] = srr - sli
                }
            }
            transform(inverse: true)
            let accLeft = (source * 2) * size
            let accRight = (source * 2 + 1) * size
            for i in 0..<size {
                acc[accLeft + i] += outRe[i] * window[i] * scale
                acc[accRight + i] += outIm[i] * window[i] * scale
            }
        }

        /* The oldest `hop` samples have had every frame that covers them. */
        var from = 0
        var take = hop
        if skip > 0 {
            let d = min(skip, take)
            skip -= d
            from = d
        }
        if let limit = limit { take = min(take, from + (limit - given)) }
        for c in 0..<(StageSplitter.sourceCount * 2) {
            let base = c * size
            if take > from { out[c / 2][c % 2].append(contentsOf: acc[(base + from)..<(base + take)]) }
            for i in 0..<(size - hop) { acc[base + i] = acc[base + i + hop] }
            for i in (size - hop)..<size { acc[base + i] = 0 }
        }
        if take > from { given += take - from }
    }

    /// Transforms (inRe, inIm) into (outRe, outIm). Neither direction is scaled.
    private func transform(inverse: Bool) {
        var input = DSPSplitComplex(realp: inRe, imagp: inIm)
        var output = DSPSplitComplex(realp: outRe, imagp: outIm)
        let direction = FFTDirection(inverse ? kFFTDirection_Inverse : kFFTDirection_Forward)
        vDSP_fft_zop(setup, &input, 1, &output, 1, log2n, direction)
    }
}
