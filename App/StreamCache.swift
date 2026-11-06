import UIKit

/// Songs fetched only to be played (not kept by the user), in `Caches/stream/<id>.m4a`.
/// The system may empty Caches when the app is not running; that is fine, they are re-fetched.
///
/// Use from the main queue only. Callbacks arrive on the main queue.
final class StreamCache {
    static let shared = StreamCache()

    private static let maxFiles = 25

    private struct Waiter {
        let progress: ((Int64, Int64) -> Void)?
        let done: ((URL?, String?) -> Void)?
    }

    private final class Job {
        let download: RangedDownload
        var waiters: [Waiter] = []
        init(download: RangedDownload) { self.download = download }
    }

    private let folder: URL
    private var jobs: [String: Job] = [:]
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        folder = base.appendingPathComponent("stream", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        RangedDownload.removeLeftovers(in: folder)
    }

    /// The id becomes a file name, so it must not be able to leave the folder.
    static func isSafe(id: String) -> Bool {
        return id.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil
    }

    private func fileURL(_ id: String) -> URL {
        return folder.appendingPathComponent(id + ".m4a")
    }

    /// The cached file for a song, when there is one. Asking counts as using it, so songs in
    /// use are the last to be deleted.
    func cachedURL(_ id: String) -> URL? {
        guard StreamCache.isSafe(id: id) else { return nil }
        let url = fileURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    /// Makes sure the song is in the cache. `done` gets the file, or nil and a message. When a
    /// download of the same song is already running this joins it instead of starting another.
    func fetch(id: String, url: URL, headers: [String: String], size: Int64,
               progress: ((Int64, Int64) -> Void)?, done: ((URL?, String?) -> Void)?) {
        guard StreamCache.isSafe(id: id) else {
            done?(nil, "bad id")
            return
        }
        if let file = cachedURL(id) {
            done?(file, nil)
            return
        }
        /* A song only the app can find the address of (yt-dlp inside the app). */
        if Ytdl.isYtdl(url) {
            Diag.shared.log("song is looked up in the app: \(id)", song: id)
            Ytdl.shared.resolve(id: Ytdl.videoID(from: url) ?? id) { [weak self] stream, message in
                guard let self = self else { return }
                guard let stream = stream else {
                    done?(nil, message ?? "could not find the song")
                    return
                }
                self.fetch(id: id, url: stream.url, headers: stream.headers, size: stream.size,
                           progress: progress, done: done)
            }
            return
        }
        let waiter = Waiter(progress: progress, done: done)
        if let job = jobs[id] {
            job.waiters.append(waiter)
            return
        }
        let download = RangedDownload(label: id, url: url, headers: headers, size: size, target: fileURL(id),
            onProgress: { [weak self] got, total in
                guard let job = self?.jobs[id] else { return }
                for w in job.waiters { w.progress?(got, total) }
            },
            onDone: { [weak self] message in
                self?.finished(id: id, message: message)
            })
        let job = Job(download: download)
        job.waiters.append(waiter)
        jobs[id] = job
        updateBackgroundTask()
        download.start()
    }

    /// Stops every download except the ones for these songs.
    func cancel(except keep: Set<String>) {
        for (id, job) in jobs where !keep.contains(id) {
            job.download.cancel()
            jobs[id] = nil
        }
        updateBackgroundTask()
    }

    private func finished(id: String, message: String?) {
        guard let job = jobs.removeValue(forKey: id) else { return }
        updateBackgroundTask()
        let file = message == nil ? fileURL(id) : nil
        for w in job.waiters { w.done?(file, message) }
        if message == nil { trim() }
    }

    /* A download must not stop because the screen was locked. While a song is audible the
       audio background mode keeps the app running, but not while we wait for the first song,
       or in the gap between two songs when the next one is not here yet. A background task
       asks iOS for extra running time (about 30 seconds) for exactly those moments. If that
       runs out the app is suspended and the download fails or continues when it wakes. */
    private func updateBackgroundTask() {
        if jobs.isEmpty {
            endBackgroundTask()
        } else if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "song download") { [weak self] in
                self?.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        if backgroundTask == .invalid { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Keeps the most recently used files and deletes the rest.
    private func trim() {
        let folder = self.folder
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            var dated: [(url: URL, date: Date)] = []
            for url in urls where url.pathExtension == "m4a" {
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                dated.append((url: url, date: date ?? Date.distantPast))
            }
            if dated.count <= StreamCache.maxFiles { return }
            dated.sort { $0.date > $1.date }
            for entry in dated[StreamCache.maxFiles...] {
                try? fm.removeItem(at: entry.url)
            }
        }
    }
}
