import Foundation

/// Where one source stands on the virtual stage in front of the listener.
public struct StagePosition: Equatable {
    /// Degrees, −90 (far left) … 0 (straight ahead) … 90 (far right).
    public var azimuth: Float
    /// 0 (at the front of the stage) … 1 (far back): quieter, duller, more early reflections.
    public var depth: Float
    /// Width of a stereo source: 0 = mono, 1 = as it is, up to 2 = twice as wide.
    public var width: Float
    /// A plain factor.
    public var gain: Float

    public init(azimuth: Float = 0, depth: Float = 0, width: Float = 1, gain: Float = 1) {
        self.azimuth = azimuth
        self.depth = depth
        self.width = width
        self.gain = gain
    }

    /// Leaves a source exactly as it is.
    public static let neutral = StagePosition()
}

/// Puts several sources (each mono or stereo) on a virtual stage and mixes them into two
/// channels, meant for two speakers in front of the listener (a car) but usable on headphones.
///
/// Per source, sample by sample:
/// - width: mid / side, the side part scaled by `width`;
/// - depth: gain down to −3.7 dB, a blend towards a 4 kHz one-pole low-pass (up to 70 %), and
///   four early reflections (7, 11, 17, 23 ms, each side hearing the other side's sound);
/// - direction: a constant-power level difference (both gains 1 straight ahead, √2 and 0 at
///   ±90°) plus a delay of up to 0.7 ms on the far side (the precedence effect does the rest).
///
/// A source at `StagePosition.neutral` passes through unchanged. All delays are part of the
/// effect, not latency: output sample n belongs to input sample n.
///
/// Not thread-safe: use one instance from one queue.
public final class StagePlacer {
    public static let maxDelay = 0.0007
    public static let reflectionTimes: [Double] = [0.007, 0.011, 0.017, 0.023]
    public static let reflectionGains: [Float] = [0.30, 0.25, 0.20, 0.16]

    public let sampleRate: Int
    public let sourceCount: Int
    /// One per source; a missing one counts as neutral.
    public var positions: [StagePosition]
    /// Applied to the whole output.
    public var master: Float = 1

    private let size: Int
    private let mask: Int
    /* After the level difference, per source and channel: index (source * 2 + channel) * size. */
    private var lines: [Float]
    /* One-pole low-pass state per source and channel. */
    private var lowpass: [Float]
    private var at = 0
    private let lowpassCoefficient: Float
    private let taps: [Int]

    public init(sources: Int, sampleRate: Int) {
        let rate = max(1, sampleRate)
        let count = max(0, sources)
        self.sampleRate = rate
        sourceCount = count
        positions = [StagePosition](repeating: .neutral, count: count)
        var length = 16
        while length < Int((0.03 * Double(rate)).rounded(.up)) + 2 { length *= 2 }
        size = length
        mask = length - 1
        lines = [Float](repeating: 0, count: count * 2 * length)
        lowpass = [Float](repeating: 0, count: count * 2)
        lowpassCoefficient = Float(1 - exp(-2 * Double.pi * 4000 / Double(rate)))
        taps = StagePlacer.reflectionTimes.map { Int(($0 * Double(rate)).rounded()) }
    }

    /// The delay, in samples, of the far side for a source at `azimuth` degrees.
    public func delaySamples(azimuth: Float) -> Int {
        let a = Double(min(90, max(-90, azimuth))) * Double.pi / 180
        return Int((StagePlacer.maxDelay * Double(sampleRate) * abs(sin(a))).rounded())
    }

    /// `sources[i]` is source i: one channel (mono) or two (left, right). All channels should
    /// be the same length; the shortest decides. Sources beyond `sourceCount` are ignored.
    public func process(_ sources: [[[Float]]]) -> (left: [Float], right: [Float]) {
        let used = min(sources.count, sourceCount)
        var n = Int.max
        for s in 0..<used {
            for channel in sources[s] { n = min(n, channel.count) }
            if sources[s].isEmpty { n = 0 }
        }
        if used == 0 || n == Int.max { n = 0 }
        var outLeft = [Float](repeating: 0, count: n)
        var outRight = [Float](repeating: 0, count: n)
        if n == 0 { return (outLeft, outRight) }

        struct Setting {
            var gainLeft: Float, gainRight: Float, delay: Int, right: Bool
            var width: Float, depth: Float, gain: Float
        }
        var settings: [Setting] = []
        for s in 0..<used {
            let p = s < positions.count ? positions[s] : .neutral
            let az = min(90, max(-90, p.azimuth))
            let theta = (Double(az) / 90 + 1) * Double.pi / 4
            let depth = min(1, max(0, p.depth))
            settings.append(Setting(gainLeft: Float(2.0.squareRoot() * cos(theta)),
                                    gainRight: Float(2.0.squareRoot() * sin(theta)),
                                    delay: delaySamples(azimuth: az), right: az > 0,
                                    width: min(2, max(0, p.width)), depth: depth,
                                    gain: p.gain * (1 - 0.35 * depth)))
        }
        let a = lowpassCoefficient
        let g = master
        for i in 0..<n {
            let now = at
            var sumLeft: Float = 0
            var sumRight: Float = 0
            for s in 0..<used {
                let source = sources[s]
                let cfg = settings[s]
                let l = source[0][i]
                let r = source.count > 1 ? source[1][i] : l
                let mid = (l + r) / 2
                let side = (l - r) / 2
                var l1 = (mid + cfg.width * side) * cfg.gain
                var r1 = (mid - cfg.width * side) * cfg.gain
                lowpass[s * 2] += a * (l1 - lowpass[s * 2])
                lowpass[s * 2 + 1] += a * (r1 - lowpass[s * 2 + 1])
                l1 += 0.7 * cfg.depth * (lowpass[s * 2] - l1)
                r1 += 0.7 * cfg.depth * (lowpass[s * 2 + 1] - r1)
                let pl = l1 * cfg.gainLeft
                let pr = r1 * cfg.gainRight
                let lineLeft = (s * 2) * size
                let lineRight = (s * 2 + 1) * size
                lines[lineLeft + now] = pl
                lines[lineRight + now] = pr
                var ol = cfg.right ? lines[lineLeft + ((now - cfg.delay) & mask)] : pl
                var or = cfg.right ? pr : lines[lineRight + ((now - cfg.delay) & mask)]
                if cfg.depth > 0 {
                    for t in 0..<taps.count {
                        let reflection = cfg.depth * StagePlacer.reflectionGains[t]
                        let back = (now - taps[t]) & mask
                        /* each side hears the other side's sound, a little later and quieter */
                        ol += reflection * lines[lineRight + back]
                        or += reflection * lines[lineLeft + back]
                    }
                }
                sumLeft += ol
                sumRight += or
            }
            outLeft[i] = sumLeft * g
            outRight[i] = sumRight * g
            at = (now + 1) & mask
        }
        return (outLeft, outRight)
    }
}
