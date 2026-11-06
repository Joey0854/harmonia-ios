import Foundation

/// Downloads one file as consecutive 1 MB `Range` requests.
///
/// Why pieces: progress can be shown, a piece that fails is asked for again without starting
/// over, and the PC server (which itself fetches the song in 1 MB pieces) answers each at once.
/// Measured against it: a 3.4 MB song in four pieces takes about 0.35 s on the same machine.
/// It also copes with a server that ignores the range and sends the whole file, and with one
/// that does not say how long the file is.
///
/// The data goes to a temporary file next to the target and is renamed when complete, so a
/// file with the final name is always a whole song. Callbacks arrive on the main queue.
/// `onDone` gets nil on success or a message on failure; after `cancel()` nothing is called.
final class RangedDownload {
    static let chunkSize: Int64 = 1 << 20
    private static let maxRetries = 2

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    private let label: String
    private let url: URL
    private let headers: [String: String]
    private let target: URL
    /// Unique per download, so a cancelled download cleaning up can never delete the file of a
    /// newer download of the same song.
    private let partURL: URL
    private let onProgress: (Int64, Int64) -> Void
    private let onDone: (String?) -> Void

    /* Everything below is only touched on `queue`. */
    private let queue = DispatchQueue(label: "ranged-download")
    private var total: Int64
    private var received: Int64 = 0
    private var file: FileHandle?
    private var task: URLSessionDataTask?
    private var finished = false
    private var lastReport = Date.distantPast

    /// `size` is the length of the file when the caller knows it, otherwise 0 (it is then read
    /// from the first answer).
    /// `label` (the song id) only marks the lines this download writes to the log.
    init(label: String, url: URL, headers: [String: String], size: Int64, target: URL,
         onProgress: @escaping (Int64, Int64) -> Void, onDone: @escaping (String?) -> Void) {
        self.label = label
        self.url = url
        self.headers = headers
        self.total = max(0, size)
        self.target = target
        self.partURL = target.deletingLastPathComponent()
            .appendingPathComponent(target.lastPathComponent + "." + UUID().uuidString + ".part")
        self.onProgress = onProgress
        self.onDone = onDone
    }

    /// Deletes temporary files left behind when the app was closed in the middle of a download.
    static func removeLeftovers(in folder: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasSuffix(".part") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /* The closures below hold `self` on purpose: the download keeps itself alive until it
       finishes, fails or is cancelled, and each closure is released once it has run. */

    func start() {
        queue.async { self.begin() }
    }

    func cancel() {
        queue.async {
            if self.finished { return }
            self.finished = true
            self.task?.cancel()
            self.task = nil
            self.cleanUp()
        }
    }

    private func begin() {
        if finished { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.createFile(atPath: partURL.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: partURL) else {
            fail("cannot create file \(partURL.lastPathComponent) in \(target.deletingLastPathComponent().lastPathComponent)")
            return
        }
        file = handle
        let host = url.host ?? "?"
        let names = headers.keys.sorted().joined(separator: ",")
        Diag.shared.log("download starts: \(host), size given \(total), headers \(names)", song: label)
        requestChunk(attempt: 0)
    }

    private func requestChunk(attempt: Int) {
        if finished { return }
        let from = received
        var to = from + RangedDownload.chunkSize - 1
        if total > 0 { to = min(to, total - 1) }
        var request = URLRequest(url: url)
        /* The first answer can take a while: the PC may have to find the song first. */
        request.timeoutInterval = from == 0 ? 30 : 20
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
        let asked = Date()
        let next = RangedDownload.session.dataTask(with: request) { data, response, error in
            self.queue.async {
                self.chunkArrived(from: from, to: to, attempt: attempt, asked: asked, data: data, response: response, error: error)
            }
        }
        task = next
        next.resume()
    }

    private func chunkArrived(from: Int64, to: Int64, attempt: Int, asked: Date, data: Data?, response: URLResponse?, error: Error?) {
        if finished { return }
        task = nil
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let count = Int64(data?.count ?? 0)
        let range = http?.value(forHTTPHeaderField: "Content-Range") ?? "-"
        let took = String(format: "%.2f", Date().timeIntervalSince(asked))
        let place = "\(from)-\(to)"

        var problem: String?
        if let error = error {
            let e = error as NSError
            problem = "download failed at \(place): \(e.domain) \(e.code) \(e.localizedDescription)"
        } else if status == 416 && from > 0 {
            /* We asked past the end: the last chunk ended exactly at the end of the file (its
               length was unknown, or shorter than we were told). */
            Diag.shared.log("chunk \(place): http 416 after \(received) bytes, taking that as the end", song: label)
            total = received
            complete()
            return
        } else if status != 206 && !(status == 200 && from == 0) {
            /* The PC explains a refusal in a small JSON body ({"error": "..."}); pass that on. */
            var said = ""
            if let data = data, !data.isEmpty, data.count < 2000,
               let text = String(data: data, encoding: .utf8) {
                said = ": " + String(text.replacingOccurrences(of: "\n", with: " ").prefix(160))
            }
            problem = "download http \(status) at \(place)\(said)"
        } else if count == 0 {
            problem = "download got an empty answer (http \(status)) at \(place)"
        }
        let verdict = problem.map { " -> " + $0 } ?? ""
        Diag.shared.log("chunk \(place) try \(attempt + 1): http \(status), \(count) bytes, Content-Range \(range), \(took) s\(verdict)",
                        error: problem != nil, song: label)
        if let problem = problem {
            /* Refused or gone: the address is no longer good, asking again cannot help. */
            let hopeless = status == 403 || status == 404 || status == 410
            if hopeless || attempt >= RangedDownload.maxRetries {
                fail(problem)
            } else {
                queue.asyncAfter(deadline: .now() + 0.6 * Double(attempt + 1)) {
                    self.requestChunk(attempt: attempt + 1)
                }
            }
            return
        }

        guard let data = data, let handle = file else {
            fail("download file was closed early")
            return
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            fail("cannot write the download to disk: \(error.localizedDescription)")
            return
        }
        received += count

        if status == 200 {
            /* The server ignored the range and sent the whole file in one go. */
            total = received
        } else if let last = range.split(separator: "/").last, let length = Int64(String(last)), length > 0 {
            /* "bytes 0-1048575/3456789": the number after the slash is the whole length. The
               server's own figure is trusted over the size the page passed along. */
            total = length
        }

        let shortChunk = count < to - from + 1
        if (total > 0 && received >= total) || (total <= 0 && shortChunk) {
            complete()
        } else {
            report(force: false)
            requestChunk(attempt: 0)
        }
    }

    private func report(force: Bool) {
        let now = Date()
        if !force && now.timeIntervalSince(lastReport) < 0.25 { return }
        lastReport = now
        let got = received
        let all = total
        DispatchQueue.main.async { self.onProgress(got, all) }
    }

    private func complete() {
        if total > 0 && received != total {
            fail("download incomplete: got \(received) of \(total) bytes")
            return
        }
        finished = true
        try? file?.close()
        file = nil
        let fm = FileManager.default
        try? fm.removeItem(at: target)
        do {
            try fm.moveItem(at: partURL, to: target)
        } catch {
            cleanUp()
            let message = "cannot move the download into place: \(error.localizedDescription)"
            Diag.shared.log(message, error: true, song: label)
            DispatchQueue.main.async { self.onDone(message) }
            return
        }
        total = received
        Diag.shared.log("download complete: \(received) bytes -> \(target.lastPathComponent)", song: label)
        report(force: true)
        DispatchQueue.main.async { self.onDone(nil) }
    }

    private func fail(_ message: String) {
        finished = true
        Diag.shared.log("download gave up: \(message)", error: true, song: label)
        cleanUp()
        DispatchQueue.main.async { self.onDone(message) }
    }

    private func cleanUp() {
        try? file?.close()
        file = nil
        try? FileManager.default.removeItem(at: partURL)
    }
}
