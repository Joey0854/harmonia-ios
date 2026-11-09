import Accelerate
import Foundation

/// The neural network in the middle of HTDemucs (drums / bass / other / vocals), as the app's
/// Core ML model runs it. Everything around it (transform, normalisation, segments) is done by
/// `Demucs` and `BandSplitter`, following tools/band/band_ref.py.
///
/// `spec`: the normalised spectrum, 4 × `Demucs.bins` × `Demucs.frames` (channels left re,
/// left im, right re, right im; then bin; then frame). `wave`: the normalised wave, 2 ×
/// `Demucs.segment`. Returns 16 × bins × frames (source, then the same four channels) and
/// 8 × segment (source, then left / right), still normalised. Sources in `Demucs.sources` order.
public protocol BandNetwork: AnyObject {
    func run(spec: [Float], wave: [Float]) throws -> (spec: [Float], wave: [Float])
    /// See BandWatchdog: work before a run that is not timed, and letting go after a stall.
    func prepare() throws
    func abandon()
}

/// HTDemucs' own pre- and post-processing for one segment (`_spec`, `_ispec`, the mean / std
/// normalisation of both branches and the complex-as-channels layout).
public enum Demucs {
    public static let sampleRate = 44100
    public static let nfft = 4096
    public static let hop = 1024
    /// int(44100 × 7.8): the length the network was trained on, and the only one it takes.
    public static let segment = 343980
    public static let frames = 336
    public static let bins = 2048
    /// apply_model's step with overlap 0.25.
    public static let stride = 257985
    public static let sources = ["drums", "bass", "other", "vocals"]

    /* Periodic Hann window, as torch.hann_window. */
    static let window: [Float] = (0..<nfft).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(nfft))) }

    /* The overlap-add envelope (sum of squared windows) of _ispec, for the samples kept. */
    private static let keptFrom = nfft / 2 + hop / 2 * 3
    private static let envelope: [Float] = {
        let count = frames + 4
        var env = [Double](repeating: 0, count: nfft + hop * (count - 1))
        for t in 0..<count {
            for k in 0..<nfft { env[t * hop + k] += Double(window[k]) * Double(window[k]) }
        }
        return (0..<segment).map { Float(env[keptFrom + $0]) }
    }()

    /// Mirror padding without repeating the edge sample (numpy / torch "reflect").
    static func reflect(_ x: [Float], left: Int, right: Int) -> [Float] {
        let n = x.count
        var out = [Float](repeating: 0, count: n + left + right)
        for i in 0..<out.count {
            var j = i - left
            if j < 0 { j = -j }
            if j >= n { j = 2 * (n - 1) - j }
            out[i] = x[max(0, min(n - 1, j))]
        }
        return out
    }

    /// `_spec` of one channel of `segment` samples: (re, im), each bins × frames (bin-major).
    public static func spectrum(_ x: [Float]) -> (re: [Float], im: [Float]) {
        precondition(x.count == segment)
        let padded = reflect(reflect(x, left: hop / 2 * 3, right: hop / 2 * 3 + frames * hop - segment),
                             left: nfft / 2, right: nfft / 2)
        var re = [Float](repeating: 0, count: bins * frames)
        var im = [Float](repeating: 0, count: bins * frames)
        let fft = FFT.shared
        let scale = 1 / Float(nfft).squareRoot()
        var inRe = [Float](repeating: 0, count: nfft)
        var inIm = [Float](repeating: 0, count: nfft)
        var outRe = [Float](repeating: 0, count: nfft)
        var outIm = [Float](repeating: 0, count: nfft)
        for t in 0..<frames {
            let start = (t + 2) * hop
            for k in 0..<nfft { inRe[k] = padded[start + k] * window[k] }
            for k in 0..<nfft { inIm[k] = 0 }
            fft.run(&inRe, &inIm, &outRe, &outIm, inverse: false)
            for f in 0..<bins {
                re[f * frames + t] = outRe[f] * scale
                im[f * frames + t] = outIm[f] * scale
            }
        }
        return (re, im)
    }

    /// `_ispec` of one channel: (re, im) as from `spectrum` back to `segment` samples.
    public static func inverse(re: [Float], im: [Float]) -> [Float] {
        precondition(re.count == bins * frames && im.count == bins * frames)
        let fft = FFT.shared
        /* frames are padded by two silent ones at each end, the transform is normalised */
        let total = nfft + hop * (frames + 3)
        var ola = [Float](repeating: 0, count: total)
        var inRe = [Float](repeating: 0, count: nfft)
        var inIm = [Float](repeating: 0, count: nfft)
        var outRe = [Float](repeating: 0, count: nfft)
        var outIm = [Float](repeating: 0, count: nfft)
        let scale = Float(nfft).squareRoot() / Float(nfft)
        for t in 0..<frames {
            for f in 0..<bins {
                inRe[f] = re[f * frames + t]
                inIm[f] = im[f * frames + t]
            }
            inRe[bins] = 0
            inIm[bins] = 0
            for f in 1..<bins {
                inRe[nfft - f] = inRe[f]
                inIm[nfft - f] = -inIm[f]
            }
            inIm[0] = 0
            fft.run(&inRe, &inIm, &outRe, &outIm, inverse: true)
            let start = (t + 2) * hop
            for k in 0..<nfft { ola[start + k] += outRe[k] * scale * window[k] }
        }
        var out = [Float](repeating: 0, count: segment)
        for n in 0..<segment { out[n] = ola[keptFrom + n] / envelope[n] }
        return out
    }

    /// Mean and (unbiased) standard deviation, as torch's mean / std.
    static func stats(_ x: [Float]) -> (mean: Double, std: Double) {
        var sum = 0.0
        for v in x { sum += Double(v) }
        let mean = sum / Double(max(1, x.count))
        var sq = 0.0
        for v in x { let d = Double(v) - mean; sq += d * d }
        return (mean, (sq / Double(max(1, x.count - 1))).squareRoot())
    }

    /// One segment (both channels `segment` samples long) through the whole model: returns
    /// [source][channel][sample], sources in `sources` order.
    public static func separate(left: [Float], right: [Float], network: BandNetwork) throws -> [[[Float]]] {
        let l = spectrum(left), r = spectrum(right)
        var spec = l.re + l.im + r.re + r.im
        let s = stats(spec)
        let a = Float(1 / (1e-5 + s.std)), b = Float(s.mean)
        for i in 0..<spec.count { spec[i] = (spec[i] - b) * a }
        var wave = left + right
        let t = stats(wave)
        let at = Float(1 / (1e-5 + t.std)), bt = Float(t.mean)
        for i in 0..<wave.count { wave[i] = (wave[i] - bt) * at }

        let out = try network.run(spec: spec, wave: wave)
        let plane = bins * frames
        guard out.spec.count == 16 * plane, out.wave.count == 8 * segment else {
            throw NetworkShapeError(spec: out.spec.count, wave: out.wave.count)
        }
        let std = Float(s.std), mean = Float(s.mean), stdt = Float(t.std), meant = Float(t.mean)
        var stems: [[[Float]]] = []
        for source in 0..<4 {
            var pair: [[Float]] = []
            for channel in 0..<2 {
                let base = (source * 4 + channel * 2) * plane
                let re = out.spec[base..<(base + plane)].map { $0 * std + mean }
                let im = out.spec[(base + plane)..<(base + 2 * plane)].map { $0 * std + mean }
                var x = inverse(re: re, im: im)
                let w = (source * 2 + channel) * segment
                for n in 0..<segment { x[n] += out.wave[w + n] * stdt + meant }
                pair.append(x)
            }
            stems.append(pair)
        }
        return stems
    }

    public struct NetworkShapeError: Error, CustomStringConvertible {
        public let spec: Int
        public let wave: Int
        public var description: String { return "network returned \(spec) + \(wave) values" }
    }

    /// A complex FFT of `nfft` points; neither direction is scaled. Safe to share between
    /// threads (the setup is only read).
    final class FFT {
        static let shared = FFT()
        private let setup: FFTSetup
        private let log2n = vDSP_Length(12)

        private init() {
            setup = vDSP_create_fftsetup(12, FFTRadix(kFFTRadix2))!
        }

        func run(_ inRe: inout [Float], _ inIm: inout [Float], _ outRe: inout [Float], _ outIm: inout [Float], inverse: Bool) {
            let direction = FFTDirection(inverse ? kFFTDirection_Inverse : kFFTDirection_Forward)
            inRe.withUnsafeMutableBufferPointer { ir in
                inIm.withUnsafeMutableBufferPointer { ii in
                    outRe.withUnsafeMutableBufferPointer { orr in
                        outIm.withUnsafeMutableBufferPointer { oi in
                            var input = DSPSplitComplex(realp: ir.baseAddress!, imagp: ii.baseAddress!)
                            var output = DSPSplitComplex(realp: orr.baseAddress!, imagp: oi.baseAddress!)
                            vDSP_fft_zop(setup, &input, 1, &output, 1, log2n, direction)
                        }
                    }
                }
            }
        }
    }
}

/// apply_model's split into overlapping segments (offsets every `Demucs.stride`, triangle
/// weights, the last segment centred in context), done as a stream: input is added as it
/// comes, `takeJob` hands out the next segment once its input is all there, `complete` adds
/// its result in. Samples before `finalUpTo` will not change any more.
///
/// Not thread-safe; `BandProcessor` locks around it.
public final class BandSplitter {
    public struct Job {
        public let index: Int
        public let offset: Int
        /// Samples of this segment that are kept (less than `Demucs.segment` only at the end).
        public let length: Int
        public let left: [Float]
        public let right: [Float]
    }

    static let weights: [Float] = {
        let n = Demucs.segment, half = n / 2
        var w = [Float](repeating: 0, count: n)
        for i in 0..<half { w[i] = Float(i + 1) }
        for i in half..<n { w[i] = Float(n - i) }
        let top = w.max() ?? 1
        return w.map { $0 / top }
    }()

    public private(set) var received = 0
    /// Total length, once known.
    public private(set) var total: Int?
    public private(set) var finalUpTo = 0
    public private(set) var nextIndex = 0
    public private(set) var skipped = 0

    private var inLeft: [Float] = []
    private var inRight: [Float] = []
    private var inBase = 0
    /* Weighted sums per source and channel, and the sum of weights, from accBase on. */
    private var acc = [[Float]](repeating: [], count: 8)
    private var weight: [Float] = []
    private var accBase = 0

    public init() {}

    /* Separated sound from elsewhere (a prefetch) for the samples before seedEnd, 16-bit. */
    private var seedStems: [[Int16]] = []
    private var seedEnd = 0
    static let seedScale: Float = 2 / 32767

    /// Starts with the first `segments` segments already separated (`final` as `read` gives
    /// it for [0, segments × stride), [source × 2 + channel][sample], 16-bit with
    /// `seedScale`). Call before any job is taken. The next segment blends in with only its
    /// own weight where it overlaps the seed.
    public func seed(_ final: [[Int16]], segments: Int) {
        guard segments > 0, final.count == 8, nextIndex == 0 else { return }
        let end = min(final[0].count, segments * Demucs.stride)
        seedStems = final.map { Array($0.prefix(end)) }
        seedEnd = end
        nextIndex = segments
        finalUpTo = end
        accBase = end
    }

    /* Or separated sound read on demand (the disk cache) for the samples before seedEnd. */
    private var seedSource: ((Int, Int) -> [[Float]]?)?

    /// Like `seed`, with the first `segments` segments read when needed from `source`
    /// (from, count) -> [source × 2 + channel][sample].
    public func seed(source: @escaping (Int, Int) -> [[Float]]?, segments: Int) {
        guard segments > 0, nextIndex == 0 else { return }
        let end = segments * Demucs.stride
        seedSource = source
        seedEnd = end
        nextIndex = segments
        finalUpTo = end
        accBase = end
    }

    /// Converts separated sound to the seed's 16-bit form.
    public static func pack(_ stems: [[Float]]) -> [[Int16]] {
        let g = 1 / seedScale
        return stems.map { ch in ch.map { Int16(max(-32767, min(32767, ($0 * g).rounded()))) } }
    }

    public func add(left: [Float], right: [Float]) {
        let n = min(left.count, right.count)
        inLeft.append(contentsOf: left.prefix(n))
        inRight.append(contentsOf: right.prefix(n))
        received += n
    }

    public func end() {
        if total == nil { total = received }
    }

    /// The next segment to separate, or nil if its input is not complete yet. Segments whose
    /// part would all be before `wanted` (already played) are skipped.
    public func takeJob(wanted: Int = 0) -> Job? {
        while true {
            let offset = nextIndex * Demucs.stride
            if let t = total, offset >= t { return nil }
            if total == nil && received < offset + Demucs.segment { return nil }
            let length = min(Demucs.segment, (total ?? Int.max) - offset)
            let ownEnd = total.map { min($0, offset + Demucs.stride) } ?? (offset + Demucs.stride)
            if ownEnd <= wanted {
                nextIndex += 1
                skipped += 1
                finalUpTo = max(finalUpTo, ownEnd)
                continue
            }
            let delta = Demucs.segment - length
            let start = offset - delta / 2
            var l = [Float](repeating: 0, count: Demucs.segment)
            var r = [Float](repeating: 0, count: Demucs.segment)
            let a = max(start, inBase), b = min(start + Demucs.segment, received)
            if b > a {
                for i in a..<b {
                    l[i - start] = inLeft[i - inBase]
                    r[i - start] = inRight[i - inBase]
                }
            }
            nextIndex += 1
            return Job(index: nextIndex - 1, offset: offset, length: length, left: l, right: r)
        }
    }

    /// Adds a separated segment (as from `Demucs.separate`) to the result.
    public func complete(_ job: Job, stems: [[[Float]]]) {
        let delta = Demucs.segment - job.length
        let from = delta / 2
        let end = job.offset + job.length
        let need = end - accBase
        if weight.count < need {
            let grow = need - weight.count
            weight.append(contentsOf: [Float](repeating: 0, count: grow))
            for i in 0..<8 { acc[i].append(contentsOf: [Float](repeating: 0, count: grow)) }
        }
        let w = BandSplitter.weights
        let first = max(job.offset, accBase)
        if first < end {
            for n in first..<end {
                let k = n - job.offset
                weight[n - accBase] += w[k]
            }
            for s in 0..<4 {
                for c in 0..<2 {
                    let x = stems[s][c]
                    let i = s * 2 + c
                    for n in first..<end {
                        let k = n - job.offset
                        acc[i][n - accBase] += w[k] * x[from + k]
                    }
                }
            }
        }
        let next = job.offset + Demucs.stride
        finalUpTo = max(finalUpTo, total.map { next >= $0 ? $0 : next } ?? next)
    }

    /// Separated sound for [from, from + count): [source * 2 + channel][sample], and per sample
    /// whether it is there (false where a segment was skipped or is still missing).
    public func read(from: Int, count: Int) -> (stems: [[Float]], ready: [Bool]) {
        var stems = [[Float]](repeating: [Float](repeating: 0, count: count), count: 8)
        var ready = [Bool](repeating: false, count: count)
        if let source = seedSource, from < seedEnd {
            let m = min(count, seedEnd - max(0, from))
            if from >= 0, m > 0, let block = source(from, m) {
                for c in 0..<8 { for j in 0..<min(m, block[c].count) { stems[c][j] = block[c][j] } }
                for j in 0..<m { ready[j] = true }
            }
        }
        for j in 0..<count {
            let n = from + j
            if n >= finalUpTo { break }
            if n < seedEnd {
                if seedSource != nil { continue }
                if n >= seedEnd - seedStems[0].count {
                    let k = n - (seedEnd - seedStems[0].count)
                    ready[j] = true
                    for c in 0..<8 { stems[c][j] = Float(seedStems[c][k]) * BandSplitter.seedScale }
                }
                continue
            }
            let i = n - accBase
            guard i >= 0, i < weight.count, weight[i] > 0 else { continue }
            ready[j] = true
            let g = 1 / weight[i]
            for c in 0..<8 { stems[c][j] = acc[c][i] * g }
        }
        return (stems, ready)
    }

    /// Forgets results before `sample` (already played) and input no segment needs any more.
    public func drop(before sample: Int) {
        /* the seed: what has been played goes */
        let gone = min(sample, seedEnd) - (seedEnd - (seedStems.first?.count ?? 0))
        if gone > Demucs.stride / 4, let n = seedStems.first?.count {
            let k = min(gone, n)
            for c in 0..<8 { seedStems[c].removeFirst(k) }
        }
        /* in large steps only: every removal moves what is left */
        let cut = min(sample, finalUpTo) - accBase
        if cut > Demucs.stride / 4 {
            if cut >= weight.count {
                weight = []
                acc = [[Float]](repeating: [], count: 8)
            } else {
                weight.removeFirst(cut)
                for i in 0..<8 { acc[i].removeFirst(cut) }
            }
            accBase += cut
        }
        /* the next segment may reach back half a segment (the last one is centred) */
        let keep = nextIndex * Demucs.stride - Demucs.segment / 2 - inBase
        if keep > Demucs.stride / 4 {
            let k = min(keep, inLeft.count)
            inLeft.removeFirst(k)
            inRight.removeFirst(k)
            inBase += k
        }
    }

    /// A whole recording at once (tests, tools): [source][channel][sample].
    public static func separateAll(left: [Float], right: [Float], network: BandNetwork) throws -> [[[Float]]] {
        let splitter = BandSplitter()
        splitter.add(left: left, right: right)
        splitter.end()
        while let job = splitter.takeJob() {
            splitter.complete(job, stems: try Demucs.separate(left: job.left, right: job.right, network: network))
        }
        let n = min(left.count, right.count)
        let out = splitter.read(from: 0, count: n).stems
        return (0..<4).map { s in [out[s * 2], out[s * 2 + 1]] }
    }
}
