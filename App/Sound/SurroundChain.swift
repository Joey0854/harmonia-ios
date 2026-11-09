import Foundation

/// How surround is made when it is on.
public enum SurroundMode: String {
    /// Head-related impulse responses (for headphones).
    case hrir
    /// The recording split into rough sources placed on a stage in front (for a car's speakers).
    case stage
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

    public init(key: String, surround: Bool, irLeft: Data?, irRight: Data?, makeup: Float,
                mode: SurroundMode = .hrir, stage: StageParams = .neutral) {
        self.key = key
        self.surround = surround
        self.irLeft = irLeft
        self.irRight = irRight
        self.makeup = makeup
        self.mode = mode
        self.stage = stage
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
    private let convolver: TrueStereoConvolver?
    private let stage: StageProcessor?
    private let makeup: Float
    /// Set when surround was asked for but the impulse responses could not be used; the sound
    /// then passes through with the make-up gain only.
    public let problem: String?

    public init(settings: SurroundSettings?, sampleRate: Int, blockSize: Int = 4096) {
        makeup = settings?.makeup ?? 1
        guard let s = settings, s.surround else {
            convolver = nil
            stage = nil
            problem = nil
            return
        }
        if s.mode == .stage {
            convolver = nil
            stage = StageProcessor(params: s.stage, sampleRate: sampleRate)
            problem = nil
            return
        }
        stage = nil
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
        if let st = stage { return scaled(st.process(left: left, right: right)) }
        guard let c = convolver else { return scaled((left, right)) }
        return scaled(c.process(left: left, right: right))
    }

    public func finish() -> (left: [Float], right: [Float]) {
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
