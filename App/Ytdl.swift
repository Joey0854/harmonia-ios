import Foundation

/// `ytdl://<videoId>`: a song the page knows the id of, but whose playable
/// address only the app can find. yt-dlp runs inside the app (see PythonBridge),
/// so no PC is needed; when it fails, the PC is used as before.
///
/// Main queue only. Callbacks arrive on the main queue.
final class Ytdl {
    static let shared = Ytdl()

    static let scheme = "ytdl"

    struct Stream {
        let url: URL
        let headers: [String: String]
        let size: Int64
        let duration: Double
        let mime: String
    }

    /// Where the PC is. Only used when the app's own yt-dlp cannot answer.
    var pcBase: URL?

    private let work = DispatchQueue(label: "ytm.ytdl", qos: .userInitiated)
    private var cache: [String: (stream: Stream, until: Date)] = [:]
    private var waiting: [String: [(Stream?, String?) -> Void]] = [:]
    /// Recent failures, so a song that cannot be extracted is not retried at once.
    private var failed: [String: (message: String, at: Date)] = [:]

    private init() {}

    /// `ytdl://BAW_jenozKc` -> `BAW_jenozKc`; nil for any other address.
    static func videoID(from url: URL?) -> String? {
        guard let url = url, url.scheme?.lowercased() == scheme else { return nil }
        return url.host
    }

    static func isYtdl(_ url: URL?) -> Bool {
        return url?.scheme?.lowercased() == scheme
    }

    static func address(for id: String) -> String {
        return "\(scheme)://\(id)"
    }

    /// Finds the song's address. Answers with a stream, or with a message.
    func resolve(id: String, done: @escaping (Stream?, String?) -> Void) {
        let now = Date()
        if let entry = cache[id], entry.until > now {
            done(entry.stream, nil)
            return
        }
        /* A song that just failed is answered at once: the PC fallback would only sit in a
           30-second timeout when the PC is away too. */
        if let failure = failed[id], now.timeIntervalSince(failure.at) < 60 {
            done(nil, failure.message)
            return
        }
        if waiting[id] != nil {
            waiting[id]?.append(done)
            return
        }
        waiting[id] = [done]
        Diag.shared.log("ytdl: looking up \(id)", song: id)
        let base = pcBase
        work.async {
            let started = Date()
            let answer = PythonBridge.shared.extract(id)
            let took = Date().timeIntervalSince(started)
            /* Only fall back to the PC when it is really there; otherwise the song fails now
               instead of after the download's own 30-second timeout. */
            var pcUp = false
            if (answer?["ok"] as? Bool) != true, let base = base {
                pcUp = Ytdl.reachable(base)
            }
            DispatchQueue.main.async {
                self.finish(id: id, answer: answer, took: took, pcUp: pcUp)
            }
        }
    }

    /// A quick "is the PC answering at all" (it answers /api/ir/bases without any work).
    static func reachable(_ base: URL) -> Bool {
        var request = URLRequest(url: base.appendingPathComponent("api/ir/bases"))
        request.timeoutInterval = 2.5
        let done = DispatchSemaphore(value: 0)
        var ok = false
        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            ok = (response as? HTTPURLResponse)?.statusCode == 200
            done.signal()
        }
        task.resume()
        _ = done.wait(timeout: .now() + 3)
        task.cancel()
        return ok
    }

    private func finish(id: String, answer: [String: Any]?, took: TimeInterval, pcUp: Bool) {
        let callbacks = waiting.removeValue(forKey: id) ?? []
        var stream: Stream?
        var message: String?
        if let answer = answer, (answer["ok"] as? Bool) == true,
           let text = answer["url"] as? String, let url = URL(string: text) {
            var headers: [String: String] = [:]
            let given = answer["headers"] as? [String: Any] ?? [:]
            for (name, value) in given {
                if let value = value as? String { headers[name] = value }
            }
            let size = (answer["size"] as? NSNumber)?.int64Value ?? 0
            let duration = (answer["duration"] as? NSNumber)?.doubleValue ?? 0
            let mime = answer["mime"] as? String ?? "audio/mp4"
            let expires = (answer["expires"] as? NSNumber)?.doubleValue ?? 0
            stream = Stream(url: url, headers: headers, size: size, duration: duration, mime: mime)
            /* Addresses last hours; stop trusting it well before YouTube does. */
            let until = expires > 0
                ? Date(timeIntervalSince1970: min(expires - 300, Date().timeIntervalSince1970 + 4 * 3600))
                : Date().addingTimeInterval(2 * 3600)
            if let stream = stream { cache[id] = (stream, until) }
            Diag.shared.log("ytdl: \(id) ready in \(String(format: "%.1f", took)) s, \(size) bytes, \(mime)", song: id)
        } else {
            message = (answer?["error"] as? String) ?? "yt-dlp returned nothing"
            failed[id] = (message!, Date())
            Diag.shared.log("ytdl: \(id) failed: \(message!)", error: true, song: id)
            stream = pcUp ? fallback(id: id, reason: message!) : nil
            if stream == nil {
                Diag.shared.log("ytdl: \(id) no PC to fall back to", error: true, song: id)
            }
        }
        for callback in callbacks {
            callback(stream, stream == nil ? message : nil)
        }
    }

    /// The PC's own copy of the song, when the app cannot extract it itself.
    private func fallback(id: String, reason: String) -> Stream? {
        guard let base = pcBase else {
            Diag.shared.log("ytdl: \(id) no PC to fall back to", error: true, song: id)
            return nil
        }
        var parts = URLComponents(url: base.appendingPathComponent("media/\(id).m4a"),
                                  resolvingAgainstBaseURL: false)
        parts?.queryItems = [URLQueryItem(name: "mode", value: "phone")]
        guard let url = parts?.url else { return nil }
        Diag.shared.log("ytdl: \(id) using the PC instead (\(reason.prefix(80)))", song: id)
        return Stream(url: url, headers: [:], size: 0, duration: 0, mime: "audio/mp4")
    }

    /// Forgets a cached address, e.g. after a 403: the page asks again.
    func invalidate(id: String) {
        cache.removeValue(forKey: id)
    }
}
