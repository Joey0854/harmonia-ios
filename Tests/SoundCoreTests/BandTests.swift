import XCTest
import SoundCore

/// Expected numbers: Tests/Fixtures/band.json, made by Tests/tools/make-band-fixtures.py from
/// tools/band/band_ref.py (numpy, double precision), which was checked against demucs'
/// apply_model on the PC. The network is a fake with a fixed rule (see that script).
final class BandTests: XCTestCase {
    final class FakeNetwork: BandNetwork {
        var calls = 0
        func run(spec: [Float], wave: [Float]) throws -> (spec: [Float], wave: [Float]) {
            calls += 1
            var s = [Float](), w = [Float]()
            s.reserveCapacity(spec.count * 4)
            w.reserveCapacity(wave.count * 4)
            for source in 0..<4 { s += spec.map { $0 * Float(source + 1) / 10 } }
            for source in 0..<4 { w += wave.map { $0 * Float(4 - source) / 10 } }
            return (s, w)
        }
    }

    private func signal(_ n: Int) -> (left: [Float], right: [Float]) {
        var a = TestRandom(seed: 11), b = TestRandom(seed: 22)
        var l = [Float](repeating: 0, count: n), r = [Float](repeating: 0, count: n)
        for k in 0..<n {
            l[k] = Float(0.3 * sin(2 * Double.pi * 220 * Double(k) / 44100)) + 0.2 * a.next()
            r[k] = Float(0.25 * sin(2 * Double.pi * 331 * Double(k) / 44100 + 1)) + 0.2 * b.next()
        }
        return (l, r)
    }

    private func fixture() throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Fixtures.data("band.json"))
        return object as? [String: Any] ?? [:]
    }

    private func rms(_ x: [Float]) -> Double {
        var e = 0.0
        for v in x { e += Double(v) * Double(v) }
        return (e / Double(max(1, x.count))).squareRoot()
    }

    func testSpectrumMatchesReference() throws {
        let f = try fixture()["spectrum"] as! [String: Any]
        let x = signal(Demucs.segment).left
        let z = Demucs.spectrum(x)
        let top = f["max"] as! Double
        for p in f["points"] as! [[Double]] {
            let i = Int(p[0]) * Demucs.frames + Int(p[1])
            XCTAssertEqual(Double(z.re[i]), p[2], accuracy: 2e-5 * top, "re at bin \(p[0]) frame \(p[1])")
            XCTAssertEqual(Double(z.im[i]), p[3], accuracy: 2e-5 * top, "im at bin \(p[0]) frame \(p[1])")
        }
    }

    /// As far as demucs' own transform pair goes back (it drops the Nyquist bin): the same
    /// error as the reference.
    func testInverseUndoesSpectrum() throws {
        let expected = try fixture()["roundtrip_db"] as! Double
        let x = signal(Demucs.segment).right
        let z = Demucs.spectrum(x)
        let y = Demucs.inverse(re: z.re, im: z.im)
        XCTAssertEqual(y.count, x.count)
        var err = 0.0, ref = 0.0
        for i in 0..<x.count {
            err += Double(y[i] - x[i]) * Double(y[i] - x[i])
            ref += Double(x[i]) * Double(x[i])
        }
        XCTAssertEqual(10 * log10(err / ref), expected, accuracy: 0.2)
    }

    func testOneSegmentMatchesReference() throws {
        let f = try fixture()["segment"] as! [String: Any]
        let s = signal(Demucs.segment)
        let stems = try Demucs.separate(left: s.left, right: s.right, network: FakeNetwork())
        let at = f["at"] as! [Int]
        let values = f["values"] as! [[[Double]]]
        let rmsRef = f["rms"] as! [[Double]]
        for source in 0..<4 {
            for c in 0..<2 {
                XCTAssertEqual(rms(stems[source][c]), rmsRef[source][c], accuracy: 1e-4 * rmsRef[source][c] + 1e-7)
                for (k, i) in at.enumerated() {
                    XCTAssertEqual(Double(stems[source][c][i]), values[source][c][k], accuracy: 2e-5,
                                   "source \(source) channel \(c) sample \(i)")
                }
            }
        }
    }

    func testSegmentsAndWeightsMatchReference() throws {
        let f = try fixture()["stream"] as! [String: Any]
        let n = f["length"] as! Int
        let s = signal(n)
        let net = FakeNetwork()
        let stems = try BandSplitter.separateAll(left: s.left, right: s.right, network: net)
        XCTAssertEqual(net.calls, 4)
        let at = f["at"] as! [Int]
        let values = f["values"] as! [[[Double]]]
        let rmsRef = f["rms"] as! [[Double]]
        for source in 0..<4 {
            for c in 0..<2 {
                XCTAssertEqual(stems[source][c].count, n)
                XCTAssertEqual(rms(stems[source][c]), rmsRef[source][c], accuracy: 1e-4 * rmsRef[source][c] + 1e-7)
                for (k, i) in at.enumerated() {
                    XCTAssertEqual(Double(stems[source][c][i]), values[source][c][k], accuracy: 2e-5,
                                   "source \(source) channel \(c) sample \(i)")
                }
            }
        }
    }

    /// Fed in uneven pieces, the processor gives exactly as many samples as went in and,
    /// once the band has faded in, the four parts through their responses.
    func testHeadphonesProcessorStreams() throws {
        let n = 12 * 44100 + 777
        let s = signal(n)
        let offline = try BandSplitter.separateAll(left: s.left, right: s.right, network: FakeNetwork())
        /* responses that pass each part through unchanged: the output is the sum of the parts */
        let identity: (left: [[Float]], right: [[Float]]) = ([[1], [0]], [[0], [1]])
        let p = BandProcessor(output: .headphones([identity, identity, identity, identity]),
                              network: FakeNetwork(), sampleRate: 44100, queue: nil, mix: BandMix())
        let out = run(p, s)
        XCTAssertEqual(out.left.count, n)
        XCTAssertEqual(out.right.count, n)
        var worst: Float = 0
        for i in BandProcessor.fade..<n {
            let l = offline[0][0][i] + offline[1][0][i] + offline[2][0][i] + offline[3][0][i]
            let r = offline[0][1][i] + offline[1][1][i] + offline[2][1][i] + offline[3][1][i]
            worst = max(worst, abs(out.left[i] - l), abs(out.right[i] - r))
        }
        XCTAssertLessThan(worst, 1e-4)
        /* the very first sample is still the original */
        XCTAssertEqual(out.left[0], s.left[0], accuracy: 1e-3)
    }

    func testSpeakersProcessorStreams() throws {
        let n = 9 * 44100 + 123
        let s = signal(n)
        let offline = try BandSplitter.separateAll(left: s.left, right: s.right, network: FakeNetwork())
        let p = BandProcessor(output: .speakers, network: FakeNetwork(), sampleRate: 44100, queue: nil, mix: BandMix())
        let out = run(p, s)
        XCTAssertEqual(out.left.count, n)
        let placer = StagePlacer(sources: 4, sampleRate: 44100)
        placer.positions = BandProcessor.positions
        let ref = placer.process(offline)
        var worst: Float = 0
        for i in 4096..<n { worst = max(worst, abs(out.left[i] - ref.left[i]), abs(out.right[i] - ref.right[i])) }
        XCTAssertLessThan(worst, 1e-4)
    }

    /// Played from a queue, with output wanted straight away: what is not separated in time
    /// is the original sound, and nothing is lost or doubled.
    func testSlowNetworkFallsBackToOriginal() {
        final class Never: BandNetwork {
            struct Failure: Error {}
            func run(spec: [Float], wave: [Float]) throws -> (spec: [Float], wave: [Float]) { throw Failure() }
        }
        let n = 3 * 44100
        let s = signal(n)
        let p = BandProcessor(output: .speakers, network: Never(), sampleRate: 44100,
                              queue: DispatchQueue(label: "test.band"), mix: BandMix())
        var l = [Float](), r = [Float]()
        let a = p.process(left: s.left, right: s.right)
        l += a.left; r += a.right
        while let part = p.drain(urgent: true) { l += part.left; r += part.right }
        let rest = p.finish()
        l += rest.left; r += rest.right
        XCTAssertEqual(l.count, n)
        var worst: Float = 0
        for i in 0..<n { worst = max(worst, abs(l[i] - s.left[i]), abs(r[i] - s.right[i])) }
        XCTAssertLessThan(worst, 1e-6)
    }

    /// Solo on the vocals: only the vocals, placed as they are by default.
    func testSoloLeavesOnlyThatPart() throws {
        let n = 9 * 44100
        let s = signal(n)
        let offline = try BandSplitter.separateAll(left: s.left, right: s.right, network: FakeNetwork())
        let mix = BandMix()
        var parts = BandProcessor.positions.map { BandPart(position: $0) }
        parts[3].solo = true
        parts[0].gain = 1.5
        mix.set(BandMixSettings(headphones: false, parts: parts))
        let p = BandProcessor(output: .speakers, network: FakeNetwork(), sampleRate: 44100, queue: nil, mix: mix)
        let out = run(p, s)
        let placer = StagePlacer(sources: 4, sampleRate: 44100)
        placer.positions = BandProcessor.positions
        let silent = [Float](repeating: 0, count: n)
        let ref = placer.process([[silent, silent], [silent, silent], [silent, silent], offline[3]])
        var worst: Float = 0
        for i in 4096..<n { worst = max(worst, abs(out.left[i] - ref.left[i]), abs(out.right[i] - ref.right[i])) }
        XCTAssertLessThan(worst, 1e-4)
    }

    /// A volume change while playing applies from the sound not handed on yet, gliding, and
    /// the network does not run again.
    func testVolumeChangeWhilePlaying() throws {
        let n = 30 * 44100
        let s = signal(n)
        let offline = try BandSplitter.separateAll(left: s.left, right: s.right, network: FakeNetwork())
        let mix = BandMix()
        let net = FakeNetwork()
        let p = BandProcessor(output: .speakers, network: net, sampleRate: 44100, queue: nil, mix: mix)
        var l = [Float](), r = [Float]()
        var at = 0
        var changedAt = -1
        while at < n {
            let m = min(8192, n - at)
            /* once some band sound has been handed on (output lags input by the lookahead) */
            if changedAt < 0 && l.count >= 6 * 44100 {
                var parts = BandProcessor.positions.map { BandPart(position: $0) }
                parts[0].mute = true
                mix.set(BandMixSettings(headphones: false, parts: parts))
                changedAt = l.count
            }
            let o = p.process(left: Array(s.left[at..<(at + m)]), right: Array(s.right[at..<(at + m)]))
            l += o.left; r += o.right
            at += m
        }
        while let part = p.drain(urgent: false) { l += part.left; r += part.right }
        let rest = p.finish()
        l += rest.left; r += rest.right
        XCTAssertEqual(l.count, n)
        XCTAssertEqual(net.calls, 6)
        XCTAssertGreaterThan(changedAt, 4096)
        guard changedAt > 4096 else { return }
        /* reference: drums silent from the change on (compared once the glide is over) */
        var drums = offline[0]
        for c in 0..<2 { for i in changedAt..<n { drums[c][i] = 0 } }
        let placer = StagePlacer(sources: 4, sampleRate: 44100)
        placer.positions = BandProcessor.positions
        let ref = placer.process([drums, offline[1], offline[2], offline[3]])
        var worst: Float = 0
        for i in (changedAt + 3 * BandProcessor.fade)..<n { worst = max(worst, abs(l[i] - ref.left[i]), abs(r[i] - ref.right[i])) }
        XCTAssertLessThan(worst, 1e-4)
        /* before the change, drums are still there */
        let before = placer2(offline, upTo: changedAt)
        var worstBefore: Float = 0
        for i in 4096..<changedAt { worstBefore = max(worstBefore, abs(l[i] - before.left[i])) }
        XCTAssertLessThan(worstBefore, 1e-4)
    }

    private func placer2(_ stems: [[[Float]]], upTo n: Int) -> (left: [Float], right: [Float]) {
        let placer = StagePlacer(sources: 4, sampleRate: 44100)
        placer.positions = BandProcessor.positions
        return placer.process(stems.map { [Array($0[0].prefix(n)), Array($0[1].prefix(n))] })
    }

    /// A 48 kHz song goes to the network at 44.1 kHz and comes back at 48 kHz.
    func testResamplesOtherRates() throws {
        let n = 10 * 48000 + 321
        let s = signal(n)
        let l44 = Resampler.convert(s.left, from: 48000, to: 44100)
        let r44 = Resampler.convert(s.right, from: 48000, to: 44100)
        let offline = try BandSplitter.separateAll(left: l44, right: r44, network: FakeNetwork())
        var sumL = [Float](repeating: 0, count: l44.count), sumR = sumL
        for st in offline { for i in 0..<sumL.count { sumL[i] += st[0][i]; sumR[i] += st[1][i] } }
        let refL = Resampler.convert(sumL, from: 44100, to: 48000)
        let refR = Resampler.convert(sumR, from: 44100, to: 48000)
        let identity: (left: [[Float]], right: [[Float]]) = ([[1], [0]], [[0], [1]])
        let p = BandProcessor(output: .headphones([identity, identity, identity, identity]),
                              network: FakeNetwork(), sampleRate: 48000, queue: nil, mix: BandMix())
        let out = run(p, s)
        XCTAssertEqual(out.left.count, n)
        let end = min(refL.count, n) - 200
        XCTAssertGreaterThan(end, n - 400)
        var worst: Float = 0
        for i in BandProcessor.fade..<end { worst = max(worst, abs(out.left[i] - refL[i]), abs(out.right[i] - refR[i])) }
        XCTAssertLessThan(worst, 1e-4)
    }

    /// A processor seeded with the first segments (as a prefetch gives them) plays the band
    /// from its first sample and runs on from there.
    func testSeededStartIsBandFromTheFirstSample() throws {
        let n = 16 * 44100
        let s = signal(n)
        let offline = try BandSplitter.separateAll(left: s.left, right: s.right, network: FakeNetwork())
        let pre = BandSplitter()
        pre.add(left: s.left, right: s.right)
        for _ in 0..<2 {
            let job = pre.takeJob()!
            pre.complete(job, stems: try Demucs.separate(left: job.left, right: job.right, network: FakeNetwork()))
        }
        XCTAssertEqual(pre.finalUpTo, 2 * Demucs.stride)
        let seed = BandSeed(id: "x", startTime: 0, sampleRate: 44100,
                            stems: BandSplitter.pack(pre.read(from: 0, count: 2 * Demucs.stride).stems), segments: 2)
        let identity: (left: [[Float]], right: [[Float]]) = ([[1], [0]], [[0], [1]])
        let net = FakeNetwork()
        let p = BandProcessor(output: .headphones([identity, identity, identity, identity]),
                              network: net, sampleRate: 44100, queue: nil, mix: BandMix(), seed: seed)
        let out = run(p, s)
        XCTAssertEqual(out.left.count, n)
        /* 16 s: segments at 0, 1, 2 (the last one partial); the first two came with the seed */
        XCTAssertEqual(net.calls, 1)
        func sum(_ i: Int) -> Float { return offline[0][0][i] + offline[1][0][i] + offline[2][0][i] + offline[3][0][i] }
        var worst: Float = 0
        for i in 0..<(2 * Demucs.stride) { worst = max(worst, abs(out.left[i] - sum(i))) }
        XCTAssertLessThan(worst, 1e-3)
        XCTAssertEqual(out.left[0], sum(0), accuracy: 1e-3)
    }

    /// The prefetch decodes the start of a file itself and gives the same parts as the
    /// processor works out when it plays the file.
    func testPrefetchMatchesPlaying() throws {
        let url = Fixtures.url("song-plain.m4a")
        let pf = BandPrefetch()
        pf.prepare(id: "song", file: url, from: 0, seconds: 5, network: FakeNetwork(), queue: DispatchQueue(label: "test.prefetch"))
        let decoder = try SongDecoder(url: url)
        var l = [Float](), r = [Float]()
        while let piece = try decoder.next() { l += piece.left; r += piece.right }
        let rate = Int(decoder.sampleRate.rounded())
        for _ in 0..<600 where !pf.hasSeed(for: "song") { Thread.sleep(forTimeInterval: 0.05) }
        let seed = pf.take(id: "song", startTime: decoder.startTime, sampleRate: rate)
        guard let s = seed else { return XCTFail("no prefetch: " + pf.progress) }
        XCTAssertEqual(s.segments, 1)
        let identity: (left: [[Float]], right: [[Float]]) = ([[1], [0]], [[0], [1]])
        let plain = run(BandProcessor(output: .headphones([identity, identity, identity, identity]),
                                      network: FakeNetwork(), sampleRate: rate, queue: nil, mix: BandMix()), (l, r))
        let seeded = run(BandProcessor(output: .headphones([identity, identity, identity, identity]),
                                       network: FakeNetwork(), sampleRate: rate, queue: nil, mix: BandMix(), seed: s), (l, r))
        XCTAssertEqual(plain.left.count, seeded.left.count)
        var worst: Float = 0
        /* up to where the seed ends (after it, the seeded one has the next segment alone) */
        let end = min(plain.left.count, Demucs.stride * rate / 44100) - 400
        for i in BandProcessor.fade..<end { worst = max(worst, abs(plain.left[i] - seeded.left[i])) }
        XCTAssertLessThan(worst, 2e-3)
    }

    /// A network whose first run never comes back: the watchdog leaves it, runs the same
    /// segment again, and a new song separates normally afterwards.
    func testWatchdogTakesOverAStalledRun() throws {
        final class Hang: BandNetwork {
            let lock = NSLock()
            var calls = 0
            var abandoned = 0
            let fake = FakeNetwork()
            func run(spec: [Float], wave: [Float]) throws -> (spec: [Float], wave: [Float]) {
                lock.lock()
                calls += 1
                let first = calls == 1
                lock.unlock()
                if first { DispatchSemaphore(value: 0).wait() }   // never returns
                return try fake.run(spec: spec, wave: wave)
            }
            func abandon() {
                lock.lock()
                abandoned += 1
                lock.unlock()
            }
        }
        let inner = Hang()
        let dog = BandWatchdog(inner, timeout: 0.5)
        let n = 9 * 44100
        let s = signal(n)
        let offline = try BandSplitter.separateAll(left: s.left, right: s.right, network: FakeNetwork())
        let identity: (left: [[Float]], right: [[Float]]) = ([[1], [0]], [[0], [1]])
        for song in 0..<2 {
            let p = BandProcessor(output: .headphones([identity, identity, identity, identity]),
                                  network: dog, sampleRate: 44100, queue: nil, mix: BandMix())
            let out = run(p, s)
            XCTAssertEqual(out.left.count, n)
            var worst: Float = 0
            for i in BandProcessor.fade..<n {
                let l = offline[0][0][i] + offline[1][0][i] + offline[2][0][i] + offline[3][0][i]
                worst = max(worst, abs(out.left[i] - l))
            }
            XCTAssertLessThan(worst, 1e-4, "song \(song)")
        }
        XCTAssertEqual(dog.stalls, 1)
        XCTAssertEqual(inner.abandoned, 1)
    }

    /// As seen on the phone: after many good runs one never comes back. The next segments
    /// and the next song go on.
    func testWatchdogAfterManyGoodRuns() throws {
        final class LateHang: BandNetwork {
            let lock = NSLock()
            var calls = 0
            let fake = FakeNetwork()
            func run(spec: [Float], wave: [Float]) throws -> (spec: [Float], wave: [Float]) {
                lock.lock()
                calls += 1
                let hang = calls == 6
                lock.unlock()
                if hang { DispatchSemaphore(value: 0).wait() }
                return try fake.run(spec: spec, wave: wave)
            }
        }
        let dog = BandWatchdog(LateHang(), timeout: 0.5)
        let n = 20 * 44100      // four segments per song
        let s = signal(n)
        for _ in 0..<3 {
            let p = BandProcessor(output: .speakers, network: dog, sampleRate: 44100, queue: nil, mix: BandMix())
            let out = run(p, s)
            XCTAssertEqual(out.left.count, n)
        }
        XCTAssertEqual(dog.stalls, 1)
    }

    /// Too hot: no new separation, the stand-in (here the original) plays.
    func testHeatPausesSeparation() {
        BandProcessor.thermal = { 2 }
        defer { BandProcessor.thermal = { ProcessInfo.processInfo.thermalState.rawValue } }
        let n = 9 * 44100
        let s = signal(n)
        let net = FakeNetwork()
        var states: [BandStatus] = []
        let p = BandProcessor(output: .speakers, network: net, sampleRate: 44100, queue: nil, mix: BandMix(),
                              status: { states.append($0) })
        /* nothing will be separated: hand on as playback would, short of sound */
        var out = p.process(left: s.left, right: s.right)
        while let part = p.drain(urgent: true) { out.left += part.left; out.right += part.right }
        let rest = p.finish()
        out.left += rest.left
        out.right += rest.right
        XCTAssertEqual(net.calls, 0)
        XCTAssertTrue(states.contains(.paused("hot")))
        var worst: Float = 0
        for i in 0..<n { worst = max(worst, abs(out.left[i] - s.left[i])) }
        XCTAssertLessThan(worst, 1e-5)
    }

    /// The parts go to the disk cache as they are separated; the next play reads them
    /// from there instead of running the network again.
    func testDiskCacheServesTheNextPlay() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bandcache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = BandCache(directory: dir)
        let n = 20 * 44100
        let s = signal(n)
        let identity: (left: [[Float]], right: [[Float]]) = ([[1], [0]], [[0], [1]])
        let first = FakeNetwork()
        let a = run(BandProcessor(output: .headphones([identity, identity, identity, identity]), network: first,
                                  sampleRate: 44100, queue: nil, mix: BandMix(), cache: cache, cacheID: "song"), s)
        XCTAssertEqual(first.calls, 4)
        XCTAssertEqual(cache.covered("song"), n)
        let second = FakeNetwork()
        let b = run(BandProcessor(output: .headphones([identity, identity, identity, identity]), network: second,
                                  sampleRate: 44100, queue: nil, mix: BandMix(), cache: cache, cacheID: "song"), s)
        /* three whole segments from the disk, the last one separated again */
        XCTAssertEqual(second.calls, 1)
        XCTAssertEqual(b.left.count, n)
        /* aligned to the sample (an encoder delay left in would show as a lag), and close */
        func error(lag: Int) -> Double {
            var err = 0.0, ref = 0.0
            for i in 10000..<(3 * Demucs.stride - 10000) {
                let d = Double(b.left[i + lag] - a.left[i])
                err += d * d
                ref += Double(a.left[i]) * Double(a.left[i])
            }
            return 10 * log10(err / max(ref, 1e-12))
        }
        var best = 0
        var bestDb = error(lag: 0)
        for lag in stride(from: -2200, through: 2200, by: 1) where lag != 0 && (lag % 64 == 0 || abs(lag) <= 8) {
            let e = error(lag: lag)
            if e < bestDb { bestDb = e; best = lag }
        }
        let db = error(lag: 0)
        print("RESULT band cache: AAC round trip error \(String(format: "%.1f", db)) dB at lag 0, best lag \(best)")
        XCTAssertEqual(best, 0)
        /* the test signal is mostly white noise, which AAC does not keep closely */
        XCTAssertLessThan(db, -10)
    }

    private func run(_ p: BandProcessor, _ s: (left: [Float], right: [Float])) -> (left: [Float], right: [Float]) {
        var l = [Float](), r = [Float]()
        let pieces = [4096, 1000, 37, 70000, 513]
        var at = 0, k = 0
        while at < s.left.count {
            let m = min(pieces[k % pieces.count], s.left.count - at)
            let o = p.process(left: Array(s.left[at..<(at + m)]), right: Array(s.right[at..<(at + m)]))
            l += o.left; r += o.right
            at += m; k += 1
        }
        while let part = p.drain(urgent: false) { l += part.left; r += part.right }
        let rest = p.finish()
        l += rest.left; r += rest.right
        return (l, r)
    }
}
