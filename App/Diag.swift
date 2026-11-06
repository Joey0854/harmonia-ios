import Foundation

/// A small running log of what the app itself does (downloads, player, engine, events sent to
/// the page), for finding faults on a real phone without a Mac:
///
/// - kept in memory and in `Caches/diag.log` (the last 300 lines);
/// - sent to the PC's debug log when the PC can be reached (`<pc>/api/debug`, the same
///   place the page logs to), every 5 seconds while there is something new and at once after
///   an error; failures are ignored and followed by a minute of silence;
/// - shown to the page on request (`{cmd: "diag"}` -> `{type: "diag", text}`);
/// - shown on the phone itself: tap three times with two fingers (PlayerViewController).
///
/// Safe to call from any queue.
final class Diag {
    static let shared = Diag()

    private static let maxLines = 300

    private struct Entry {
        let time: Date
        let error: Bool
        let song: String
        let text: String
        let number: Int
    }

    private let queue = DispatchQueue(label: "diag")
    private var lines: [String] = []
    private var unsent: [Entry] = []
    private var counter = 0
    private var dirty = false
    private var sending = false
    private var quietUntil = Date.distantPast
    private var timer: DispatchSourceTimer?
    private let file: URL
    private let session: URLSession
    private let sid: String
    private let clock: DateFormatter
    private var server: URL?

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        file = caches.appendingPathComponent("diag.log")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 3
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
        /* The PC's log keeps letters and digits of the session name only. */
        let letters = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        sid = "app" + String((0..<4).map { _ in letters[Int.random(in: 0..<letters.count)] })
        clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "HH:mm:ss.SSS"
        /* The PC's address: the one the user set in the page (kept by the `config` command),
           otherwise the one built into the app. */
        let text = UserDefaults.standard.string(forKey: Diag.pcKey)
            ?? Bundle.main.object(forInfoDictionaryKey: "ServerURL") as? String
        if let text = text, let base = URL(string: text) {
            server = URL(string: "/api/debug", relativeTo: base)?.absoluteURL
        }
        if let old = try? String(contentsOf: file, encoding: .utf8) {
            lines = Array(old.split(separator: "\n").map { String($0) }.suffix(Diag.maxLines))
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        log("app \(version) (\(build)) started, session \(sid)")
    }

    /// Where the PC's address is remembered (UserDefaults).
    static let pcKey = "pcBase"

    /// The PC has moved: send the log there from now on, starting at once.
    func setServer(_ base: URL) {
        queue.async {
            self.server = URL(string: "/api/debug", relativeTo: base)?.absoluteURL
            self.quietUntil = Date.distantPast
        }
    }

    func log(_ text: String, error: Bool = false, song: String = "-") {
        let now = Date()
        queue.async {
            self.counter += 1
            let entry = Entry(time: now, error: error, song: song, text: text, number: self.counter)
            self.lines.append("\(self.clock.string(from: now)) \(error ? "E" : "I") \(song) \(text)")
            if self.lines.count > Diag.maxLines { self.lines.removeFirst(self.lines.count - Diag.maxLines) }
            self.unsent.append(entry)
            if self.unsent.count > Diag.maxLines { self.unsent.removeFirst(self.unsent.count - Diag.maxLines) }
            self.dirty = true
            if error { self.tick() }
        }
    }

    /// The last lines of the log as one text.
    func tail(_ count: Int) -> String {
        return queue.sync { lines.suffix(count).joined(separator: "\n") }
    }

    /// Runs on `queue`: writes the file and sends what the PC has not seen yet.
    private func tick() {
        if dirty {
            dirty = false
            try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        }
        guard let server = server, !sending, !unsent.isEmpty, Date() >= quietUntil else { return }
        let batch = unsent
        unsent.removeAll()
        /* The shape the PC's debugWrite() reads: t time, l level, n number, k kind, v song,
           d details. */
        let items: [[String: Any]] = batch.map { e in
            ["t": Int(e.time.timeIntervalSince1970 * 1000), "l": e.error ? "E" : "I", "n": e.number,
             "k": "native", "v": e.song, "p": 0, "d": ["m": e.text]]
        }
        guard let body = try? JSONSerialization.data(withJSONObject: ["sid": sid, "items": items]) else { return }
        var request = URLRequest(url: server)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        sending = true
        session.dataTask(with: request) { [weak self] _, response, _ in
            guard let self = self else { return }
            self.queue.async {
                self.sending = false
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status < 200 || status >= 300 {
                    /* The PC is off or out of reach: keep the lines for later and stay quiet a while. */
                    self.quietUntil = Date().addingTimeInterval(60)
                    self.unsent = Array((batch + self.unsent).suffix(Diag.maxLines))
                }
            }
        }.resume()
    }
}
