import Foundation

/// "Band" surround: the song is separated into drums, bass, other and vocals by the HTDemucs
/// network (`BandSplitter` + `Demucs`), and the four parts are placed one by one:
/// - `.speakers`: on the stage in front (`StagePlacer`), for a car's two speakers;
/// - `.headphones`: each through its own pair of head-related responses (virtual speakers
///   chosen per part), for headphones.
///
/// The network runs on `queue`, one segment (7.8 s) at a time, while the song plays. To give it
/// time, output is held back `lookahead` samples behind the input (the decoder simply reads
/// further ahead). Where a part of the song is not separated when it has to be handed on (the
/// phone too slow, the first seconds after a start or a seek), the original sound is handed on
/// instead and the band fades in once it is ready. Nothing ever waits for the network except
/// `drain`, and that only when it is told playback is not short of sound.
///
/// Output sample n belongs to input sample n. Call `process` for each piece, then `drain`
/// until it returns nil, then `finish`. Use from one thread (the network has its own).
public final class BandProcessor {
    public enum Output {
        case speakers
        /// One pair of impulse responses (as for `TrueStereoConvolver`) per part, in
        /// `Demucs.sources` order.
        case headphones([(left: [[Float]], right: [[Float]])])
    }

    /// Input held back before output: one segment and one step, so the next segment can be
    /// worked on while the current one plays.
    public static let lookahead = Demucs.segment + Demucs.stride
    /// Samples over which the band fades in.
    public static let fade = 2048

    /// Where the four parts stand on the stage (`Demucs.sources` order): drums behind the
    /// singer, bass a little left, other (guitars, keys) wide, vocals at the front and narrow.
    public static let positions: [StagePosition] = {
        let m: Float = 1 / (1 - 0.35 * 0.3)
        return [
            StagePosition(azimuth: 0, depth: 0.5, width: 1.3, gain: m),
            StagePosition(azimuth: -12, depth: 0.3, width: 0.4, gain: m),
            StagePosition(azimuth: 0, depth: 0.35, width: 1.7, gain: m),
            StagePosition(azimuth: 0, depth: 0.05, width: 0.6, gain: 1.1 * m)
        ]
    }()

    private let network: BandNetwork
    private let sampleRate: Int
    private let queue: DispatchQueue?
    private let log: (String) -> Void

    /* Shared with the network's thread, under `lock`. */
    private let lock = NSLock()
    private let splitter = BandSplitter()
    private var working = false
    private var failed = false
    private var wanted = 0
    private let wake = DispatchSemaphore(value: 0)

    /* The caller's side. */
    private let placer: StagePlacer?
    private let convolvers: [TrueStereoConvolver]
    private var original: [[Float]] = [[], []]
    private var originalStart = 0
    private var received = 0
    private var emitted = 0
    private var amount: Float = 0
    private var direct: [[Float]] = [[], []]
    private var wasReady = false
    private var skippedShown = 0

    /// `queue` nil runs the network inside `process` / `drain` (tests). `log` gets one line per
    /// segment and per change between band and original.
    public init(output: Output, network: BandNetwork, sampleRate: Int, queue: DispatchQueue?,
                log: @escaping (String) -> Void = { _ in }) {
        self.network = network
        self.sampleRate = sampleRate
        self.queue = queue
        self.log = log
        switch output {
        case .speakers:
            let p = StagePlacer(sources: 5, sampleRate: sampleRate)
            /* the fifth source is the original sound, standing in where the band is missing */
            p.positions = BandProcessor.positions + [.neutral]
            placer = p
            convolvers = []
        case .headphones(let irs):
            placer = nil
            convolvers = irs.prefix(4).map { TrueStereoConvolver(irLeft: $0.left, irRight: $0.right) }
        }
        if sampleRate != Demucs.sampleRate {
            log("band: song at \(sampleRate) Hz, the model expects \(Demucs.sampleRate) Hz; used as it is")
        }
    }

    public func process(left: [Float], right: [Float]) -> (left: [Float], right: [Float]) {
        let n = min(left.count, right.count)
        original[0].append(contentsOf: left.prefix(n))
        original[1].append(contentsOf: right.prefix(n))
        received += n
        lock.lock()
        splitter.add(left: Array(left.prefix(n)), right: Array(right.prefix(n)))
        lock.unlock()
        kick()
        return emit(upTo: received - BandProcessor.lookahead)
    }

    /// After the last `process`: hands on what is ready. When nothing is ready, waits a moment
    /// for the network and returns nothing, unless `urgent` (playback is running short), in
    /// which case half a second goes on as it is. Nil when everything has been handed on.
    public func drain(urgent: Bool) -> (left: [Float], right: [Float])? {
        lock.lock()
        splitter.end()
        let ready = failed ? received : splitter.finalUpTo
        lock.unlock()
        kick()
        if emitted >= received { return nil }
        if ready > emitted { return emit(upTo: min(ready, emitted + sampleRate)) }
        if urgent { return emit(upTo: min(received, emitted + sampleRate / 2)) }
        _ = wake.wait(timeout: .now() + 0.05)
        return ([], [])
    }

    /// The rest (whatever `drain` left, and the tails held inside the impulse responses).
    public func finish() -> (left: [Float], right: [Float]) {
        var out = emit(upTo: received)
        if !convolvers.isEmpty {
            var l = [Float](), r = [Float]()
            for (i, c) in convolvers.enumerated() {
                let t = c.flush()
                if i == 0 { l = t.left; r = t.right } else {
                    for j in 0..<min(l.count, t.left.count) { l[j] += t.left[j]; r[j] += t.right[j] }
                }
            }
            for j in 0..<min(l.count, direct[0].count) { l[j] += direct[0][j]; r[j] += direct[1][j] }
            direct = [[], []]
            out.left += l
            out.right += r
        }
        lock.lock()
        failed = true
        lock.unlock()
        return out
    }

    // MARK: - network

    private func kick() {
        guard let q = queue else {
            while let job = take() { work(job) }
            return
        }
        lock.lock()
        if working || failed {
            lock.unlock()
            return
        }
        working = true
        lock.unlock()
        q.async { [weak self] in self?.next() }
    }

    private func take() -> BandSplitter.Job? {
        lock.lock()
        defer { lock.unlock() }
        if failed { return nil }
        return splitter.takeJob(wanted: wanted)
    }

    /* One segment, then the next one is queued; a released processor stops there. */
    private func next() {
        guard let job = take() else {
            lock.lock()
            working = false
            lock.unlock()
            return
        }
        work(job)
        queue?.async { [weak self] in self?.next() }
    }

    private func work(_ job: BandSplitter.Job) {
        let start = Date()
        do {
            let stems = try Demucs.separate(left: job.left, right: job.right, network: network)
            let took = Date().timeIntervalSince(start)
            let audio = Double(Demucs.stride) / Double(sampleRate)
            log(String(format: "band: segment %d took %.2f s (realtime x%.2f)", job.index, took, audio / max(took, 1e-6)))
            lock.lock()
            splitter.complete(job, stems: stems)
            lock.unlock()
        } catch {
            log("band: the network failed (\(error)); playing the original")
            lock.lock()
            failed = true
            lock.unlock()
        }
        wake.signal()
    }

    // MARK: - output

    private func emit(upTo limit: Int) -> (left: [Float], right: [Float]) {
        let count = min(limit, received) - emitted
        if count <= 0 { return ([], []) }
        lock.lock()
        let part = splitter.read(from: emitted, count: count)
        let skipped = splitter.skipped
        splitter.drop(before: emitted)
        wanted = emitted + count
        let broken = failed
        lock.unlock()
        if skipped > skippedShown {
            log("band: \(skipped - skippedShown) segment(s) skipped, too late to be of use")
            skippedShown = skipped
        }

        let o = originalStart
        var gains = [Float](repeating: 0, count: count)
        for j in 0..<count {
            if part.ready[j] && !broken {
                amount = min(1, amount + 1 / Float(BandProcessor.fade))
            } else {
                amount = 0
            }
            gains[j] = amount
            let ready = gains[j] > 0
            if ready != wasReady {
                let at = Double(emitted + j) / Double(sampleRate)
                log(ready ? String(format: "band: separated sound from %.1f s", at)
                          : String(format: "band: not separated in time at %.1f s, playing the original", at))
                wasReady = ready
            }
        }
        var stems = part.stems
        for c in 0..<8 { for j in 0..<count { stems[c][j] *= gains[j] } }
        var dryLeft = [Float](repeating: 0, count: count), dryRight = [Float](repeating: 0, count: count)
        for j in 0..<count {
            dryLeft[j] = original[0][o + j] * (1 - gains[j])
            dryRight[j] = original[1][o + j] * (1 - gains[j])
        }
        originalStart += count
        emitted += count
        if originalStart > 1 << 18 {
            original[0].removeFirst(originalStart)
            original[1].removeFirst(originalStart)
            originalStart = 0
        }

        if let p = placer {
            var sources: [[[Float]]] = (0..<4).map { [stems[$0 * 2], stems[$0 * 2 + 1]] }
            sources.append([dryLeft, dryRight])
            return p.process(sources)
        }
        var l = [Float](), r = [Float]()
        for (s, c) in convolvers.enumerated() {
            let t = c.process(left: stems[s * 2], right: stems[s * 2 + 1])
            if s == 0 { l = t.left; r = t.right } else {
                for j in 0..<min(l.count, t.left.count) { l[j] += t.left[j]; r[j] += t.right[j] }
            }
        }
        direct[0] += dryLeft
        direct[1] += dryRight
        let m = min(l.count, direct[0].count)
        for j in 0..<m { l[j] += direct[0][j]; r[j] += direct[1][j] }
        direct[0].removeFirst(m)
        direct[1].removeFirst(m)
        return (l, r)
    }
}
