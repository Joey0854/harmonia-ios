import Foundation

/// "Band" surround: the song is separated into drums, bass, other and vocals by the HTDemucs
/// network (`BandSplitter` + `Demucs`), and the four parts are placed one by one:
/// - `.speakers`: on the stage in front (`StagePlacer`), for a car's two speakers;
/// - `.headphones`: each through its own pair of head-related responses (virtual speakers
///   chosen per part), for headphones.
///
/// The network runs on `queue`, one segment (7.8 s at 44.1 kHz) at a time, while the song plays.
/// Songs at another rate are resampled to 44.1 kHz for it and the parts back to the song's rate.
/// To give the network time, output is held back `lookahead` samples behind the input (the
/// decoder simply reads further ahead). Where a part of the song is not separated when it has
/// to be handed on (the phone too slow, the first seconds after a start or a seek), the
/// original sound is handed on instead and the band fades in once it is ready.
///
/// The mixer (`BandMix`: volume, solo, mute, positions, and for headphones new responses) is
/// read every time sound is handed on and applies from there, without the network running
/// again; volumes glide, new responses cross-fade.
///
/// Output sample n belongs to input sample n. Call `process` for each piece, then `drain`
/// until it returns nil, then `finish`. Use from one thread (the network has its own).
public final class BandProcessor {
    public enum Output {
        case speakers
        /// One pair of impulse responses (as for `TrueStereoConvolver`) per part, in
        /// `Demucs.sources` order.
        case headphones([(left: [[Float]], right: [[Float]])])
        /// For a car with Bose Centerpoint (`CarBandMixer`).
        case car
    }

    /// Input held back before output (at 44.1 kHz): one segment and two steps (19.5 s), so
    /// separation can run up to about 17 s ahead of what is handed on: a cushion for slower
    /// moments (the app going to the background, where only the CPU may be used). Costs about
    /// 40 MB of buffers (the parts are kept as 32-bit sums until handed on).
    public static let lookahead = Demucs.segment + 2 * Demucs.stride
    /// Called after every separated segment with its time and how many times faster than
    /// playback it was (any thread). For the app's performance log.
    public static var onSegment: ((Double, Double) -> Void)?
    private static let leadLock = NSLock()
    private static var leadValue: Double?
    /// Seconds of separated sound ahead of what was last handed on (nil: no band running).
    public static var lead: Double? {
        leadLock.lock()
        defer { leadLock.unlock() }
        return leadValue
    }
    static func setLead(_ v: Double?) {
        leadLock.lock()
        leadValue = v
        leadLock.unlock()
    }

    /// Samples over which the band fades in, and a volume change glides.
    public static let fade = 2048

    /// Where the four parts stand on the stage by default (`Demucs.sources` order): drums
    /// behind the singer, bass a little left, other (guitars, keys) wide, vocals at the front
    /// and narrow. The gains here are part of the placement, the mixer's volume comes on top.
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
    private let status: (BandStatus) -> Void
    private let mix: BandMix
    private let headphones: Bool

    /* Shared with the network's thread, under `lock`. */
    private let lock = NSLock()
    private let splitter = BandSplitter()
    private var working = false
    private var failed = false
    private var failure: String?
    private var wanted = 0
    private let wake = DispatchSemaphore(value: 0)

    /* The caller's side. */
    private let placer: StagePlacer?
    private let car: CarBandMixer?
    private var convolvers: [TrueStereoConvolver]
    private var fading: [TrueStereoConvolver]?
    private var fadeLeft = 0
    private var history = [[Float]](repeating: [], count: 8)
    private var fed = 0
    private var original: [[Float]] = [[], []]
    private var originalStart = 0
    private var received = 0
    private var emitted = 0
    private var amount: Float = 0
    private var direct: [[Float]] = [[], []]
    private var wasReady = false
    private var everReady = false
    private var lastRun: BandStatus = .loading
    /* What plays where the band is missing: the mode chosen before (when switching from it),
       else the original. And the band only starts once its first two segments are there, so
       that a switch is not followed by a moment of the stand-in. */
    private var dry: SurroundChain?
    private var gateOpen = false
    /* where this run's sample 0 lies in the song (44.1 kHz), and the cache chunk being written */
    private let startOffset: Int
    private var cacheWriter: BandCache.Writer?
    private var thermalPaused = false
    /// The phone's thermal state (0 nominal … 3 critical); serious and above pause new
    /// separation (tests replace it).
    public static var thermal: () -> Int = { ProcessInfo.processInfo.thermalState.rawValue }
    private static let statsLock = NSLock()
    private static var hits = 0
    private static var hotNow = false
    static func countCacheHits(_ n: Int) {
        statsLock.lock()
        hits += n
        statsLock.unlock()
    }
    /// Segments read from the disk cache since the last call (the performance report).
    public static func takeCacheHits() -> Int {
        statsLock.lock()
        defer { hits = 0; statsLock.unlock() }
        return hits
    }
    /// Whether some band is held back by the heat now.
    public static var heldByHeat: Bool {
        statsLock.lock()
        defer { statsLock.unlock() }
        return hotNow
    }
    private var retry: BandSplitter.Job?
    private var errors = 0
    /// Network failures in a row before the band gives up for the song.
    public static let maxTries = 3
    /// What is appended to each segment's log line (the app: compute units, background).
    public static var segmentTag: (() -> String)?
    private var late = false
    private var skippedShown = 0
    private var mixVersion = -1
    private var irVersion = 0
    private var gainTarget: [Float] = [1, 1, 1, 1]
    private var gainNow: [Float] = [1, 1, 1, 1]

    /* Other sample rates: resamplers into and out of the network's rate, and the parts at the
       song's rate (`store`, from `storeBase` on) with whether each sample is separated. */
    private let resampling: Bool
    private var into: [Resampler] = []
    private var outOf: [Resampler] = []
    private var inputEnded = false
    private var cursor = 0
    private var flushed = false
    private var ready44: [Bool] = []
    private var ready44Base = 0
    private var produced = 0
    private var store = [[Float]](repeating: [], count: 8)
    private var storeReady: [Bool] = []
    private var storeBase = 0

    /// `queue` nil runs the network inside `process` / `drain` (tests). `log` gets one line per
    /// segment and per change between band and original; `status` the same for the page.
    public init(output: Output, network: BandNetwork, sampleRate: Int, queue: DispatchQueue?,
                mix: BandMix = .shared, seed: BandSeed? = nil, dry: SurroundChain? = nil,
                cache: BandCache? = nil, cacheID: String? = nil, startOffset: Int = 0,
                log: @escaping (String) -> Void = { _ in },
                status: @escaping (BandStatus) -> Void = { _ in }) {
        self.network = network
        self.sampleRate = max(8000, sampleRate)
        self.queue = queue
        self.log = log
        self.status = status
        self.mix = mix
        self.startOffset = startOffset
        let rate = max(8000, sampleRate)
        switch output {
        case .speakers:
            let p = StagePlacer(sources: 5, sampleRate: sampleRate)
            /* the fifth source is the original sound, standing in where the band is missing */
            p.positions = BandProcessor.positions + [.neutral]
            placer = p
            car = nil
            convolvers = []
            headphones = false
        case .headphones(let irs):
            placer = nil
            car = nil
            convolvers = irs.prefix(4).map { TrueStereoConvolver(irLeft: $0.left, irRight: $0.right) }
            headphones = true
        case .car:
            placer = nil
            car = CarBandMixer(sampleRate: sampleRate, params: .v2b)
            convolvers = []
            headphones = false
        }
        resampling = self.sampleRate != Demucs.sampleRate
        if resampling {
            into = (0..<2).map { _ in Resampler(from: rate, to: Demucs.sampleRate) }
            outOf = (0..<8).map { _ in Resampler(from: Demucs.sampleRate, to: rate) }
            log("band: song at \(self.sampleRate) Hz, resampled to \(Demucs.sampleRate) Hz for the model and back")
        }
        self.dry = dry
        /* the disk cache first: parts kept from an earlier play need no network at all */
        if let c = cache, let id = cacheID, let reader = c.reader(id), reader.covered > startOffset {
            let k = (reader.covered - startOffset) / Demucs.stride
            if k >= 1 {
                let off = startOffset
                splitter.seed(source: { reader.read(from: off + $0, count: $1) }, segments: k)
                gateOpen = true
                everReady = true
                wasReady = true
                amount = 1
                BandProcessor.countCacheHits(k)
                log(String(format: "band: cache hit %@: %d segments (%.1f s) from %.1f s read from disk",
                           id, k, Double(k * Demucs.stride) / Double(Demucs.sampleRate), Double(off) / Double(Demucs.sampleRate)))
            }
        }
        if let c = cache, let id = cacheID {
            let from = c.covered(id)
            if from >= startOffset { cacheWriter = c.writer(id, from: from) }
        }
        if let s = seed, !gateOpen {
            gateOpen = true
            splitter.seed(s.stems, segments: s.segments)
            /* separated already: the band from the very first sample, no fade-in */
            everReady = true
            wasReady = true
            amount = 1
        }
        applyMix(crossfade: false)
        status(.loading)
    }

    public func process(left: [Float], right: [Float]) -> (left: [Float], right: [Float]) {
        let n = min(left.count, right.count)
        let l = Array(left.prefix(n)), r = Array(right.prefix(n))
        if let d = dry {
            let t = d.process(left: l, right: r)
            original[0].append(contentsOf: t.left)
            original[1].append(contentsOf: t.right)
        } else {
            original[0].append(contentsOf: l)
            original[1].append(contentsOf: r)
        }
        received += n
        let a = resampling ? into[0].process(l) : l
        let b = resampling ? into[1].process(r) : r
        lock.lock()
        splitter.add(left: a, right: b)
        lock.unlock()
        kick()
        let hold = resampling ? BandProcessor.lookahead * sampleRate / Demucs.sampleRate : BandProcessor.lookahead
        return emit(upTo: received - hold)
    }

    /// After the last `process`: hands on what is ready. When nothing is ready, waits a moment
    /// for the network and returns nothing, unless `urgent` (playback is running short), in
    /// which case half a second goes on as it is. Nil when everything has been handed on.
    public func drain(urgent: Bool) -> (left: [Float], right: [Float])? {
        if !inputEnded {
            inputEnded = true
            if let d = dry {
                let t = d.finish()
                original[0].append(contentsOf: t.left)
                original[1].append(contentsOf: t.right)
            }
            if resampling {
                let a = into[0].finish(), b = into[1].finish()
                lock.lock()
                splitter.add(left: a, right: b)
                lock.unlock()
            }
            lock.lock()
            splitter.end()
            lock.unlock()
        }
        kick()
        if emitted >= received { return nil }
        let ready = readyUpTo()
        if ready > emitted { return emit(upTo: min(ready, emitted + sampleRate)) }
        if urgent { return emit(upTo: min(received, emitted + sampleRate / 2)) }
        _ = wake.wait(timeout: .now() + 0.05)
        return ([], [])
    }

    /// The rest (whatever `drain` left, and the tails held inside the impulse responses).
    /* Writes newly separated sound to the disk cache, while it follows what is kept there
       (band queue). A gap (a skipped segment, sound already handed on) ends the chunk. */
    private func keep() {
        guard let w = cacheWriter else { return }
        lock.lock()
        let final = splitter.finalUpTo
        let from = w.start + w.frames - startOffset
        let part = final > from && from >= 0 ? splitter.read(from: from, count: final - from) : nil
        let done = splitter.total.map { final >= $0 } ?? false
        lock.unlock()
        if let p = part {
            if p.ready.allSatisfy({ $0 }) {
                w.append(p.stems)
            } else {
                w.close()
                lock.lock()
                cacheWriter = nil
                lock.unlock()
                return
            }
        }
        if done {
            w.close()
            lock.lock()
            cacheWriter = nil
            lock.unlock()
        }
    }

    public func finish() -> (left: [Float], right: [Float]) {
        keep()
        cacheWriter?.close()
        var out = emit(upTo: received)
        fading = nil
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
        BandProcessor.setLead(nil)
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
        /* too hot (serious or critical): no new separation until it is fair again; what is
           separated or kept on disk plays, the rest is the stand-in */
        let heat = BandProcessor.thermal()
        let hot = thermalPaused ? heat >= 2 : heat >= 2
        if hot != thermalPaused {
            thermalPaused = hot
            BandProcessor.statsLock.lock()
            BandProcessor.hotNow = hot
            BandProcessor.statsLock.unlock()
            log(hot ? "band: phone hot (thermal \(heat)): no new separation; separated parts play, then the stand-in"
                    : "band: phone cooler (thermal \(heat)): separating again")
            lock.lock()
            let run = lastRun
            lock.unlock()
            status(hot ? .paused("hot") : run)
        }
        if hot { return nil }
        lock.lock()
        defer { lock.unlock() }
        if failed { return nil }
        if let again = retry {
            retry = nil
            return again
        }
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
            let audio = Double(Demucs.stride) / Double(Demucs.sampleRate)
            let speed = audio / max(took, 1e-6)
            let tag = BandProcessor.segmentTag?() ?? ""
            log(String(format: "band: segment %d took %.2f s (realtime x%.2f)", job.index, took, speed) + (tag.isEmpty ? "" : " [" + tag + "]"))
            BandProcessor.onSegment?(took, speed)
            lock.lock()
            errors = 0
            lock.unlock()
            let s = BandStatus.running(seconds: took, realtime: speed)
            lock.lock()
            splitter.complete(job, stems: stems)
            lastRun = s
            let behind = late
            lock.unlock()
            keep()
            /* while the original is playing, the page keeps saying so */
            if !behind { status(s) }
        } catch {
            /* The same segment again (the network reloads its model, e.g. after a memory
               warning), up to maxTries times in a row; the original plays meanwhile. */
            lock.lock()
            errors += 1
            let n = errors
            let giveUp = n >= BandProcessor.maxTries
            if giveUp {
                failed = true
                failure = "\(error)"
            } else {
                retry = job
            }
            lock.unlock()
            log("band: the network failed on segment \(job.index), try \(n) of \(BandProcessor.maxTries) (\(error)); " + (giveUp ? "the stand-in plays for this song" : "trying again"))
            status(.failed((giveUp ? "paused: " : "retrying: ") + "\(error)"))
            if !giveUp { Thread.sleep(forTimeInterval: 2) }
        }
        wake.signal()
    }

    // MARK: - separated parts at the song's rate

    /// Song samples before this are separated or never will be.
    private func readyUpTo() -> Int {
        lock.lock()
        let broken = failed
        let final44 = splitter.finalUpTo
        let total44 = splitter.total
        lock.unlock()
        if broken { return received }
        if !resampling {
            if let t = total44, final44 >= t { return received }
            return final44
        }
        pull()
        if flushed { return received }
        return storeBase + storeReady.count
    }

    /* Brings newly separated parts over to the song's rate. */
    private func pull() {
        guard resampling, !flushed else { return }
        lock.lock()
        let final44 = splitter.finalUpTo
        let total44 = splitter.total
        var part: (stems: [[Float]], ready: [Bool])?
        if final44 > cursor {
            part = splitter.read(from: cursor, count: final44 - cursor)
            cursor = final44
        }
        lock.unlock()
        var outs = [[Float]](repeating: [], count: 8)
        if let p = part {
            ready44 += p.ready
            for c in 0..<8 { outs[c] = outOf[c].process(p.stems[c]) }
        }
        if let t = total44, cursor >= t {
            for c in 0..<8 { outs[c] += outOf[c].finish() }
            flushed = true
        }
        let k = outs[0].count
        if k == 0 { return }
        for c in 0..<8 { store[c] += outs[c] }
        for m in produced..<(produced + k) {
            let i = m * Demucs.sampleRate / sampleRate - ready44Base
            storeReady.append(i >= 0 && i < ready44.count ? ready44[i] : false)
        }
        produced += k
    }

    private func read(from: Int, count: Int) -> (stems: [[Float]], ready: [Bool]) {
        if !resampling {
            lock.lock()
            defer { lock.unlock() }
            return splitter.read(from: from, count: count)
        }
        pull()
        var stems = [[Float]](repeating: [Float](repeating: 0, count: count), count: 8)
        var ready = [Bool](repeating: false, count: count)
        for j in 0..<count {
            let i = from + j - storeBase
            guard i >= 0, i < storeReady.count else { continue }
            ready[j] = storeReady[i]
            for c in 0..<8 { stems[c][j] = store[c][i] }
        }
        return (stems, ready)
    }

    private func forget(before sample: Int) {
        let at44 = resampling ? sample * Demucs.sampleRate / sampleRate : sample
        lock.lock()
        splitter.drop(before: resampling ? min(cursor, max(0, at44 - 64)) : at44)
        wanted = at44
        lock.unlock()
        guard resampling else { return }
        let cut = min(sample - storeBase, storeReady.count)
        if cut > 1 << 16 {
            for c in 0..<8 { store[c].removeFirst(cut) }
            storeReady.removeFirst(cut)
            storeBase += cut
        }
        let cut44 = min(max(0, at44 - 64) - ready44Base, ready44.count)
        if cut44 > 1 << 16 {
            ready44.removeFirst(cut44)
            ready44Base += cut44
        }
    }

    // MARK: - mixer

    private func applyMix(crossfade: Bool) {
        let now = mix.current()
        guard now.version != mixVersion else { return }
        mixVersion = now.version
        guard let s = now.settings, s.headphones == headphones, (s.car != nil) == (car != nil) else { return }
        gainTarget = s.effectiveGains
        if let c = car, let p = s.car { c.set(p) }
        if !crossfade { gainNow = gainTarget }
        if let p = placer {
            p.positions = (0..<4).map { i in
                var q = i < s.parts.count ? s.parts[i].position : BandProcessor.positions[i]
                q.gain = BandProcessor.positions[i].gain
                return q
            } + [.neutral]
        }
        if headphones, let irs = s.irs, irs.count == 4, now.irVersion != irVersion {
            irVersion = now.irVersion
            do {
                let made = try irs.map {
                    TrueStereoConvolver(irLeft: try SurroundChain.prepare($0.left, sampleRate: sampleRate),
                                        irRight: try SurroundChain.prepare($0.right, sampleRate: sampleRate))
                }
                replaceResponses(with: made, crossfade: crossfade && fed > 0)
            } catch {
                log("band: mixer responses not usable (\(error)); kept the previous ones")
            }
        }
    }

    /* New responses: primed with the last blocks of input so that their output lines up with
       the old ones, then cross-faded over one block. */
    private func replaceResponses(with made: [TrueStereoConvolver], crossfade: Bool) {
        guard crossfade, let block = convolvers.first?.blockSize else {
            convolvers = made
            return
        }
        let pending = fed % block
        var prime = pending
        while prime + block <= history[0].count && prime + block <= 2 * block + pending { prime += block }
        prime = min(prime, history[0].count)
        if prime < pending {
            convolvers = made
            return
        }
        for (s, c) in made.enumerated() {
            let l = Array(history[s * 2].suffix(prime)), r = Array(history[s * 2 + 1].suffix(prime))
            _ = c.process(left: l, right: r)
        }
        fading = convolvers
        convolvers = made
        fadeLeft = block
    }

    // MARK: - output

    private func emit(upTo limit: Int) -> (left: [Float], right: [Float]) {
        let count = min(limit, received) - emitted
        if count <= 0 { return ([], []) }
        applyMix(crossfade: true)
        let part = read(from: emitted, count: count)
        forget(before: emitted)
        lock.lock()
        let skipped = splitter.skipped
        let broken = failed
        lock.unlock()
        if skipped > skippedShown {
            log("band: \(skipped - skippedShown) segment(s) skipped, too late to be of use")
            skippedShown = skipped
        }

        let o = originalStart
        if !gateOpen {
            let r = readyUpTo()
            let two = 2 * Demucs.stride * sampleRate / Demucs.sampleRate
            if r >= emitted + min(two, received - emitted) || (inputEnded && r >= received) {
                gateOpen = true
            }
        }
        var gains = [Float](repeating: 0, count: count)
        for j in 0..<count {
            if part.ready[j] && !broken && gateOpen {
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
                lock.lock()
                let run = lastRun
                late = !ready && everReady && !broken
                let nowLate = late
                lock.unlock()
                if ready { status(run) } else if nowLate { status(.late) }
                if ready { everReady = true }
                wasReady = ready
            }
        }
        BandProcessor.setLead(Double(max(0, readyUpTo() - emitted - count)) / Double(sampleRate))
        var stems = part.stems
        let step = 1 / Float(BandProcessor.fade)
        for s in 0..<4 {
            var g = gainNow[s]
            let target = gainTarget[s]
            for j in 0..<count {
                if g < target { g = min(target, g + step) } else if g > target { g = max(target, g - step) }
                let k = gains[j] * g
                stems[s * 2][j] *= k
                stems[s * 2 + 1][j] *= k
            }
            gainNow[s] = g
        }
        var dryLeft = [Float](repeating: 0, count: count), dryRight = [Float](repeating: 0, count: count)
        let have = original[0].count
        for j in 0..<count where o + j < have {
            dryLeft[j] = original[0][o + j] * (1 - gains[j])
            dryRight[j] = original[1][o + j] * (1 - gains[j])
        }
        originalStart += count
        emitted += count
        if originalStart > 1 << 18 {
            let k = min(originalStart, original[0].count)
            original[0].removeFirst(k)
            original[1].removeFirst(k)
            originalStart -= k
        }

        if let c = car {
            return c.process(stems: stems, standIn: (dryLeft, dryRight))
        }
        if let p = placer {
            var sources: [[[Float]]] = (0..<4).map { [stems[$0 * 2], stems[$0 * 2 + 1]] }
            sources.append([dryLeft, dryRight])
            return p.process(sources)
        }
        /* remember the last blocks fed, for responses that arrive later */
        let keep = 3 * (convolvers.first?.blockSize ?? 4096)
        for c in 0..<8 {
            history[c] += stems[c]
            if history[c].count > 2 * keep { history[c].removeFirst(history[c].count - keep) }
        }
        fed += count
        var (l, r) = sum(convolvers, stems)
        if let old = fading {
            let (ol, or) = sum(old, stems)
            let block = Float(convolvers.first?.blockSize ?? 4096)
            for j in 0..<min(l.count, ol.count) {
                let w = fadeLeft > 0 ? 1 - Float(fadeLeft) / block : 1
                l[j] = l[j] * w + ol[j] * (1 - w)
                r[j] = r[j] * w + or[j] * (1 - w)
                if fadeLeft > 0 { fadeLeft -= 1 }
            }
            if fadeLeft == 0 { fading = nil }
        }
        direct[0] += dryLeft
        direct[1] += dryRight
        let m = min(l.count, direct[0].count)
        for j in 0..<m { l[j] += direct[0][j]; r[j] += direct[1][j] }
        direct[0].removeFirst(m)
        direct[1].removeFirst(m)
        return (l, r)
    }

    private func sum(_ set: [TrueStereoConvolver], _ stems: [[Float]]) -> ([Float], [Float]) {
        var l = [Float](), r = [Float]()
        for (s, c) in set.enumerated() {
            let t = c.process(left: stems[s * 2], right: stems[s * 2 + 1])
            if s == 0 { l = t.left; r = t.right } else {
                for j in 0..<min(l.count, t.left.count) { l[j] += t.left[j]; r[j] += t.right[j] }
            }
        }
        return (l, r)
    }
}
