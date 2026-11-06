import Foundation

/// Songs that were listened to while the page could not write them down (the screen is off, the
/// phone is in a car). The app counts the listening itself and keeps the songs here until the
/// page asks for them.
final class PlayHistory {
    static let shared = PlayHistory()

    private let key = "ytm_pending_history"
    private let queue = DispatchQueue(label: "ytm.history")

    func add(_ entry: [String: Any]) {
        queue.sync {
            var list = UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? []
            list.append(entry)
            if list.count > 300 { list.removeFirst(list.count - 300) }
            UserDefaults.standard.set(list, forKey: key)
        }
    }

    /// Everything waiting, oldest first; the store is emptied.
    func drain() -> [[String: Any]] {
        return queue.sync {
            let list = UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? []
            UserDefaults.standard.removeObject(forKey: key)
            return list
        }
    }
}
