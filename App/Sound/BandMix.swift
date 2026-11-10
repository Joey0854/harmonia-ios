import Foundation

/// The page's mixer for the band modes: per separated part a volume, solo / mute and (on the
/// speaker stage) a position. Kept apart from `SurroundSettings` so that changing it never
/// restarts the processing or the network: every `BandProcessor` reads the latest version each
/// time it hands sound on, so a change is heard from the sound not yet handed to the player.
public struct BandPart: Equatable {
    /// A plain factor (0 … 1.5 from the page).
    public var gain: Float
    public var solo: Bool
    public var mute: Bool
    /// Azimuth −90 … 90, depth 0 … 1, width 0 … 2 (the gain inside is not used).
    public var position: StagePosition

    public init(gain: Float = 1, solo: Bool = false, mute: Bool = false, position: StagePosition = .neutral) {
        self.gain = gain
        self.solo = solo
        self.mute = mute
        self.position = position
    }
}

public struct BandMixSettings {
    /// True: meant for `bandHead` (the positions are already in `irs`); false: `band`.
    public var headphones: Bool
    /// In `Demucs.sources` order.
    public var parts: [BandPart]
    /// For `bandHead`: one pair of impulse responses (WAV) per part for these positions, or nil.
    public var irs: [(left: Data, right: Data)]?
    /// For `bandCar`: what the car mode does with the parts (nil for the other modes).
    public var car: CarBandParams?

    public init(headphones: Bool, parts: [BandPart], irs: [(left: Data, right: Data)]? = nil, car: CarBandParams? = nil) {
        self.headphones = headphones
        self.parts = parts
        self.irs = irs
        self.car = car
    }

    /// What each part is multiplied by: muted parts and, when any part is soloed, all the
    /// others are silent.
    public var effectiveGains: [Float] {
        let anySolo = parts.contains { $0.solo }
        return (0..<4).map { i in
            guard i < parts.count else { return anySolo ? 0 : 1 }
            let p = parts[i]
            if p.mute || (anySolo && !p.solo) { return 0 }
            return max(0, min(2, p.gain))
        }
    }
}

/// The one mixer setting all band processors follow (thread-safe).
public final class BandMix {
    public static let shared = BandMix()

    private let lock = NSLock()
    private var settings: BandMixSettings?
    private var version = 0
    private var irVersion = 0

    public init() {}

    public func set(_ new: BandMixSettings) {
        lock.lock()
        settings = new
        version += 1
        if new.irs != nil { irVersion += 1 }
        lock.unlock()
    }

    /// The latest setting (nil: none came yet), its version and the version of its responses.
    public func current() -> (settings: BandMixSettings?, version: Int, irVersion: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (settings, version, irVersion)
    }
}

/// What the band modes are doing, for the page.
public enum BandStatus: Equatable {
    case off
    /// Model loading or the first segment being separated.
    case loading
    /// Separated in time; the last segment took `seconds`, `realtime` times faster than playback.
    case running(seconds: Double, realtime: Double)
    /// Separation fell behind: the original sound is playing for now.
    case late
    case failed(String)
    /// Separation held back (`hot`: the phone is too warm); what is ready plays.
    case paused(String)
}
