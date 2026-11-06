import Foundation

/// What the lock screen, the Dynamic Island and CarPlay show for a song.
public struct NowPlayingMeta: Equatable {
    public var title: String
    public var artist: String
    public var artwork: String
    public var duration: Double

    public init(title: String, artist: String, artwork: String, duration: Double) {
        self.title = title
        self.artist = artist
        self.artwork = artwork
        self.duration = duration
    }
}

/// Keeps the page from putting the previous song back on the lock screen after the app has moved
/// on to the next song by itself (end of a song, or the hand-over of a mix).
///
/// The page learns of such a change a moment later than the app (it even holds the "advanced"
/// event back during a mix) and in between still describes its old song: the player's "playing"
/// event makes it send `meta` and `dur` for that song. Those must not replace the new song's.
///
/// - A message that names its song (`id`) is taken only for the song being heard.
/// - Without an id, for a while after a change made by the app (`window` seconds) a description
///   that is the previous song's (same title and artist; or for `dur` the same length) is
///   dropped. The first different description ends that.
public struct NowPlayingGuard {
    public static let window = 15.0

    private var previous: NowPlayingMeta?
    private var until = 0.0
    /// A description the page sent for a song that is not playing yet (it describes the song it
    /// has just chosen before asking for it): kept until that song starts.
    private var held: (id: String, meta: NowPlayingMeta)?

    public init() {}

    /// The app has moved on by itself from the song described by `old`.
    public mutating func advancedBySelf(from old: NowPlayingMeta, now: Double) {
        previous = old
        until = now + NowPlayingGuard.window
    }

    /// The page chose a song itself: whatever it says now is about the right song.
    public mutating func pageChose() {
        previous = nil
    }

    public mutating func acceptMeta(_ m: NowPlayingMeta, id: String?, current: String?, now: Double) -> Bool {
        if let id = id, !id.isEmpty, let current = current { return id == current }
        guard let p = previous, now < until else { return true }
        if m.title == p.title && m.artist == p.artist { return false }
        previous = nil
        return true
    }

    /// Keeps a description that named a song other than the current one.
    public mutating func hold(_ m: NowPlayingMeta, id: String) {
        held = (id, m)
    }

    /// The kept description, when it is for the song that has just become the current one.
    public mutating func takeHeld(for current: String?) -> NowPlayingMeta? {
        guard let h = held, let current = current, h.id == current else { return nil }
        held = nil
        return h.meta
    }

    public func acceptDuration(_ seconds: Double, id: String?, current: String?, now: Double) -> Bool {
        if let id = id, !id.isEmpty, let current = current { return id == current }
        guard let p = previous, now < until, p.duration > 0 else { return true }
        return abs(seconds - p.duration) >= 0.5
    }
}
