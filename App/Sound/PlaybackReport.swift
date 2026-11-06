import Foundation

/// What the system (lock screen, Control Centre, CarPlay) is told about playing or paused.
///
/// Inside the app a song change, a download wait, a seek or a mix hand-over all stop and start
/// the sound for a moment. None of that may reach the system: CarPlay reacts to the reported
/// state changing (it can leave the Now Playing screen). Only a real pause is reported.
///
/// - A pause from the lock screen, CarPlay, an interruption or lost headphones is reported at
///   once (`immediate`).
/// - A pause from the page is held for `pageGrace` seconds: the page pauses the player before
///   every song change (and the user may tap play again). A play within that time cancels it,
///   and the system never sees the pause.
/// - A play is reported at once.
public struct PlaybackReport {
    public static let pageGrace = 1.5

    public enum Source: String {
        case immediate
        case page
    }

    /// What the system has been told.
    public private(set) var playing = false
    /// When a held page pause becomes real.
    public private(set) var pendingPauseAt: Double?

    public init() {}

    /// Something wants the sound on or off. Returns the new reported state when it changes now.
    public mutating func want(_ play: Bool, source: Source, now: Double) -> Bool? {
        if play {
            pendingPauseAt = nil
            if playing { return nil }
            playing = true
            return true
        }
        guard playing else {
            pendingPauseAt = nil
            return nil
        }
        if source == .page {
            if pendingPauseAt == nil { pendingPauseAt = now + PlaybackReport.pageGrace }
            return nil
        }
        pendingPauseAt = nil
        playing = false
        return false
    }

    /// Call when a held pause may be due. Returns false when the pause is now reported.
    public mutating func resolve(now: Double) -> Bool? {
        guard let at = pendingPauseAt, now >= at - 1e-9 else { return nil }
        pendingPauseAt = nil
        guard playing else { return nil }
        playing = false
        return false
    }
}
