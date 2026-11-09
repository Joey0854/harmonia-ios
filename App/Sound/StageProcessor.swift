import Foundation

/// The page's three stage controls, each 0 … 100. All at 0 the sound is left as it is.
public struct StageParams: Equatable {
    /// How far the sources are spread beyond the two speakers.
    public var width: Float
    /// How far back the stage is (side and ambience parts most, the centre a little).
    public var depth: Float
    /// How far the centre (lead vocal) comes forward: louder, narrower, closer.
    public var vocal: Float

    public init(width: Float = 0, depth: Float = 0, vocal: Float = 0) {
        self.width = width
        self.depth = depth
        self.vocal = vocal
    }

    public static let neutral = StageParams()
}

/// "Stage" surround without impulse responses: `StageSplitter` cuts the stereo recording into
/// five rough sources and `StagePlacer` puts them on a virtual stage in front of the listener.
/// Meant for a car's two speakers, where head-related responses fall apart because each ear
/// hears both speakers.
///
/// Output sample n belongs to input sample n. Output comes in steps of 512 samples; `finish`
/// returns the rest. Do not use it after `finish`.
public final class StageProcessor {
    public let params: StageParams
    private let splitter: StageSplitter
    private let placer: StagePlacer

    public init(params: StageParams, sampleRate: Int) {
        self.params = params
        splitter = StageSplitter(sampleRate: sampleRate)
        placer = StagePlacer(sources: StageSplitter.sourceCount, sampleRate: sampleRate)
        placer.positions = StageProcessor.positions(for: params)
        placer.master = StageProcessor.master(for: params)
    }

    /// Where the splitter's five sources (low, center, sideL, sideR, ambience) go.
    public static func positions(for p: StageParams) -> [StagePosition] {
        let w = min(100, max(0, p.width)) / 100
        let d = min(100, max(0, p.depth)) / 100
        let v = min(100, max(0, p.vocal)) / 100
        return [
            /* bass stays in the middle and becomes mono as the stage widens */
            StagePosition(azimuth: 0, depth: 0, width: 1 - w, gain: 1),
            StagePosition(azimuth: 0, depth: 0.3 * d * (1 - v), width: 1 - 0.5 * v, gain: 1 + 0.4 * v),
            StagePosition(azimuth: -30 * w, depth: 0.5 * d, width: 1 + 0.4 * w, gain: 1),
            StagePosition(azimuth: 30 * w, depth: 0.5 * d, width: 1 + 0.4 * w, gain: 1),
            StagePosition(azimuth: 0, depth: d, width: 1 + 0.6 * w, gain: 1)
        ]
    }

    /// Depth makes everything quieter; this brings the whole back up (1 at depth 0).
    public static func master(for p: StageParams) -> Float {
        return 1 / (1 - 0.4 * min(100, max(0, p.depth)) / 100)
    }

    public func process(left: [Float], right: [Float]) -> (left: [Float], right: [Float]) {
        return placer.process(splitter.process(left: left, right: right))
    }

    public func finish() -> (left: [Float], right: [Float]) {
        return placer.process(splitter.flush())
    }
}
