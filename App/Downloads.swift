import Foundation

/// Songs stored on the phone. A stored song is played from its file instead of the network.
final class Downloads: NSObject, URLSessionDownloadDelegate {
    static let shared = Downloads()

    var onEvent: (([String: Any]) -> Void)?

    private let folder: URL
    private var session: URLSession!
    private var idsByTask: [Int: String] = [:]
    private var lastReport: [Int: Date] = [:]
    /// Downloads that need request headers and are fetched in ranges, by song id.
    private var ranged: [String: RangedDownload] = [:]
    /// Songs whose address is still being looked up in the app.
    private var resolving: Set<String> = []

    private override init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = base.appendingPathComponent("songs", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        super.init()
        RangedDownload.removeLeftovers(in: folder)
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    }

    static func isValid(id: String) -> Bool {
        return id.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil
    }

    private func fileURL(_ id: String) -> URL {
        return folder.appendingPathComponent(id + ".m4a")
    }

    /// The stored file for a song, when there is one.
    func localURL(_ id: String) -> URL? {
        guard Downloads.isValid(id: id) else { return nil }
        let url = fileURL(id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func start(id: String, url: URL) {
        guard Downloads.isValid(id: id) else { return }
        if Ytdl.isYtdl(url) {
            start(id: id, url: url, headers: [:], size: 0)
            return
        }
        if idsByTask.values.contains(id) || ranged[id] != nil { return }
        let task = session.downloadTask(with: url)
        idsByTask[task.taskIdentifier] = id
        task.resume()
    }

    /// Stores a song that can only be fetched with these request headers. Reports with the
    /// same events as a plain download.
    func start(id: String, url: URL, headers: [String: String], size: Int64) {
        guard Downloads.isValid(id: id) else { return }
        if Ytdl.isYtdl(url) {
            guard !resolving.contains(id), ranged[id] == nil else { return }
            resolving.insert(id)
            Ytdl.shared.resolve(id: Ytdl.videoID(from: url) ?? id) { [weak self] stream, message in
                guard let self = self else { return }
                self.resolving.remove(id)
                guard let stream = stream else {
                    Diag.shared.log("dl: \(id) could not be looked up: \(message ?? "")", error: true, song: id)
                    self.onEvent?(["type": "dl", "id": id, "state": "error"])
                    return
                }
                self.start(id: id, url: stream.url, headers: stream.headers, size: stream.size)
            }
            return
        }
        if idsByTask.values.contains(id) || ranged[id] != nil { return }
        let target = fileURL(id)
        /* Often the song was just played, so the bytes are already on the phone. */
        if let cached = StreamCache.shared.cachedURL(id) {
            try? FileManager.default.removeItem(at: target)
            if (try? FileManager.default.copyItem(at: cached, to: target)) != nil {
                onEvent?(["type": "dl", "id": id, "state": "done", "size": fileSize(target)])
                return
            }
        }
        let job = RangedDownload(label: id, url: url, headers: headers, size: size, target: target,
            onProgress: { [weak self] got, total in
                guard let self = self, self.ranged[id] != nil else { return }
                self.onEvent?(["type": "dl", "id": id, "state": "progress", "got": got, "total": total])
            },
            onDone: { [weak self] message in
                guard let self = self, self.ranged[id] != nil else { return }
                self.ranged[id] = nil
                if message == nil {
                    self.onEvent?(["type": "dl", "id": id, "state": "done", "size": self.fileSize(target)])
                } else {
                    self.onEvent?(["type": "dl", "id": id, "state": "error"])
                }
            })
        ranged[id] = job
        job.start()
    }

    private func fileSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    func remove(id: String) {
        guard Downloads.isValid(id: id) else { return }
        ranged.removeValue(forKey: id)?.cancel()
        let running = idsByTask.filter { $0.value == id }.map { $0.key }
        if !running.isEmpty {
            session.getAllTasks { tasks in
                for task in tasks where running.contains(task.taskIdentifier) { task.cancel() }
            }
        }
        try? FileManager.default.removeItem(at: fileURL(id))
    }

    func list() -> [[String: Any]] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var out: [[String: Any]] = []
        for name in names where name.hasSuffix(".m4a") {
            let id = String(name.dropLast(4))
            let attrs = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            out.append(["id": id, "size": size])
        }
        return out
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let key = downloadTask.taskIdentifier
        guard let id = idsByTask[key] else { return }
        let now = Date()
        if let last = lastReport[key], now.timeIntervalSince(last) < 0.3 { return }
        lastReport[key] = now
        onEvent?(["type": "dl", "id": id, "state": "progress", "got": totalBytesWritten, "total": totalBytesExpectedToWrite])
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = idsByTask[downloadTask.taskIdentifier] else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            onEvent?(["type": "dl", "id": id, "state": "error"])
            return
        }
        let target = fileURL(id)
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.moveItem(at: location, to: target)
            let attrs = try? FileManager.default.attributesOfItem(atPath: target.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            onEvent?(["type": "dl", "id": id, "state": "done", "size": size])
        } catch {
            onEvent?(["type": "dl", "id": id, "state": "error"])
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let key = task.taskIdentifier
        let id = idsByTask[key]
        idsByTask[key] = nil
        lastReport[key] = nil
        if let error = error, let id = id, (error as NSError).code != NSURLErrorCancelled {
            onEvent?(["type": "dl", "id": id, "state": "error"])
        }
    }
}
