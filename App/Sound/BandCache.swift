import AVFoundation
import Foundation

/// Separated parts kept on disk (AAC, 192 kbit/s per stereo part, about 23 MB for four
/// minutes), so that playing a song again, or going back in it, needs no network. Per song the
/// parts from its start onwards are kept as chunks that follow each other without a gap; a run
/// that was cut off leaves a chunk that ends early, and a later run carries on after it. Only
/// sound that was completely separated is written. Least recently used songs go when the cache
/// is over `limitBytes`. Positions are samples at 44.1 kHz from the song's start.
public final class BandCache {
    public static let shared = BandCache(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BandStems-htdemucs-1"))
    /// The most the cache may hold (default 1 GB).
    public var limitBytes: Int = 1 << 30
    public static var log: (String) -> Void = { _ in }

    public let directory: URL
    private let lock = NSLock()

    struct Chunk: Codable {
        var start: Int
        var frames: Int
        var name: String
    }
    struct Index: Codable {
        var chunks: [Chunk]
        var used: Double
    }

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func folder(_ id: String) -> URL {
        let safe = String(id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }.prefix(64))
        return directory.appendingPathComponent(safe.isEmpty ? "_" : safe)
    }

    private func readIndex(_ id: String) -> Index? {
        guard let data = try? Data(contentsOf: folder(id).appendingPathComponent("index.json")) else { return nil }
        return try? JSONDecoder().decode(Index.self, from: data)
    }

    private func writeIndex(_ id: String, _ index: Index) {
        if let data = try? JSONEncoder().encode(index) {
            try? data.write(to: folder(id).appendingPathComponent("index.json"), options: .atomic)
        }
    }

    /// How far the song's parts are kept without a gap from its start (0: nothing).
    public func covered(_ id: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let index = readIndex(id) else { return 0 }
        var end = 0
        for c in index.chunks.sorted(by: { $0.start < $1.start }) {
            if c.start > end { break }
            end = max(end, c.start + c.frames)
        }
        return end
    }

    /// A reader for the song's kept parts, nil if there are none.
    public func reader(_ id: String) -> Reader? {
        let end = covered(id)
        guard end > 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard var index = readIndex(id) else { return nil }
        index.used = Date().timeIntervalSince1970
        writeIndex(id, index)
        return Reader(folder: folder(id), chunks: index.chunks.sorted { $0.start < $1.start }, covered: end)
    }

    /// A writer for the song's parts from `start` on, only where that continues what is kept.
    public func writer(_ id: String, from start: Int) -> Writer? {
        guard start == covered(id) else { return nil }
        let name = "c\(start)"
        let dir = folder(id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return Writer(cache: self, id: id, folder: dir, name: name, start: start)
    }

    /* A chunk is complete: note it, then keep the cache under its limit. */
    fileprivate func add(_ id: String, _ chunk: Chunk) {
        lock.lock()
        var index = readIndex(id) ?? Index(chunks: [], used: 0)
        index.chunks.removeAll { $0.start == chunk.start }
        index.chunks.append(chunk)
        index.used = Date().timeIntervalSince1970
        writeIndex(id, index)
        lock.unlock()
        trim()
    }

    /// Bytes on disk and the songs by last use.
    public func size() -> Int {
        let fm = FileManager.default
        var total = 0
        if let e = fm.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in e {
                total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0
            }
        }
        return total
    }

    func trim() {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        guard let songs = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        var entries: [(url: URL, used: Double, bytes: Int)] = []
        var total = 0
        for s in songs {
            var bytes = 0
            if let e = fm.enumerator(at: s, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let u as URL in e { bytes += (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 }
            }
            var used = 0.0
            if let data = try? Data(contentsOf: s.appendingPathComponent("index.json")),
               let i = try? JSONDecoder().decode(Index.self, from: data) { used = i.used }
            entries.append((s, used, bytes))
            total += bytes
        }
        guard total > limitBytes else { return }
        for e in entries.sorted(by: { $0.used < $1.used }) where total > limitBytes {
            try? fm.removeItem(at: e.url)
            total -= e.bytes
            BandCache.log("band: cache over its limit, removed \(e.url.lastPathComponent) (\(e.bytes / 1_048_576) MB)")
        }
    }

    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Demucs.sampleRate), channels: 2, interleaved: false)!

    public final class Reader {
        public let covered: Int
        private let folder: URL
        private let chunks: [Chunk]
        private var open: (start: Int, frames: Int, files: [AVAudioFile])?

        init(folder: URL, chunks: [Chunk], covered: Int) {
            self.folder = folder
            self.chunks = chunks
            self.covered = covered
        }

        /// [source × 2 + channel][sample] for [from, from + count), within `covered`.
        public func read(from: Int, count: Int) -> [[Float]]? {
            var out = [[Float]](repeating: [Float](repeating: 0, count: count), count: 8)
            var at = from
            while at < from + count {
                guard let c = chunks.last(where: { $0.start <= at && at < $0.start + $0.frames }) else { return nil }
                if open?.start != c.start {
                    var files: [AVAudioFile] = []
                    for s in Demucs.sources {
                        guard let f = try? AVAudioFile(forReading: folder.appendingPathComponent("\(c.name)-\(s).m4a"),
                                                       commonFormat: .pcmFormatFloat32, interleaved: false) else { return nil }
                        files.append(f)
                    }
                    open = (c.start, c.frames, files)
                }
                guard let o = open else { return nil }
                let n = min(from + count - at, c.start + c.frames - at)
                for (s, f) in o.files.enumerated() {
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(n)) else { return nil }
                    f.framePosition = AVAudioFramePosition(at - c.start)
                    do { try f.read(into: buffer, frameCount: AVAudioFrameCount(n)) } catch { return nil }
                    guard let data = buffer.floatChannelData else { return nil }
                    let got = Int(buffer.frameLength)
                    let channels = Int(f.processingFormat.channelCount)
                    for ch in 0..<2 {
                        let src = data[min(ch, channels - 1)]
                        for i in 0..<min(got, n) { out[s * 2 + ch][at - from + i] = src[i] }
                    }
                }
                at += n
            }
            return out
        }
    }

    public final class Writer {
        public let start: Int
        public private(set) var frames = 0
        private weak var cache: BandCache?
        private let id: String
        private let folder: URL
        private let name: String
        private var files: [AVAudioFile] = []
        private var closed = false

        init?(cache: BandCache, id: String, folder: URL, name: String, start: Int) {
            self.cache = cache
            self.id = id
            self.folder = folder
            self.name = name
            self.start = start
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Double(Demucs.sampleRate),
                                           AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000]
            for s in Demucs.sources {
                let url = folder.appendingPathComponent("\(name)-\(s).m4a")
                try? FileManager.default.removeItem(at: url)
                guard let f = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false) else { return nil }
                files.append(f)
            }
        }

        /// More parts, [source × 2 + channel][sample], following what was written.
        public func append(_ stems: [[Float]]) {
            guard !closed, stems.count == 8, let n = stems.first?.count, n > 0 else { return }
            for (s, f) in files.enumerated() {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: BandCache.format, frameCapacity: AVAudioFrameCount(n)),
                      let data = buffer.floatChannelData else { return }
                buffer.frameLength = AVAudioFrameCount(n)
                for ch in 0..<2 { stems[s * 2 + ch].withUnsafeBufferPointer { data[ch].update(from: $0.baseAddress!, count: n) } }
                do { try f.write(from: buffer) } catch {
                    BandCache.log("band: cache write failed: \(error)")
                    closed = true
                    return
                }
            }
            frames += n
        }

        /// Finishes the chunk (also when a run is cut off: it ends early, a later run goes on).
        public func close() {
            guard !closed else { return }
            closed = true
            files = []      // AVAudioFile finishes the file when let go
            guard frames > 0 else { return }
            cache?.add(id, Chunk(start: start, frames: frames, name: name))
            let bytes = Demucs.sources.reduce(0) { sum, s in
                sum + ((try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("\(name)-\(s).m4a").path)[.size] as? NSNumber)?.intValue ?? 0)
            }
            BandCache.log(String(format: "band: cache wrote %@ from %.1f s, %.1f s, %.1f MB", id, Double(start) / Double(Demucs.sampleRate),
                                 Double(frames) / Double(Demucs.sampleRate), Double(bytes) / 1_048_576))
        }

        deinit { close() }
    }
}
