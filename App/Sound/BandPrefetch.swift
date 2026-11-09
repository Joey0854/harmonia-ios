import Foundation

/// The start of the next song, separated ahead of time, for a band processor to start with.
public struct BandSeed {
    public let id: String
    /// Where its decoder started (seconds into the song) and at what rate.
    public let startTime: Double
    public let sampleRate: Int
    /// [source × 2 + channel][sample] at 44.1 kHz, 16-bit (`BandSplitter.seedScale`).
    public let stems: [[Int16]]
    public let segments: Int

    public init(id: String, startTime: Double, sampleRate: Int, stems: [[Int16]], segments: Int) {
        self.id = id
        self.startTime = startTime
        self.sampleRate = sampleRate
        self.stems = stems
        self.segments = segments
    }
}

/// Separates the start of the next song while the current one plays, so that a mix into it
/// (or the plain change to it) is the band from its first sample. Runs on the band queue, one
/// segment at a time, and only while the playing song's band is well ahead (`minLead`); the
/// playing song always comes first. One prefetch at a time; a new one replaces the old.
public final class BandPrefetch {
    public static let shared = BandPrefetch()
    /// Seconds the playing song's separated sound must be ahead before a prefetch step runs.
    public static let minLead = 10.0
    public static var log: (String) -> Void = { _ in }

    private let lock = NSLock()
    private var generation = 0
    private var key: String?
    private var ready: BandSeed?
    private var busyID: String?
    private var stage = "idle"
    /// What the prefetch is doing (tests, diagnosis).
    public var progress: String {
        lock.lock()
        defer { lock.unlock() }
        return stage
    }
    private func note(_ s: String) {
        lock.lock()
        stage = s
        lock.unlock()
    }

    public init() {}

    /// Separates `file` from `position` (decoded exactly as the incoming song of a mix is,
    /// or from the start like a song that simply comes next) for at least `seconds`.
    public func prepare(id: String, file: URL, from position: Double, seconds: Double,
                        network: BandNetwork, queue: DispatchQueue) {
        let k = "\(id)|\(String(format: "%.3f", position))|\(Int(seconds.rounded()))"
        lock.lock()
        if key == k {
            lock.unlock()
            return
        }
        key = k
        generation += 1
        let g = generation
        ready = nil
        busyID = id
        lock.unlock()
        queue.async { [weak self] in
            self?.start(g, id: id, file: file, position: position, seconds: seconds, network: network, queue: queue)
        }
    }

    public func cancel(_ reason: String) {
        lock.lock()
        let had = key != nil
        key = nil
        generation += 1
        ready = nil
        busyID = nil
        lock.unlock()
        if had { BandPrefetch.log("band: prefetch dropped (\(reason))") }
    }

    /// Whether a finished prefetch for `id` is waiting.
    public func hasSeed(for id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ready?.id == id
    }

    /// The seed for a band processor starting `id` at `startTime`, if one is ready for exactly
    /// that start. Taken once.
    public func take(id: String, startTime: Double, sampleRate: Int) -> BandSeed? {
        lock.lock()
        defer { lock.unlock() }
        if let s = ready, s.id == id, abs(s.startTime - startTime) < 1e-6, s.sampleRate == sampleRate {
            ready = nil
            key = nil
            BandPrefetch.log(String(format: "band: starting %@ with the prefetched %d segments (%.1f s), band from the first sample", id, s.segments, Double(s.stems.first?.count ?? 0) / Double(Demucs.sampleRate)))
            return s
        }
        if let s = ready {
            stage = "asked for \(id) from \(startTime) s at \(sampleRate) Hz; have \(s.id) from \(s.startTime) s at \(s.sampleRate) Hz"
        }
        if busyID == id || ready?.id == id {
            BandPrefetch.log("band: prefetch of \(id) not ready for this start; the original plays first")
            key = nil
            generation += 1
            ready = nil
            busyID = nil
        }
        return nil
    }

    private func current(_ g: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return g == generation
    }

    private func start(_ g: Int, id: String, file: URL, position: Double, seconds: Double,
                       network: BandNetwork, queue: DispatchQueue) {
        guard current(g) else { return }
        let segments = max(1, Int((seconds * Double(Demucs.sampleRate) / Double(Demucs.stride)).rounded(.up)))
        let need44 = (segments - 1) * Demucs.stride + Demucs.segment
        let splitter = BandSplitter()
        let decoder: SongDecoder
        do {
            decoder = try SongDecoder(url: file, startAt: position, exact: position > 0)
        } catch {
            BandPrefetch.log("band: prefetch of \(id) cannot decode: \(error)")
            return
        }
        /* the rate is known once the first piece is there */
        var first = try? decoder.next()
        let rate = Int(decoder.sampleRate.rounded())
        guard first != nil, rate >= 8000 else {
            BandPrefetch.log("band: prefetch of \(id): no sound in the file")
            return
        }
        let resample = rate != Demucs.sampleRate
        let into = resample ? [Resampler(from: rate, to: Demucs.sampleRate), Resampler(from: rate, to: Demucs.sampleRate)] : []
        var ended = false
        while splitter.received < need44 {
            let next: (left: [Float], right: [Float])?
            if let f = first {
                next = f
                first = nil
            } else {
                next = try? decoder.next()
            }
            guard let piece = next else { ended = true; break }
            let l = resample ? into[0].process(piece.left) : piece.left
            let r = resample ? into[1].process(piece.right) : piece.right
            splitter.add(left: l, right: r)
        }
        if ended {
            if resample { splitter.add(left: into[0].finish(), right: into[1].finish()) }
            splitter.end()
        }
        let startTime = decoder.startTime
        note("decoded \(splitter.received) samples, ended \(ended), need \(need44), segments \(segments)")
        var packed = [[Int16]](repeating: [], count: 8)
        var done = 0
        var computing = 0.0
        let began = Date()

        func finish() {
            guard current(g), done > 0 else { return }
            let seed = BandSeed(id: id, startTime: startTime, sampleRate: rate, stems: packed, segments: done)
            lock.lock()
            if g == generation {
                ready = seed
                busyID = nil
                stage = "ready: \(id) from \(startTime) s at \(rate) Hz, \(done) segments"
            } else {
                stage = "finished for an older request"
            }
            lock.unlock()
            BandPrefetch.log(String(format: "band: prefetched next %@ from %.1f s, %d segments, took %.1f s (%.1f s of network, %d MB)",
                                    id, startTime, done, Date().timeIntervalSince(began), computing,
                                    (packed[0].count * 16) / 1_048_576))
        }

        func step() {
            guard current(g) else { return }
            /* the playing song first: only while its band is well ahead */
            if BandProcessor.thermal() >= 2 {
                note("waiting: the phone is hot")
                queue.asyncAfter(deadline: .now() + 5) { step() }
                return
            }
            if let lead = BandProcessor.lead, lead < BandPrefetch.minLead {
                note("waiting: playing song only \(lead) s ahead")
                queue.asyncAfter(deadline: .now() + 1) { step() }
                return
            }
            guard done < segments, let job = splitter.takeJob() else {
                note("finishing after \(done) segments")
                return finish()
            }
            let t0 = Date()
            do {
                let stems = try Demucs.separate(left: job.left, right: job.right, network: network)
                computing += Date().timeIntervalSince(t0)
                splitter.complete(job, stems: stems)
                let from = job.index * Demucs.stride
                let upTo = splitter.finalUpTo
                let part = splitter.read(from: from, count: max(0, upTo - from)).stems
                let p = BandSplitter.pack(part)
                for c in 0..<8 { packed[c] += p[c] }
                splitter.drop(before: upTo)
                done += 1
            } catch {
                BandPrefetch.log("band: prefetch of \(id) stopped: \(error)")
                return
            }
            queue.async { step() }
        }

        step()
    }
}
