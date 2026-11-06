import Foundation

/// How much of a song has really been listened to, counted from the position the player reports.
///
/// A song counts as played once 30 s of it were heard (or half of a short one). Jumps of more
/// than 2 s are seeking, not listening. A song that is started again after it was counted
/// (the position goes back to its beginning) counts again.
public struct ListenCounter {
    public static let need = 30.0

    private var id = ""
    private var heard = 0.0
    private var last = -1.0
    private var done = false

    public init() {}

    /// Feed the player's position. Returns true, once per time a song is played, when it counts.
    public mutating func feed(id newID: String, position t: Double, playing: Bool, duration: Double) -> Bool {
        if newID != id {
            id = newID
            heard = 0
            last = -1
            done = false
        }
        guard playing, t.isFinite else {
            last = -1
            return false
        }
        if done {
            /* back at the start of a song that was counted: a new play */
            if last >= 0 && t + 5 < last && t < 5 {
                heard = 0
                done = false
            } else {
                last = t
                return false
            }
        }
        let step = last < 0 ? 0 : t - last
        last = t
        if step > 0 && step <= 2 { heard += step }
        if heard >= ListenCounter.need || (duration > 0 && heard >= duration / 2) {
            done = true
            return true
        }
        return false
    }
}
