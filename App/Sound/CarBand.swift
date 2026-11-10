import Accelerate
import Foundation

/// One separated part in the car band mode (`SurroundMode.bandCar`). Volume, solo and mute
/// stay in `BandPart`; this is what the car mode does with the part on top of that.
public struct CarBandTrack: Equatable {
    /// Level difference between the speakers, in dB, above the low crossover (below it every
    /// part is the same on both sides). Positive: the right side louder. 6 means right +3 dB,
    /// left -3 dB.
    public var panDb: Float
    /// Reverb send in dB; at or below `CarBandParams.sendOff` nothing is sent.
    public var sendDb: Float
    /// True: the part's reverb goes to the rear bus (left +w, right -w, which the car's
    /// Centerpoint sends to the rear-window speakers). False: the front bus, the same on both
    /// sides apart from the part's own pan, so it stays in front.
    public var rear: Bool

    public init(panDb: Float = 0, sendDb: Float = CarBandParams.sendOff, rear: Bool = true) {
        self.panDb = panDb
        self.sendDb = sendDb
        self.rear = rear
    }

    /// The send as a factor (0 when off).
    public var sendGain: Float { return sendDb <= CarBandParams.sendOff ? 0 : pow(10, sendDb / 20) }
}

/// The car band mode's settings (a Bose system with Centerpoint on: what is the same on both
/// sides goes to the centre, level differences to the doors, mid-band opposite-phase sound to
/// the rear windows, see RESULTS-2026-11-10). Tracks in `Demucs.sources` order.
public struct CarBandParams: Equatable {
    /// A send at or below this is off.
    public static let sendOff: Float = -40

    public var tracks: [CarBandTrack]
    /// The reverb layer on or off.
    public var ambienceOn: Bool
    /// The whole reverb layer (both buses) against the dry mix, in dB (RMS, kept there as the
    /// song goes on).
    public var ambienceDb: Float
    public var rt60: Float
    public var predelayMs: Float
    /// The reverb's band: high-pass 24 dB/oct at `lowHz` (and a guard, see `CarBandMixer`),
    /// low-pass 12 dB/oct at `highHz`.
    public var lowHz: Float
    public var highHz: Float
    /// Below this every part is the same on both sides.
    public var crossoverHz: Float
    /// Early reflections: every part's dry sound (above `crossoverHz`) through a few taps
    /// between `earlyMinMs` and `earlyMaxMs`; half of the taps only on the left, half only on
    /// the right, all positive (so they go to the doors, not the centre or the rear).
    public var earlyOn: Bool
    /// The early reflections against the dry mix, in dB (RMS).
    public var earlyDb: Float
    public var earlyMinMs: Float
    public var earlyMaxMs: Float
    /// Extra high-frequency damping of the reverb: the part above 3 kHz decays with
    /// RT60 × 0.5 × this (1: as the v2b prototype, where it already decays twice as fast).
    public var hfDamping: Float
    /// True: the reverb below `lowSplitHz` is kept, the same on both sides (in front); the
    /// part above still goes to its bus (the rear one in opposite phase). False: removed.
    public var lowReverbFront: Bool
    public var lowSplitHz: Float

    public init(tracks: [CarBandTrack], ambienceOn: Bool = true, ambienceDb: Float = -15, rt60: Float = 1.4,
                predelayMs: Float = 12, lowHz: Float = 250, highHz: Float = 4000, crossoverHz: Float = 150,
                earlyOn: Bool = false, earlyDb: Float = -10, earlyMinMs: Float = 15, earlyMaxMs: Float = 30,
                hfDamping: Float = 1, lowReverbFront: Bool = false, lowSplitHz: Float = 250) {
        self.tracks = tracks
        self.ambienceOn = ambienceOn
        self.ambienceDb = ambienceDb
        self.rt60 = rt60
        self.predelayMs = predelayMs
        self.lowHz = lowHz
        self.highHz = highHz
        self.crossoverHz = crossoverHz
        self.earlyOn = earlyOn
        self.earlyDb = earlyDb
        self.earlyMinMs = earlyMinMs
        self.earlyMaxMs = earlyMaxMs
        self.hfDamping = hfDamping
        self.lowReverbFront = lowReverbFront
        self.lowSplitHz = lowSplitHz
    }

    /// The one chosen by ear in the car (make.py v2b): vocals dry in the centre with a little
    /// reverb (-10 dB against the other parts' send), other 6 dB to the right, drums 2 dB to
    /// the left above 150 Hz, bass in the centre; the reverb (RT60 1.4 s, 12 ms) to the rear,
    /// 15 dB below the dry mix, 250 Hz - 4 kHz only. (Piano, 6 dB to the left in v2b, needs a
    /// model with five parts; the phone's has four.)
    public static let v2b = CarBandParams(tracks: [
        CarBandTrack(panDb: -2, sendDb: sendOff, rear: true),   // drums
        CarBandTrack(panDb: 0, sendDb: sendOff, rear: true),    // bass
        CarBandTrack(panDb: 6, sendDb: 0, rear: true),          // other
        CarBandTrack(panDb: 0, sendDb: -10, rear: true)         // vocals
    ])

    /// For comparison (make.py v3a): everything in front, the reverb the same on both sides,
    /// parts 4 dB apart, nothing in opposite phase.
    public static let v3 = CarBandParams(tracks: [
        CarBandTrack(panDb: -2, sendDb: sendOff, rear: false),
        CarBandTrack(panDb: 0, sendDb: sendOff, rear: false),
        CarBandTrack(panDb: 4, sendDb: 0, rear: false),
        CarBandTrack(panDb: 0, sendDb: sendOff, rear: false)
    ], ambienceDb: -16, rt60: 1.2)

    /// "Concert hall": the v2b placement with the parts only 4 dB apart, early reflections
    /// (15 - 30 ms, 10 dB below the dry mix) to the doors, a longer reverb (RT60 1.8 s, 20 ms)
    /// 12 dB below the dry mix whose 250 Hz - 4 kHz part goes to the rear in opposite phase and
    /// whose part below 250 Hz stays in front (the same on both sides); vocals 6 dB less reverb
    /// than the instruments.
    public static let concertHall = CarBandParams(tracks: [
        CarBandTrack(panDb: -2, sendDb: sendOff, rear: true),
        CarBandTrack(panDb: 0, sendDb: sendOff, rear: true),
        CarBandTrack(panDb: 4, sendDb: 0, rear: true),
        CarBandTrack(panDb: 0, sendDb: -6, rear: true)
    ], ambienceDb: -12, rt60: 1.8, predelayMs: 20,
       earlyOn: true, earlyDb: -10, earlyMinMs: 15, earlyMaxMs: 30, hfDamping: 1, lowReverbFront: true, lowSplitHz: 250)

    /// Within the ranges the processing supports.
    public func clamped() -> CarBandParams {
        func c(_ v: Float, _ lo: Float, _ hi: Float) -> Float { return v.isFinite ? min(hi, max(lo, v)) : lo }
        var t = Array(tracks.prefix(4))
        while t.count < 4 { t.append(CarBandTrack()) }
        t = t.map { CarBandTrack(panDb: c($0.panDb, -12, 12), sendDb: c($0.sendDb, CarBandParams.sendOff, 6), rear: $0.rear) }
        let lo = c(lowHz, 120, 1000)
        let e0 = c(earlyMinMs, 5, 60)
        return CarBandParams(tracks: t, ambienceOn: ambienceOn, ambienceDb: c(ambienceDb, -30, -3),
                             rt60: c(rt60, 0.3, 3), predelayMs: c(predelayMs, 12, 80),
                             lowHz: lo, highHz: c(highHz, max(1500, lo * 2), 10000), crossoverHz: c(crossoverHz, 60, 300),
                             earlyOn: earlyOn, earlyDb: c(earlyDb, -30, -3), earlyMinMs: e0, earlyMaxMs: c(earlyMaxMs, e0, 80),
                             hfDamping: c(hfDamping, 0.25, 2), lowReverbFront: lowReverbFront, lowSplitHz: c(lowSplitHz, 80, 500))
    }
}

/// A second-order section (RBJ), transposed direct form II, in double precision.
struct CarBiquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    var z1 = 0.0, z2 = 0.0

    @inline(__always) mutating func step(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    /// New coefficients; the state is kept (a change is not restarted).
    mutating func design(highpass: Bool, frequency: Double, q: Double, sampleRate: Double) {
        let f = min(max(frequency, 10), 0.45 * sampleRate)
        let w = 2 * Double.pi * f / sampleRate
        let c = cos(w), alpha = sin(w) / (2 * q)
        let a0 = 1 + alpha
        if highpass {
            b0 = (1 + c) / 2 / a0
            b1 = -(1 + c) / a0
        } else {
            b0 = (1 - c) / 2 / a0
            b1 = (1 - c) / a0
        }
        b2 = b0
        a1 = -2 * c / a0
        a2 = (1 - alpha) / a0
    }

    /// Butterworth of order 2 × `qs.count`.
    static func butterworth(_ qs: [Double], highpass: Bool, frequency: Double, sampleRate: Double) -> [CarBiquad] {
        return qs.map { q in
            var b = CarBiquad()
            b.design(highpass: highpass, frequency: frequency, q: q, sampleRate: sampleRate)
            return b
        }
    }

    static let q2: [Double] = [0.70710678]
    static let q4: [Double] = [0.54119610, 1.30656296]
    static let q8: [Double] = [0.50979558, 0.60134489, 0.89997622, 2.56291545]
}

/// Convolution of several channels with one long response, with no delay at all: the
/// response must be silent for its first `blockSize` samples (the reverb's pre-delay), so each
/// block's output can be made from earlier blocks only (uniformly partitioned, overlap-save).
/// Any number of samples in, the same number out.
final class CarConvolver {
    let blockSize: Int
    let channels: Int
    private let fftSize: Int
    private let log2n: vDSP_Length
    private let bins: Int
    private let partitions: Int
    private let setup: FFTSetup
    private let hRe: UnsafeMutablePointer<Float>
    private let hIm: UnsafeMutablePointer<Float>
    private let xRe: UnsafeMutablePointer<Float>
    private let xIm: UnsafeMutablePointer<Float>
    private let previous: UnsafeMutablePointer<Float>
    private let inBlock: UnsafeMutablePointer<Float>
    private let outBlock: UnsafeMutablePointer<Float>
    private let inRe: UnsafeMutablePointer<Float>
    private let inIm: UnsafeMutablePointer<Float>
    private let outRe: UnsafeMutablePointer<Float>
    private let outIm: UnsafeMutablePointer<Float>
    private let accRe: UnsafeMutablePointer<Float>
    private let accIm: UnsafeMutablePointer<Float>
    private var position = 0
    private var ring = 0

    /// `response`: the whole response; its first `blockSize` samples are dropped (they must
    /// be zero). `blockSize` a power of two.
    init(response: [Float], channels: Int, blockSize: Int = 512) {
        var size = 16
        var log = 4
        while size < blockSize { size *= 2; log += 1 }
        self.blockSize = size
        self.channels = max(1, channels)
        fftSize = 2 * size
        log2n = vDSP_Length(log + 1)
        bins = size + 1
        let tail = response.count > size ? Array(response[size...]) : [0]
        partitions = max(1, (tail.count + size - 1) / size)
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        func zeros(_ count: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: count)
            p.initialize(repeating: 0, count: count)
            return p
        }
        hRe = zeros(partitions * bins)
        hIm = zeros(partitions * bins)
        xRe = zeros(self.channels * partitions * bins)
        xIm = zeros(self.channels * partitions * bins)
        previous = zeros(self.channels * size)
        inBlock = zeros(self.channels * size)
        outBlock = zeros(self.channels * size)
        inRe = zeros(fftSize)
        inIm = zeros(fftSize)
        outRe = zeros(fftSize)
        outIm = zeros(fftSize)
        accRe = zeros(fftSize)
        accIm = zeros(fftSize)
        for piece in 0..<partitions {
            for i in 0..<fftSize {
                let source = piece * size + i
                inRe[i] = (i < size && source < tail.count) ? tail[source] : 0
                inIm[i] = 0
            }
            transform(inverse: false)
            for k in 0..<bins {
                hRe[piece * bins + k] = outRe[k]
                hIm[piece * bins + k] = outIm[k]
            }
        }
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        for p in [hRe, hIm, xRe, xIm, previous, inBlock, outBlock, inRe, inIm, outRe, outIm, accRe, accIm] {
            p.deallocate()
        }
    }

    /// Replaces each channel's samples (all the same length) by the convolution output.
    func process(_ buffers: inout [[Float]]) {
        let count = buffers.map { $0.count }.min() ?? 0
        guard buffers.count >= channels else { return }
        var j = 0
        while j < count {
            let run = min(count - j, blockSize - position)
            for c in 0..<channels {
                let base = c * blockSize + position
                buffers[c].withUnsafeMutableBufferPointer { b in
                    for i in 0..<run {
                        let x = b[j + i]
                        b[j + i] = outBlock[base + i]
                        inBlock[base + i] = x
                    }
                }
            }
            position += run
            j += run
            if position == blockSize {
                block()
                position = 0
            }
        }
    }

    /// The next block's output from the input blocks so far.
    private func block() {
        let size = blockSize
        let scale = 1 / Float(fftSize)
        for c in 0..<channels {
            let old = previous + c * size
            let now = inBlock + c * size
            for i in 0..<size {
                inRe[i] = old[i]
                inRe[size + i] = now[i]
                old[i] = now[i]
            }
            for i in 0..<fftSize { inIm[i] = 0 }
            transform(inverse: false)
            let at = (c * partitions + ring) * bins
            for k in 0..<bins {
                xRe[at + k] = outRe[k]
                xIm[at + k] = outIm[k]
            }
            for k in 0..<bins {
                accRe[k] = 0
                accIm[k] = 0
            }
            /* two descriptions of the same buffer: added to in place */
            var accIn = DSPSplitComplex(realp: accRe, imagp: accIm)
            var accOut = DSPSplitComplex(realp: accRe, imagp: accIm)
            for piece in 0..<partitions {
                let slot = (ring - piece + partitions) % partitions
                var x = DSPSplitComplex(realp: xRe + (c * partitions + slot) * bins, imagp: xIm + (c * partitions + slot) * bins)
                var h = DSPSplitComplex(realp: hRe + piece * bins, imagp: hIm + piece * bins)
                vDSP_zvma(&x, 1, &h, 1, &accIn, 1, &accOut, 1, vDSP_Length(bins))
            }
            for k in 0..<bins {
                inRe[k] = accRe[k]
                inIm[k] = accIm[k]
            }
            for k in 1..<size {
                inRe[fftSize - k] = accRe[k]
                inIm[fftSize - k] = -accIm[k]
            }
            transform(inverse: true)
            let out = outBlock + c * size
            for i in 0..<size { out[i] = outRe[size + i] * scale }
        }
        ring = (ring + 1) % partitions
    }

    private func transform(inverse: Bool) {
        var input = DSPSplitComplex(realp: inRe, imagp: inIm)
        var output = DSPSplitComplex(realp: outRe, imagp: outIm)
        let direction = FFTDirection(inverse ? kFFTDirection_Inverse : kFFTDirection_Forward)
        vDSP_fft_zop(setup, &input, 1, &output, 1, log2n, direction)
    }
}

/// The car band mode's mixer, after separation (make.py v2b in real time):
///
/// - every part is first made mono, (L + R) / 2; below `crossoverHz` (Linkwitz-Riley, 24
///   dB/oct) it is the same on both sides, above it panned by the part's level difference;
/// - each part sends to one of two reverb buses: front (panned like the part, so a centred
///   part's reverb is the same on both sides) or rear (one mono signal w, out as left +w and
///   right -w); both buses go through the same reverb: exponentially decaying noise, RT60 and
///   pre-delay as set, convolved without delay (`CarConvolver`);
/// - the reverb is band-limited: high-pass 24 dB/oct at `lowHz` as in v2b, plus a guard
///   (high-pass 48 dB/oct at 1.2 × `lowHz`) so that what is left below `lowHz` is more than
///   30 dB down, and low-pass 12 dB/oct at `highHz`; nothing below `lowHz` is ever in
///   opposite phase; with `lowReverbFront` the reverb below `lowSplitHz` is added back, the
///   same on both sides (it stays in front);
/// - early reflections (optional): the parts' mono sum above the crossover through six taps
///   between `earlyMinMs` and `earlyMaxMs`, alternately only left and only right, all
///   positive, held `earlyDb` below the dry mix (one ring of past samples: a few operations per
///   sample);
/// - the reverb as a whole is held `ambienceDb` below the dry mix (followed over a few
///   seconds). Nothing here matches loudness or limits: the result goes on in float to the
///   engine's own loudness balance and limiter, like every other mode.
///
/// Output sample n belongs to input sample n. Not thread-safe.
public final class CarBandMixer {
    public let sampleRate: Int
    public private(set) var params: CarBandParams
    static let blockSize = 512

    private var lowpass: [[CarBiquad]]
    private var highpass: [[CarBiquad]]
    private var band: [[CarBiquad]]
    /* per track: pan factors above the crossover (left, right), front send (left, right), rear send */
    private var now: [[Float]]
    private var reverb: CarConvolver?
    private var fading: CarConvolver?
    private var fadeLeft = 0
    private static let fadeLength = 4096
    private var builtFor: (rt60: Float, predelay: Float, damping: Float)?
    /* the low part of each reverb channel (Linkwitz-Riley at lowSplitHz), for lowReverbFront */
    private var lowSplit: [[CarBiquad]] = []
    /* early reflections: mono input above the crossover, a ring of past samples, the taps */
    private var earlyHigh: [CarBiquad] = []
    private var earlyRing = [Float](repeating: 0, count: 8192)
    private var earlyAt = 0
    private var earlyTaps: [(delay: Int, gain: Float, left: Bool)] = []
    private var earlyPower = 0.0
    private var earlyGain: Float = 0
    /// Gains of the early-reflection taps, earliest first (alternately left and right).
    static let earlyGains: [Float] = [1.0, 0.85, 0.72, 0.61, 0.52, 0.44]
    private var dryPower = 0.0
    private var wetPower = 0.0
    private var started = false
    private var wetGain: Float = 0

    public init(sampleRate: Int, params: CarBandParams = .v2b) {
        self.sampleRate = max(8000, sampleRate)
        self.params = params.clamped()
        lowpass = []
        highpass = []
        band = []
        now = []
        design()
        now = (0..<4).map { targets(track: $0) }
        buildReverb()
    }

    /// New settings, from the next sample on (levels glide; a new reverb length or pre-delay
    /// cross-fades).
    public func set(_ new: CarBandParams) {
        let p = new.clamped()
        if p == params { return }
        params = p
        design()
        if let b = builtFor, (b.rt60 != p.rt60 || b.predelay != p.predelayMs || b.damping != p.hfDamping) {
            fading = reverb
            fadeLeft = CarBandMixer.fadeLength
            buildReverb()
        }
    }

    /// The reverb's response (unit energy): pre-delay, then noise decaying by 60 dB in `rt60`
    /// seconds, its part above 3 kHz twice as fast (make.py `make_ir`).
    static func response(rt60: Float, predelayMs: Float, sampleRate: Int, hfDamping: Float = 1, seed: UInt64 = 11) -> [Float] {
        let sr = Double(sampleRate)
        let pre = max(blockSize, Int((Double(predelayMs) / 1000 * sr).rounded()))
        let decay = Double(rt60) * 7 / 6   // to -70 dB
        let n = min(Int(4.5 * sr), pre + Int(decay * sr) + 1)
        var state = seed &* 0x9E3779B97F4A7C15 | 1
        func uniform() -> Double {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return (Double(state >> 11) + 0.5) / Double(1 << 53)
        }
        var lp = CarBiquad.butterworth(CarBiquad.q2, highpass: false, frequency: 3000, sampleRate: sr)[0]
        var ir = [Float](repeating: 0, count: n)
        var energy = 0.0
        for i in pre..<n {
            let z = (-2 * log(uniform())).squareRoot() * cos(2 * Double.pi * uniform())
            let lo = lp.step(z)
            let hi = z - lo
            let t = Double(i - pre) / sr
            let v = lo * exp(-6.9078 * t / Double(rt60)) + 0.7 * hi * exp(-6.9078 * t / (0.5 * Double(hfDamping) * Double(rt60)))
            ir[i] = Float(v)
            energy += v * v
        }
        let g = Float(1 / max(1e-12, energy).squareRoot())
        for i in pre..<n { ir[i] *= g }
        return ir
    }

    private func buildReverb() {
        let ir = CarBandMixer.response(rt60: params.rt60, predelayMs: params.predelayMs, sampleRate: sampleRate,
                                       hfDamping: params.hfDamping)
        reverb = CarConvolver(response: ir, channels: 3, blockSize: CarBandMixer.blockSize)
        builtFor = (params.rt60, params.predelayMs, params.hfDamping)
    }

    private func design() {
        let sr = Double(sampleRate)
        let x = Double(params.crossoverHz)
        if lowpass.count != 4 {
            lowpass = (0..<4).map { _ in CarBiquad.butterworth(CarBiquad.q2 + CarBiquad.q2, highpass: false, frequency: x, sampleRate: sr) }
            highpass = (0..<4).map { _ in CarBiquad.butterworth(CarBiquad.q2 + CarBiquad.q2, highpass: true, frequency: x, sampleRate: sr) }
        } else {
            for t in 0..<4 {
                for k in 0..<2 {
                    lowpass[t][k].design(highpass: false, frequency: x, q: CarBiquad.q2[0], sampleRate: sr)
                    highpass[t][k].design(highpass: true, frequency: x, q: CarBiquad.q2[0], sampleRate: sr)
                }
            }
        }
        let lo = Double(params.lowHz), hi = Double(params.highHz)
        let made = CarBiquad.butterworth(CarBiquad.q4, highpass: true, frequency: lo, sampleRate: sr)
            + CarBiquad.butterworth(CarBiquad.q8, highpass: true, frequency: 1.2 * lo, sampleRate: sr)
            + CarBiquad.butterworth(CarBiquad.q2, highpass: false, frequency: hi, sampleRate: sr)
        if band.count != 3 {
            band = (0..<3).map { _ in made }
        } else {
            for c in 0..<3 {
                for k in 0..<made.count {
                    var b = made[k]
                    b.z1 = band[c][k].z1
                    b.z2 = band[c][k].z2
                    band[c][k] = b
                }
            }
        }
        func keep(_ old: [CarBiquad], _ made: [CarBiquad]) -> [CarBiquad] {
            guard old.count == made.count else { return made }
            return zip(old, made).map { o, m in var b = m; b.z1 = o.z1; b.z2 = o.z2; return b }
        }
        let split = CarBiquad.butterworth(CarBiquad.q2 + CarBiquad.q2, highpass: false, frequency: Double(params.lowSplitHz), sampleRate: sr)
        lowSplit = (0..<3).map { c in keep(c < lowSplit.count ? lowSplit[c] : [], split) }
        earlyHigh = keep(earlyHigh, CarBiquad.butterworth(CarBiquad.q2 + CarBiquad.q2, highpass: true, frequency: x, sampleRate: sr))
        let count = CarBandMixer.earlyGains.count
        earlyTaps = (0..<count).map { i in
            let ms = Double(params.earlyMinMs) + Double(params.earlyMaxMs - params.earlyMinMs) * Double(i) / Double(count - 1)
            let d = min(earlyRing.count - 1, max(1, Int((ms / 1000 * sr).rounded())))
            return (d, CarBandMixer.earlyGains[i], i % 2 == 0)
        }
    }

    private func targets(track t: Int) -> [Float] {
        let p = params.tracks[t]
        let l = pow(10, -p.panDb / 40), r = pow(10, p.panDb / 40)
        let s = params.ambienceOn ? p.sendGain : 0
        return p.rear ? [l, r, 0, 0, s] : [l, r, s * l, s * r, 0]
    }

    /// `stems`: 8 channels (part, then left / right) in `Demucs.sources` order, volumes and the
    /// band's fade already applied. `standIn`: added as it is (what plays where the band is
    /// missing).
    public func process(stems: [[Float]], standIn: (left: [Float], right: [Float])) -> (left: [Float], right: [Float]) {
        var n = stems.count >= 8 ? stems.prefix(8).map { $0.count }.min() ?? 0 : 0
        n = min(n, standIn.left.count, standIn.right.count)
        if n == 0 { return ([], []) }
        var dryL = [Float](repeating: 0, count: n), dryR = [Float](repeating: 0, count: n)
        var buses: [[Float]] = [[Float](repeating: 0, count: n), [Float](repeating: 0, count: n), [Float](repeating: 0, count: n)]
        var earlyIn = [Float](repeating: 0, count: n)
        let k = Float(1 - exp(-1 / (0.02 * Double(sampleRate))))
        var sending = false
        for t in 0..<4 {
            let target = targets(track: t)
            var g = now[t]
            if target[2] > 0 || target[3] > 0 || target[4] > 0 || g[2] > 1e-6 || g[3] > 1e-6 || g[4] > 1e-6 { sending = true }
            var lp0 = lowpass[t][0], lp1 = lowpass[t][1], hp0 = highpass[t][0], hp1 = highpass[t][1]
            let left = stems[t * 2], right = stems[t * 2 + 1]
            for j in 0..<n {
                for q in 0..<5 { g[q] += (target[q] - g[q]) * k }
                let m = (left[j] + right[j]) * 0.5
                let md = Double(m)
                let lo = Float(lp1.step(lp0.step(md)))
                let hi = Float(hp1.step(hp0.step(md)))
                dryL[j] += lo + g[0] * hi
                dryR[j] += lo + g[1] * hi
                buses[0][j] += m * g[2]
                buses[1][j] += m * g[3]
                buses[2][j] += m * g[4]
                earlyIn[j] += m
            }
            lowpass[t][0] = lp0; lowpass[t][1] = lp1; highpass[t][0] = hp0; highpass[t][1] = hp1
            now[t] = g
        }

        var dryEnergy = 0.0
        for j in 0..<n { dryEnergy += Double(dryL[j] * dryL[j] + dryR[j] * dryR[j]) }
        dryEnergy /= Double(2 * n)
        let alpha = 1 - exp(-Double(n) / (2.5 * Double(sampleRate)))
        dryPower += started ? (dryEnergy - dryPower) * alpha : dryEnergy - dryPower

        var outL = dryL, outR = dryR

        /* early reflections: left taps only on the left, right taps only on the right */
        if params.earlyOn || earlyGain > 1e-5 {
            var erL = [Float](repeating: 0, count: n), erR = [Float](repeating: 0, count: n)
            let size = earlyRing.count
            var hpf = earlyHigh
            let taps = earlyTaps
            earlyRing.withUnsafeMutableBufferPointer { ring in
                for j in 0..<n {
                    var v = Double(earlyIn[j])
                    for s in 0..<hpf.count { v = hpf[s].step(v) }
                    ring[earlyAt] = Float(v)
                    var l: Float = 0, r: Float = 0
                    for tap in taps {
                        let x = ring[(earlyAt - tap.delay + size) % size] * tap.gain
                        if tap.left { l += x } else { r += x }
                    }
                    erL[j] = l
                    erR[j] = r
                    earlyAt = (earlyAt + 1) % size
                }
            }
            earlyHigh = hpf
            var e = 0.0
            for j in 0..<n { e += Double(erL[j] * erL[j] + erR[j] * erR[j]) }
            e /= Double(2 * n)
            earlyPower += (earlyPower == 0 ? e - earlyPower : (e - earlyPower) * alpha)
            var target = earlyGain
            if !params.earlyOn {
                target = 0
            } else if earlyPower > 1e-14 && dryPower > 1e-14 {
                target = min(31.6, pow(10, params.earlyDb / 20) * Float((dryPower / earlyPower).squareRoot()))
            }
            let from = earlyGain
            for j in 0..<n {
                let g = from + (target - from) * Float(j + 1) / Float(n)
                outL[j] += g * erL[j]
                outR[j] += g * erR[j]
            }
            earlyGain = target
        }

        let wetOn = sending || wetGain > 1e-5 || fading != nil
        if wetOn, let r = reverb {
            var wet = buses
            r.process(&wet)
            if let old = fading {
                var tail = buses
                old.process(&tail)
                for j in 0..<n {
                    let w = fadeLeft > 0 ? 1 - Float(fadeLeft) / Float(CarBandMixer.fadeLength) : 1
                    for c in 0..<3 { wet[c][j] = wet[c][j] * w + tail[c][j] * (1 - w) }
                    if fadeLeft > 0 { fadeLeft -= 1 }
                }
                if fadeLeft == 0 { fading = nil }
            }
            /* the part below lowSplitHz, kept the same on both sides (in front) */
            var low: [[Float]]? = nil
            if params.lowReverbFront {
                var made: [[Float]] = []
                for c in 0..<3 {
                    var f = lowSplit[c]
                    var out = [Float](repeating: 0, count: n)
                    for j in 0..<n {
                        var v = Double(wet[c][j])
                        for s in 0..<f.count { v = f[s].step(v) }
                        out[j] = Float(v)
                    }
                    lowSplit[c] = f
                    made.append(out)
                }
                low = made
            }
            for c in 0..<3 {
                var f = band[c]
                wet[c].withUnsafeMutableBufferPointer { b in
                    for j in 0..<n {
                        var v = Double(b[j])
                        for s in 0..<f.count { v = f[s].step(v) }
                        b[j] = Float(v)
                    }
                }
                band[c] = f
            }
            /* left = front left + rear + low, right = front right - rear + low */
            var wl = [Float](repeating: 0, count: n), wr = [Float](repeating: 0, count: n)
            for j in 0..<n {
                let rear = wet[2][j]
                var common: Float = 0
                if let lw = low { common = 0.5 * (lw[0][j] + lw[1][j]) + lw[2][j] }
                wl[j] = wet[0][j] + rear + common
                wr[j] = wet[1][j] - rear + common
            }
            var wetEnergy = 0.0
            for j in 0..<n { wetEnergy += Double(wl[j] * wl[j] + wr[j] * wr[j]) }
            wetEnergy /= Double(2 * n)
            wetPower += started ? (wetEnergy - wetPower) * alpha : wetEnergy - wetPower
            var target = wetGain
            if !params.ambienceOn {
                target = 0
            } else if wetPower > 1e-14 && dryPower > 1e-14 {
                target = min(31.6, pow(10, params.ambienceDb / 20) * Float((dryPower / wetPower).squareRoot()))
            }
            let from = wetGain
            for j in 0..<n {
                let g = from + (target - from) * Float(j + 1) / Float(n)
                outL[j] += g * wl[j]
                outR[j] += g * wr[j]
            }
            wetGain = target
        }


        started = true
        /* No loudness matching or limiting here: the engine's loudness balance and limiter
           come after (float throughout, so nothing clips before them). */
        for j in 0..<n {
            outL[j] += standIn.left[j]
            outR[j] += standIn.right[j]
        }
        return (outL, outR)
    }
}
