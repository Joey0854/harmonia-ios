import Foundation

/// How surround is made when it is on.
public enum SurroundMode: String {
    /// Head-related impulse responses (for headphones).
    case hrir
    /// The recording split into rough sources placed on a stage in front (for a car's speakers).
    case stage
    /// The recording separated by the HTDemucs network into drums, bass, other and vocals,
    /// placed on the stage in front (for a car's speakers).
    case band
    /// The same four parts, each through its own head-related responses (for headphones).
    case bandHead
}

/// The sound setting the page chose: surround on or off, how it is made (`mode`), the two
/// impulse responses for `hrir` (WAV files, 2 channels: left ear, right ear), the stage
/// controls for `stage`, and the make-up gain (a plain factor, 1 = no change) that follows.
public struct SurroundSettings {
    public let key: String
    public let surround: Bool
    public let irLeft: Data?
    public let irRight: Data?
    public let makeup: Float
    public let mode: SurroundMode
    public let stage: StageParams
    /// For `bandHead`: one pair of impulse responses (WAV, as `irLeft` / `irRight`) per
    /// part, in `Demucs.sources` order.
    public let bandIrs: [(left: Data, right: Data)]

    public init(key: String, surround: Bool, irLeft: Data?, irRight: Data?, makeup: Float,
                mode: SurroundMode = .hrir, stage: StageParams = .neutral,
                bandIrs: [(left: Data, right: Data)] = []) {
        self.key = key
        self.surround = surround
        self.irLeft = irLeft
        self.irRight = irRight
        self.makeup = makeup
        self.mode = mode
        self.stage = stage
        self.bandIrs = bandIrs
    }
}

/// The part of the signal chain done ahead of playback, for one song at one sample rate:
/// surround (when on: impulse responses, or the stage) and make-up gain. Equaliser, loudness
/// gain and limiter come later, in real time.
///
/// Output sample n belongs to input sample n. With surround on, output comes in whole blocks
/// of the convolver, or in steps of 512 samples on the stage (which makes up for the delay of
/// its transform inside, so nothing needs compensating here); `finish` returns the rest.
public final class SurroundChain {
    /// Provides the HTDemucs network for the band modes (set by the app, which holds the
    /// Core ML model); nil or returning nil: the band modes pass the sound through.
    public static var bandNetwork: (() -> BandNetwork?)?
    /// Where the band modes write what they do (timings, fallbacks).
    public static var log: (String) -> Void = { _ in }
    /// What the band modes are doing, for the page (`.off` when a chain without them starts).
    public static var status: (BandStatus) -> Void = { _ in }
    /// The one queue all band separation runs on, so two songs never compete for it.
    public static let bandQueue = DispatchQueue(label: "band.network", qos: .userInitiated)

    private let convolver: TrueStereoConvolver?
    private let stage: StageProcessor?
    private let band: BandProcessor?
    private let makeup: Float
    /// Set when surround was asked for but the impulse responses could not be used; the sound
    /// then passes through with the make-up gain only.
    public let problem: String?

    /// `song` and `startTime` (where its decoder started) let a band mode start with what
    /// `BandPrefetch` separated ahead of time.
    public init(settings: SurroundSettings?, sampleRate: Int, blockSize: Int = 4096,
                song: String = "", startTime: Double = 0) {
        makeup = settings?.makeup ?? 1
        if !(settings?.surround ?? false) || !(settings?.mode == .band || settings?.mode == .bandHead) {
            SurroundChain.status(.off)
        }
        guard let s = settings, s.surround else {
            convolver = nil
            stage = nil
            band = nil
            problem = nil
            return
        }
        if s.mode == .stage {
            convolver = nil
            band = nil
            stage = StageProcessor(params: s.stage, sampleRate: sampleRate)
            problem = nil
            return
        }
        stage = nil
        if s.mode == .band || s.mode == .bandHead {
            convolver = nil
            var output = BandProcessor.Output.speakers
            var trouble: String?
            if s.mode == .bandHead {
                do {
                    guard s.bandIrs.count == 4 else { throw WavFile.ParseError(description: "\(s.bandIrs.count) of 4 given") }
                    output = .headphones(try s.bandIrs.map {
                        (left: try SurroundChain.prepare($0.left, sampleRate: sampleRate),
                         right: try SurroundChain.prepare($0.right, sampleRate: sampleRate))
                    })
                } catch {
                    trouble = "band: impulse responses not usable (\(error)); playing the original"
                }
            }
            if trouble == nil, let network = SurroundChain.bandNetwork?() {
                let seed = song.isEmpty ? nil : BandPrefetch.shared.take(id: song, startTime: startTime, sampleRate: sampleRate)
                band = BandProcessor(output: output, network: network, sampleRate: sampleRate,
                                     queue: SurroundChain.bandQueue, seed: seed, log: SurroundChain.log,
                                     status: SurroundChain.status)
            } else {
                band = nil
                if trouble == nil { trouble = "band: the separation model is not available; playing the original" }
            }
            if let t = trouble { SurroundChain.status(.failed(t)) }
            problem = trouble
            return
        }
        band = nil
        guard let left = s.irLeft, let right = s.irRight else {
            convolver = nil
            problem = "surround is on but no impulse responses were given"
            return
        }
        var built: TrueStereoConvolver?
        var trouble: String?
        do {
            let l = try SurroundChain.prepare(left, sampleRate: sampleRate)
            let r = try SurroundChain.prepare(right, sampleRate: sampleRate)
            built = TrueStereoConvolver(irLeft: l, irRight: r, blockSize: blockSize)
        } catch {
            trouble = "impulse response not usable: \(error)"
        }
        convolver = built
        problem = trouble
    }

    /// Reads an impulse-response file and brings it to the song's sample rate.
    public static func prepare(_ wav: Data, sampleRate: Int) throws -> [[Float]] {
        let file = try WavFile(data: wav)
        /* A response of more than three seconds is not a head-related one; refuse it rather
           than spend the phone's battery on it. */
        guard let first = file.channels.first, !first.isEmpty, first.count <= file.sampleRate * 3 else {
            throw WavFile.ParseError(description: "impulse response empty or too long")
        }
        return file.channels.prefix(2).map {
            Resampler.convertImpulseResponse($0, from: file.sampleRate, to: sampleRate)
        }
    }

    public func process(left: [Float], right: [Float]) -> (left: [Float], right: [Float]) {
        if let b = band { return scaled(b.process(left: left, right: right)) }
        if let st = stage { return scaled(st.process(left: left, right: right)) }
        guard let c = convolver else { return scaled((left, right)) }
        return scaled(c.process(left: left, right: right))
    }

    /// After the last `process` and before `finish`: more output, for as long as this returns
    /// non-nil (only the band modes hold sound back; an empty result means "nothing yet"). With
    /// `urgent` it does not wait for the network but hands on the original sound.
    public func drain(urgent: Bool) -> (left: [Float], right: [Float])? {
        guard let b = band, let part = b.drain(urgent: urgent) else { return nil }
        return scaled(part)
    }

    public func finish() -> (left: [Float], right: [Float]) {
        if let b = band { return scaled(b.finish()) }
        if let st = stage { return scaled(st.finish()) }
        guard let c = convolver else { return ([], []) }
        return scaled(c.flush())
    }

    private func scaled(_ pair: (left: [Float], right: [Float])) -> (left: [Float], right: [Float]) {
        if makeup == 1 { return pair }
        let g = makeup
        return (pair.left.map { $0 * g }, pair.right.map { $0 * g })
    }
}
