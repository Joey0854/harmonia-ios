import Foundation

/// A small running log of what the app itself does (downloads, player, engine, events sent to
/// the page), for finding faults on a real phone without a Mac:
///
/// - kept in memory and in `Caches/diag.log` (the last 300 lines);
/// - sent to the PC's debug log when the PC can be reached (`<pc>/api/debug`, the same
///   place the page logs to), every 5 seconds while there is something new and at once after
///   an error; failures are ignored and followed by a minute of silence;
/// - sent the same way to a report receiver when one is set (`reportBase`, its own setting,
///   so that setting it never makes the page use a PC), which also gets whole reports
///   (`<report>/api/report`: version, device, settings and the whole log) when the app goes
///   to the background, after songs (at most every 2 minutes), on request, and at start when
///   the last run ended without going to the background (with that run's log);
/// - shown to the page on request (`{cmd: "diag"}` -> `{type: "diag", text}`);
/// - shown on the phone itself: tap three times with two fingers (PlayerViewController).
///
/// Values of cookies, tokens and keys are masked before a line is kept.
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

    /* One place lines are sent to, with its own backlog and quiet time. */
    private final class Sink {
        var url: URL?
        var unsent: [Entry] = []
        var sending = false
        var quietUntil = Date.distantPast
        init(_ url: URL?) { self.url = url }
    }

    private let queue = DispatchQueue(label: "diag")
    private var lines: [String] = []
    private var counter = 0
    private var dirty = false
    private var timer: DispatchSourceTimer?
    private let file: URL
    private let session: URLSession
    private let reportSession: URLSession
    private let sid: String
    private let clock: DateFormatter
    private let pc: Sink
    private let receiver: Sink
    private var reportBase: URL?
    private var lastSongReport = Date.distantPast
    private var settings: [String: Any] = [:]
    /// The log the previous run left behind (read before this run adds to it).
    private let previousLog: String

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        file = caches.appendingPathComponent("diag.log")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 3
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
        let slow = URLSessionConfiguration.ephemeral
        slow.timeoutIntervalForRequest = 10
        slow.timeoutIntervalForResource = 10
        slow.waitsForConnectivity = false
        reportSession = URLSession(configuration: slow)
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
        var server: URL?
        if let text = text, let base = URL(string: text) {
            server = URL(string: "/api/debug", relativeTo: base)?.absoluteURL
        }
        pc = Sink(server)
        reportBase = Diag.validBase(UserDefaults.standard.string(forKey: Diag.reportKey) ?? "")
        receiver = Sink(reportBase.flatMap { URL(string: "/api/debug", relativeTo: $0)?.absoluteURL })
        let old = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        previousLog = old
        lines = Array(old.split(separator: "\n").map { String($0) }.suffix(Diag.maxLines))
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        log("app \(Diag.version) (\(Diag.build)) started, session \(sid)")
    }

    static var version: String { return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
    static var build: String { return Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }

    /// Where the PC's address is remembered (UserDefaults).
    static let pcKey = "pcBase"
    /// Where the report receiver's address is remembered (UserDefaults); empty = none.
    static let reportKey = "reportBase"
    /// "running" while the app is in front, "background" once it went there (UserDefaults).
    static let runKey = "diagRunState"

    /// The PC has moved: send the log there from now on, starting at once.
    func setServer(_ base: URL) {
        queue.async {
            self.pc.url = URL(string: "/api/debug", relativeTo: base)?.absoluteURL
            self.pc.quietUntil = Date.distantPast
        }
    }

    /// An http(s) address with a host, without what follows it; nil otherwise.
    static func validBase(_ text: String) -> URL? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, let u = URLComponents(string: s), let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = u.host, !host.isEmpty else { return nil }
        var c = URLComponents()
        c.scheme = scheme
        c.host = host
        c.port = u.port
        return c.url
    }

    /// Sets the report receiver ("" turns it off). Returns the address kept, or nil if the text
    /// was not a usable address (then nothing changes).
    func setReportBase(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? nil : Diag.validBase(trimmed)
        if !trimmed.isEmpty && base == nil { return nil }
        UserDefaults.standard.set(base?.absoluteString ?? "", forKey: Diag.reportKey)
        queue.async {
            self.reportBase = base
            self.receiver.url = base.flatMap { URL(string: "/api/debug", relativeTo: $0)?.absoluteURL }
            self.receiver.unsent.removeAll()
            self.receiver.quietUntil = Date.distantPast
        }
        log("diag: report receiver \(base?.absoluteString ?? "off")")
        return base?.absoluteString ?? ""
    }

    var reportAddress: String { return UserDefaults.standard.string(forKey: Diag.reportKey) ?? "" }

    /// One of the settings reports describe (mode, profile, eq, loudness).
    func setSetting(_ key: String, _ value: Any) {
        queue.async { self.settings[key] = value }
    }

    func log(_ text: String, error: Bool = false, song: String = "-") {
        let now = Date()
        let clean = Diag.mask(text)
        queue.async {
            self.counter += 1
            let entry = Entry(time: now, error: error, song: song, text: clean, number: self.counter)
            self.lines.append("\(self.clock.string(from: now)) \(error ? "E" : "I") \(song) \(clean)")
            if self.lines.count > Diag.maxLines { self.lines.removeFirst(self.lines.count - Diag.maxLines) }
            for sink in [self.pc, self.receiver] where sink.url != nil {
                sink.unsent.append(entry)
                if sink.unsent.count > Diag.maxLines { sink.unsent.removeFirst(sink.unsent.count - Diag.maxLines) }
            }
            self.dirty = true
            if error { self.tick() }
        }
    }

    /* Cookie, token and key values never reach the log. */
    private static let secret = try? NSRegularExpression(
        pattern: "(?i)(cookie|set-cookie|authorization|bearer|token|access_token|refresh_token|sapisid|apisid|ssid|hsid|sid|__secure-[a-z0-9_-]+|login_info|key|password|sig)([=:]\\s*)([^\\s;&,\"']+)")

    private static let bearer = try? NSRegularExpression(pattern: "(?i)(bearer)\\s+[^\\s\"']+")

    static func mask(_ text: String) -> String {
        var out = text
        if let re = bearer {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1 …")
        }
        if let re = secret {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1$2…")
        }
        return out
    }

    /// The last lines of the log as one text.
    func tail(_ count: Int) -> String {
        return queue.sync { lines.suffix(count).joined(separator: "\n") }
    }

    /// Runs on `queue`: writes the file and sends what the PC and the receiver have not seen yet.
    private func tick() {
        if dirty {
            dirty = false
            try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        }
        for sink in [pc, receiver] { send(sink) }
    }

    private func send(_ sink: Sink) {
        guard let server = sink.url, !sink.sending, !sink.unsent.isEmpty, Date() >= sink.quietUntil else { return }
        let batch = sink.unsent
        sink.unsent.removeAll()
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
        sink.sending = true
        session.dataTask(with: request) { [weak self] _, response, _ in
            guard let self = self else { return }
            self.queue.async {
                sink.sending = false
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status < 200 || status >= 300 {
                    /* Off or out of reach: keep the lines for later and stay quiet a while. */
                    sink.quietUntil = Date().addingTimeInterval(60)
                    sink.unsent = Array((batch + sink.unsent).suffix(Diag.maxLines))
                }
            }
        }.resume()
    }

    // MARK: - reports

    /// Whether the last run ended while the app was in front (a crash, or killed by the
    /// system), as noted at the start of this run. Call once, early.
    func noteStart() -> Bool {
        let before = UserDefaults.standard.string(forKey: Diag.runKey)
        UserDefaults.standard.set("running", forKey: Diag.runKey)
        return before == "running"
    }

    func noteBackground(_ inBackground: Bool) {
        UserDefaults.standard.set(inBackground ? "background" : "running", forKey: Diag.runKey)
    }

    /// After a song: a report, unless one went less than 2 minutes ago.
    func songEnded() {
        queue.async {
            guard self.reportBase != nil, Date().timeIntervalSince(self.lastSongReport) >= 120 else { return }
            self.lastSongReport = Date()
            self.report(trigger: "songEnd", previous: false, done: nil)
        }
    }

    /// Sends a report now: trigger is background, songEnd, manual or lastRunEnded. `done` gets
    /// nil when it went through, otherwise why not (on any queue). No retry.
    func sendReport(trigger: String, done: ((String?) -> Void)? = nil) {
        queue.async { self.report(trigger: trigger, previous: trigger == "lastRunEnded", done: done) }
    }

    /* On `queue`. */
    private func report(trigger: String, previous: Bool, done: ((String?) -> Void)?) {
        guard let base = reportBase, let url = URL(string: "/api/report", relativeTo: base)?.absoluteURL else {
            done?("no report address set")
            return
        }
        var info: [String: Any] = [
            "sid": sid, "version": Diag.version, "build": Diag.build, "device": Diag.machine,
            "ios": Diag.osVersion, "trigger": trigger,
            "settings": settings, "log": lines.joined(separator: "\n")
        ]
        if previous { info["lastLog"] = Diag.mask(previousLog) }
        guard let body = try? JSONSerialization.data(withJSONObject: info) else {
            done?("report could not be encoded")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        reportSession.dataTask(with: request) { [weak self] _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let problem: String? = (200..<300).contains(status) ? nil : (error.map { "\($0.localizedDescription)" } ?? "HTTP \(status)")
            self?.log("diag: report (\(trigger)) " + (problem.map { "not sent: \($0)" } ?? "sent, \(body.count) bytes"), error: false)
            done?(problem)
        }.resume()
    }

    /// GET <base>/api/ping, expecting 200 and {"ok": true}. `done` gets nil or what went wrong.
    func ping(_ text: String, done: @escaping (String?) -> Void) {
        guard let base = Diag.validBase(text), let url = URL(string: "/api/ping", relativeTo: base)?.absoluteURL else {
            done("not an http(s) address with a host")
            return
        }
        reportSession.dataTask(with: url) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let e = error { return done(e.localizedDescription) }
            guard status == 200 else { return done("HTTP \(status)") }
            let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            done(object?["ok"] as? Bool == true ? nil : "answer is not {\"ok\":true}")
        }.resume()
    }

    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// The model code, e.g. iPhone15,2.
    static var machine: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
