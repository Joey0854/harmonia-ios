import XCTest
import SoundCore

final class MixPlannerTests: XCTestCase {
    private func song(_ values: [String: Double]) -> MixAnalysis {
        return MixAnalysis(values.mapValues { NSNumber(value: $0) })
    }

    /// A: 200 s, main part to 190, faint from 193, silent from 195 (an ending of its own).
    private var a: [String: Double] {
        return ["bpm": 120, "beat0": 0.25, "conf": 5, "dur": 200, "bodyEnd": 190, "quietStart": 193, "tailEnd": 195]
    }
    /// A without an ending of its own: main part to 196, silent from 197.
    private var aTight: [String: Double] {
        return ["bpm": 120, "beat0": 0.25, "conf": 5, "dur": 200, "bodyEnd": 196, "quietStart": 196.5, "tailEnd": 197]
    }
    private var b: [String: Double] {
        return ["bpm": 120, "beat0": 0.1, "conf": 3, "dur": 180, "bodyStart": 4]
    }

    private func plan(_ a: [String: Double]?, _ b: [String: Double]?, durationA: Double = 0, availableB: Double = 0,
                      on: Bool = true) -> MixDecision {
        return MixPlanner.plan(a: a.map { song($0) }, b: b.map { song($0) }, durationA: durationA, availableB: availableB, mixOn: on)
    }

    private func expect(_ decision: MixDecision, startA: Double, overlap: Double, end: Double, bOffset: Double,
                        bDelay: Double, synced: Bool, file: StaticString = #filePath, line: UInt = #line) {
        guard case .plan(let p) = decision else {
            XCTFail("expected a plan, got \(decision)", file: file, line: line)
            return
        }
        XCTAssertEqual(p.startA, startA, accuracy: 1e-6, "startA", file: file, line: line)
        XCTAssertEqual(p.overlap, overlap, accuracy: 1e-6, "overlap", file: file, line: line)
        XCTAssertEqual(p.end, end, accuracy: 1e-6, "end", file: file, line: line)
        XCTAssertEqual(p.bOffset, bOffset, accuracy: 1e-6, "bOffset", file: file, line: line)
        XCTAssertEqual(p.bDelay, bDelay, accuracy: 1e-6, "bDelay", file: file, line: line)
        XCTAssertEqual(p.synced, synced, "synced", file: file, line: line)
    }

    private func expectNone(_ decision: MixDecision, _ reason: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(decision, .none(reason), file: file, line: line)
    }

    // MARK: worked out by hand

    /// overlap = clamp(195 - 193 + 1.5, 2, 3) = 3; end = min(200, max(195, 190.5)) = 195;
    /// startA = 192; B's main part (at 4 s) in the middle: bOffset = 4 - 1.5 = 2.5.
    func testOrdinaryMix() {
        expect(plan(a, b), startA: 192, overlap: 3, end: 195, bOffset: 2.5, bDelay: 0, synced: false)
    }

    /// B's main part begins 0.4 s in, less than half the overlap (1.5): B starts from 0, 1.1 s late.
    func testMainPartEarlierThanHalfTheOverlap() {
        var early = b
        early["bodyStart"] = 0.4
        expect(plan(a, early), startA: 192, overlap: 3, end: 195, bOffset: 0, bDelay: 1.1, synced: false)
        early["bodyStart"] = 0
        expect(plan(a, early), startA: 192, overlap: 3, end: 195, bOffset: 0, bDelay: 1.5, synced: false)
    }

    /// Sound right up to the end: end = min(200, max(199.8, 199.9 + 0.5)) = 200;
    /// overlap = clamp(199.8 - 199.5 + 1.5 = 1.8, 2, 3) = 2.
    func testEndingAtTheVeryEnd() {
        var late = a
        late["bodyEnd"] = 199.9
        late["quietStart"] = 199.5
        late["tailEnd"] = 199.8
        late["conf"] = 0   // tempo not sure: the ordinary kind of mix
        expect(plan(late, b), startA: 198, overlap: 2, end: 200, bOffset: 3, bDelay: 0, synced: false)
    }

    /// Beat on beat. Beats of A every 0.5 s from 0.25; overlap 16 beats = 8 s; end = 197.
    /// B starts at 4 - 0.3 = 3.7; its next beat is 4.1 (0.1 + 8 x 0.5), 0.4 s later.
    /// First A beat at or after (197 - 8) + 0.4 = 189.4 is 189.75, so startA = 189.35; that
    /// overlap would end at 197.35 > 197, so one beat earlier: 188.85.
    func testBeatMatched() {
        let decision = plan(aTight, b)
        expect(decision, startA: 188.85, overlap: 8, end: 197, bOffset: 3.7, bDelay: 0, synced: true)
    }

    /// B at twice A's tempo: beats of B every 0.25 s; next beat after 3.7 is 3.85 (lead 0.15).
    /// First A beat at or after 189.15 is 189.25 -> startA 189.1 -> one beat earlier: 188.6.
    func testBeatMatchedAtDoubleAndHalfTempo() {
        var double = b
        double["bpm"] = 240
        expect(plan(aTight, double), startA: 188.6, overlap: 8, end: 197, bOffset: 3.7, bDelay: 0, synced: true)
        /* Half tempo: beats of B every second from 0.1; next after 3.7 is 4.1, as in testBeatMatched. */
        var half = b
        half["bpm"] = 60
        expect(plan(aTight, half), startA: 188.85, overlap: 8, end: 197, bOffset: 3.7, bDelay: 0, synced: true)
    }

    /// 16 beats at 100 bpm are 9.6 s: halved to 4.8. At 300 bpm 3.2 s: doubled to 6.4.
    func testOverlapIsBroughtBetweenFourAndEightSeconds() {
        var slowA = aTight, slowB = b
        slowA["bpm"] = 100
        slowB["bpm"] = 100
        guard case .plan(let p) = plan(slowA, slowB) else { return XCTFail("no plan") }
        XCTAssertEqual(p.overlap, 4.8, accuracy: 1e-9)
        XCTAssertTrue(p.synced)
        slowA["bpm"] = 300
        slowB["bpm"] = 300
        guard case .plan(let q) = plan(slowA, slowB) else { return XCTFail("no plan") }
        XCTAssertEqual(q.overlap, 6.4, accuracy: 1e-9)
    }

    /// The same tempos, but A's ending lasts 3 s after its main part: not on the beat.
    /// overlap = clamp(197 - 196.5 + 1.5, 2, 3) = 2; end = max(197, 194.5) = 197.
    func testAnEndingOfItsOwnPreventsBeatMatching() {
        var ending = aTight
        ending["bodyEnd"] = 194
        expect(plan(ending, b), startA: 195, overlap: 2, end: 197, bOffset: 3, bDelay: 0, synced: false)
        /* exactly 2 s is still allowed */
        ending["bodyEnd"] = 195
        guard case .plan(let p) = plan(ending, b) else { return XCTFail("no plan") }
        XCTAssertTrue(p.synced)
    }

    func testUnsureOrDifferentTemposAreNotBeatMatched() {
        var unsure = b
        unsure["conf"] = 1.99
        expect(plan(aTight, unsure), startA: 195, overlap: 2, end: 197, bOffset: 3, bDelay: 0, synced: false)
        var off = b
        off["bpm"] = 120.72   // 0.6 % apart
        expect(plan(aTight, off), startA: 195, overlap: 2, end: 197, bOffset: 3, bDelay: 0, synced: false)
        off["bpm"] = 120.48   // 0.4 % apart
        guard case .plan(let p) = plan(aTight, off) else { return XCTFail("no plan") }
        XCTAssertTrue(p.synced)
        var noBeat = b
        noBeat["beat0"] = nil
        guard case .plan(let q) = plan(aTight, noBeat) else { return XCTFail("no plan") }
        XCTAssertFalse(q.synced, "without a beat position there is nothing to line up")
    }

    func testNoMix() {
        expectNone(plan(a, b, on: false), "mixing is off")
        expectNone(plan(nil, b), "no analysis of the current song")
        expectNone(plan(a, nil), "no analysis of the next song")
        var broken = a
        broken["tailEnd"] = nil
        expectNone(plan(broken, b), "analysis incomplete")
        var noStart = b
        noStart["bodyStart"] = nil
        expectNone(plan(a, noStart), "analysis incomplete")
        /* the song goes quiet at 90 s of 200: startA = 88 < 100 */
        var early = a
        early["bodyEnd"] = 89
        early["quietStart"] = 89
        early["tailEnd"] = 90
        expectNone(plan(early, b), "the mix would begin before the middle of the song")
        var short = a
        short["dur"] = 29
        short["bodyEnd"] = 27
        short["quietStart"] = 27.5
        short["tailEnd"] = 28
        expectNone(plan(short, b), "current song shorter than 30 s")
        /* B: 2.5 + 3 s are needed, 5 exist */
        expectNone(plan(a, b, availableB: 5), "next song too short")
        expect(plan(a, b, availableB: 5.5), startA: 192, overlap: 3, end: 195, bOffset: 2.5, bDelay: 0, synced: false)
        /* the file is 3 s longer than the analysed one */
        expectNone(plan(a, b, durationA: 203), "analysis does not fit this file")
        var noLength = a
        noLength["dur"] = nil
        expectNone(plan(noLength, b), "length unknown")
        expect(plan(noLength, b, durationA: 200), startA: 192, overlap: 3, end: 195, bOffset: 2.5, bDelay: 0, synced: false)
    }

    /// The real length wins over the analysis' figure when they are close: end is capped by it.
    func testRealLengthCapsTheEnd() {
        var late = a
        late["bodyEnd"] = 199.9
        late["quietStart"] = 199.5
        late["tailEnd"] = 199.8
        late["conf"] = 0   // tempo not sure: the ordinary kind of mix
        expect(plan(late, b, durationA: 199.2), startA: 197.2, overlap: 2, end: 199.2, bOffset: 3, bDelay: 0, synced: false)
    }

    // MARK: the 11 real songs, against the JavaScript reference

    private func fixtures() throws -> (songs: [String: MixAnalysis], cases: [[String: Any]]) {
        let analysis = try JSONSerialization.jsonObject(with: Fixtures.data("mix-analysis.json")) as? [String: [String: Any]] ?? [:]
        let cases = try JSONSerialization.jsonObject(with: Fixtures.data("mix-expected.json")) as? [[String: Any]] ?? []
        return (analysis.mapValues { MixAnalysis($0) }, cases)
    }

    private func decide(_ entry: [String: Any], _ songs: [String: MixAnalysis]) -> (MixDecision, MixAnalysis?, MixAnalysis?) {
        let a = (entry["aInfo"] as? [String: Any]).map { MixAnalysis($0) } ?? songs[entry["a"] as? String ?? ""]
        let b = (entry["bInfo"] as? [String: Any]).map { MixAnalysis($0) } ?? songs[entry["b"] as? String ?? ""]
        let durationA = (entry["durationA"] as? NSNumber)?.doubleValue ?? a?.dur ?? 0
        let availableB = (entry["availableB"] as? NSNumber)?.doubleValue ?? b?.dur ?? 0
        return (MixPlanner.plan(a: a, b: b, durationA: durationA, availableB: availableB, mixOn: true), a, b)
    }

    func testRealSongsEqualTheReferenceToTheMillisecond() throws {
        let f = try fixtures()
        XCTAssertEqual(f.songs.count, 11)
        XCTAssertGreaterThanOrEqual(f.cases.count, 110)
        var plans = 0, synced = 0, none = 0
        for entry in f.cases {
            let name = "\(entry["a"] ?? "?") -> \(entry["b"] ?? "?")"
            let want = entry["result"] as? [String: Any] ?? [:]
            let got = decide(entry, f.songs).0
            if let reason = want["none"] as? String {
                XCTAssertEqual(got, .none(reason), name)
                none += 1
                continue
            }
            guard case .plan(let p) = got else {
                XCTFail("\(name): reference has a plan, planner says \(got)")
                continue
            }
            func value(_ key: String) -> Double { return (want[key] as? NSNumber)?.doubleValue ?? .nan }
            XCTAssertEqual(p.startA, value("startA"), accuracy: 0.001, name)
            XCTAssertEqual(p.overlap, value("overlap"), accuracy: 0.001, name)
            XCTAssertEqual(p.end, value("end"), accuracy: 0.001, name)
            XCTAssertEqual(p.bOffset, value("bOffset"), accuracy: 0.001, name)
            XCTAssertEqual(p.bDelay, value("bDelay"), accuracy: 0.001, name)
            XCTAssertEqual(p.synced, want["synced"] as? Bool, name)
            plans += 1
            if p.synced { synced += 1 }
        }
        print("RESULT mix planner vs reference: \(f.cases.count) pairs, \(plans) plans (\(synced) beat-matched), \(none) without")
        XCTAssertGreaterThanOrEqual(plans, 100)
        XCTAssertGreaterThanOrEqual(synced, 4)
        XCTAssertGreaterThanOrEqual(none, 3)
    }

    // MARK: what must hold for every plan

    private func check(_ p: MixPlan, _ a: MixAnalysis, _ b: MixAnalysis, _ name: String) {
        XCTAssertLessThanOrEqual(p.startA + p.overlap, p.end + 1e-6, name)
        XCTAssertGreaterThanOrEqual(p.bOffset, 0, name)
        XCTAssertGreaterThanOrEqual(p.bDelay, 0, name)
        XCTAssertLessThanOrEqual(p.bDelay, p.overlap / 2 + 1e-9, name)
        XCTAssertGreaterThanOrEqual(p.overlap, 2 - 1e-9, name)
        XCTAssertLessThanOrEqual(p.overlap, 8 + 1e-9, name)
        if p.synced, let bpmA = a.bpm, let bpmB = b.bpm, let beatA = a.beat0, let beatB = b.beat0 {
            /* B's first beat at or after its starting point falls on a beat of A. */
            let pa = 60 / bpmA, pb = 60 / bpmB
            let bBeat = beatB + ((p.bOffset - beatB) / pb).rounded(.up) * pb
            let atA = p.startA + (bBeat - p.bOffset)
            let beats = (atA - beatA) / pa
            XCTAssertEqual(beats, beats.rounded(), accuracy: 0.001 / pa, "\(name): beat alignment")
            XCTAssertEqual(p.bDelay, 0, name)
        }
    }

    func testEveryPlanKeepsTheRules() throws {
        let f = try fixtures()
        for entry in f.cases {
            let (decision, a, b) = decide(entry, f.songs)
            if case .plan(let p) = decision, let a = a, let b = b {
                check(p, a, b, "\(entry["a"] ?? "?") -> \(entry["b"] ?? "?")")
            }
        }
        /* and for a few thousand made-up songs */
        var random = TestRandom(seed: 77)
        func pick(_ low: Double, _ high: Double) -> Double { return low + (Double(random.next()) + 1) / 2 * (high - low) }
        var plans = 0, synced = 0
        for i in 0..<4000 {
            var a = MixAnalysis(), b = MixAnalysis()
            let dur = pick(20, 400)
            a.dur = dur
            a.bodyEnd = dur - pick(0, 30)
            a.tailEnd = min(dur, (a.bodyEnd ?? 0) + pick(0, 6))
            a.quietStart = (a.bodyEnd ?? 0) + pick(0, 1) * ((a.tailEnd ?? 0) - (a.bodyEnd ?? 0))
            a.bpm = pick(60, 180)
            a.beat0 = pick(0, 1)
            a.conf = pick(0, 8)
            b.dur = pick(5, 300)
            b.bodyStart = pick(0, 20)
            /* every other song gets a tempo that fits (same, double or half) */
            let factor: Double = [1.0, 2.0, 0.5][i % 3]
            let fitting: Double = (a.bpm ?? 100) * factor * pick(0.997, 1.003)
            b.bpm = i % 2 == 0 ? pick(60, 180) : fitting
            b.beat0 = pick(0, 1)
            b.conf = pick(0, 8)
            if case .plan(let p) = MixPlanner.plan(a: a, b: b, durationA: 0, availableB: 0, mixOn: true) {
                check(p, a, b, "made-up \(i)")
                XCTAssertGreaterThanOrEqual(p.startA, dur * 0.5)
                XCTAssertLessThanOrEqual(p.bOffset + p.overlap - p.bDelay, (b.dur ?? 0) + 1e-9)
                plans += 1
                if p.synced { synced += 1 }
            }
        }
        XCTAssertGreaterThan(plans, 1000)
        XCTAssertGreaterThan(synced, 100)
    }
}

final class MixShaperTests: XCTestCase {
    private func run(_ shaper: MixShaper, _ input: [Float], firstSample: Int, pieces: [Int]) -> (left: [Float], right: [Float]) {
        var outL: [Float] = [], outR: [Float] = []
        var at = 0, turn = 0
        while at < input.count {
            let n = min(pieces[turn % pieces.count], input.count - at)
            var l = Array(input[at..<(at + n)]), r = l
            shaper.process(left: &l, right: &r, firstSample: firstSample + at)
            outL.append(contentsOf: l)
            outR.append(contentsOf: r)
            at += n
            turn += 1
        }
        return (outL, outR)
    }

    /// A steady input of 1 comes out as the curve itself, whatever the size of the pieces;
    /// untouched (or silent) outside the overlap.
    func testSteadyInputGivesTheCurves() {
        let rate = 1000.0, overlap = 2.0, n = 2000
        let ones = [Float](repeating: 1, count: 3000)
        let incoming = run(MixShaper(role: .incoming, synced: false, overlap: overlap, sampleRate: rate), ones, firstSample: -500, pieces: [7, 300, 1, 999])
        let outgoing = run(MixShaper(role: .outgoing, synced: false, overlap: overlap, sampleRate: rate), ones, firstSample: -500, pieces: [1000, 3])
        XCTAssertEqual(incoming.left.count, 3000)
        for i in 0..<3000 {
            let s = i - 500
            let x = Double(s) / Double(n)
            var wantIn = MixCurve.incomingGain(x, synced: false)
            var wantOut = MixCurve.outgoingGain(x)
            if s < 0 { wantIn = 0; wantOut = 1 }
            if s >= n { wantIn = 1; wantOut = 0 }
            XCTAssertEqual(Double(incoming.left[i]), wantIn, accuracy: 1e-6, "incoming at \(s)")
            XCTAssertEqual(Double(incoming.right[i]), wantIn, accuracy: 1e-6)
            XCTAssertEqual(Double(outgoing.left[i]), wantOut, accuracy: 1e-6, "outgoing at \(s)")
        }
        /* the shapes themselves */
        XCTAssertEqual(MixCurve.incomingGain(0.25, synced: false), sin(Double.pi / 4), accuracy: 1e-12)
        XCTAssertEqual(MixCurve.incomingGain(0.5, synced: false), 1, accuracy: 1e-12, "full level at half the overlap")
        XCTAssertEqual(MixCurve.incomingGain(0.9, synced: false), 1, accuracy: 1e-12, "and it stays there")
        XCTAssertEqual(MixCurve.incomingGain(0.5, synced: true), sin(Double.pi / 4), accuracy: 1e-12)
        XCTAssertEqual(MixCurve.outgoingGain(0.5), cos(Double.pi / 4), accuracy: 1e-12)
        XCTAssertEqual(MixCurve.outgoingGain(0), 1)
        XCTAssertEqual(MixCurve.outgoingGain(1), 0)
    }

    /// How loud the two together can get. Beat-matched (equal power): the same signal in both
    /// never exceeds one of them by more than 3.01 dB. The ordinary curve keeps B at full level
    /// from the middle while A is still fading, so the same signal in both peaks at +4.9 dB;
    /// two different songs (powers add) peak at +1.9 dB.
    func testLevelOfTheTwoTogether() {
        var syncedPeak = 0.0, plainPeak = 0.0, plainPower = 0.0, syncedPower = 0.0
        for i in 0...10000 {
            let x = Double(i) / 10000
            let a = MixCurve.outgoingGain(x)
            syncedPeak = max(syncedPeak, a + MixCurve.incomingGain(x, synced: true))
            plainPeak = max(plainPeak, a + MixCurve.incomingGain(x, synced: false))
            let bs = MixCurve.incomingGain(x, synced: true), bp = MixCurve.incomingGain(x, synced: false)
            syncedPower = max(syncedPower, abs(a * a + bs * bs - 1))
            plainPower = max(plainPower, a * a + bp * bp)
        }
        let dB = { (v: Double) in 20 * log10(v) }
        print("RESULT mix levels: same signal in both: beat-matched +\(String(format: "%.2f", dB(syncedPeak))) dB, ordinary +\(String(format: "%.2f", dB(plainPeak))) dB; different songs, ordinary: +\(String(format: "%.2f", 10 * log10(plainPower))) dB")
        XCTAssertLessThanOrEqual(dB(syncedPeak), 3.1)
        XCTAssertLessThan(syncedPower, 1e-9, "beat-matched curves keep the power of the two together constant")
        XCTAssertLessThanOrEqual(dB(plainPeak), 5.0)
        XCTAssertLessThanOrEqual(10 * log10(plainPower), 2.0)
    }

    private func sine(_ frequency: Double, rate: Double, seconds: Double) -> [Float] {
        return (0..<Int(rate * seconds)).map { Float(sin(2 * Double.pi * frequency * Double($0) / rate)) }
    }

    private func power(_ x: [Float], rate: Double, around t: Double, width: Double = 0.2) -> Double {
        let a = Int((t - width / 2) * rate), b = Int((t + width / 2) * rate)
        var sum = 0.0
        for i in a..<b { sum += Double(x[i]) * Double(x[i]) }
        return sum / Double(b - a)
    }

    /// Beat-matched: the bass changes hands around the middle. A 50 Hz tone is carried by the
    /// outgoing song before the middle and by the incoming one after it, and through the change
    /// the bass of the two together stays about as strong as everything else (a 5 kHz tone,
    /// which the high-pass does not touch).
    func testBassChangesHandsInTheMiddle() {
        let rate = 44100.0, overlap = 6.0
        func shaped(_ role: MixShaper.Role, _ frequency: Double) -> [Float] {
            return run(MixShaper(role: role, synced: true, overlap: overlap, sampleRate: rate),
                       sine(frequency, rate: rate, seconds: overlap), firstSample: 0, pieces: [4096]).left
        }
        let lowOut = shaped(.outgoing, 50), lowIn = shaped(.incoming, 50)
        let highOut = shaped(.outgoing, 5000), highIn = shaped(.incoming, 5000)
        let full = 0.5   // power of a sine of amplitude 1
        func dB(_ p: Double) -> Double { return 10 * log10(max(p, 1e-12) / full) }

        /* a quarter in: A has the bass, B has (almost) none */
        XCTAssertGreaterThan(dB(power(lowOut, rate: rate, around: 1.5)), -1.5)
        XCTAssertLessThan(dB(power(lowIn, rate: rate, around: 1.5)), -30)
        /* three quarters in: the other way round */
        XCTAssertLessThan(dB(power(lowOut, rate: rate, around: 4.5)), -30)
        XCTAssertGreaterThan(dB(power(lowIn, rate: rate, around: 4.5)), -1.5)
        /* the swap takes min(1, overlap / 8) = 0.75 s around the middle */
        XCTAssertEqual(MixCurve.bassShare(0.5 - 0.375 / 6, overlap: overlap, incoming: true), 0, accuracy: 1e-9)
        XCTAssertEqual(MixCurve.bassShare(0.5 + 0.375 / 6, overlap: overlap, incoming: true), 1, accuracy: 1e-9)
        XCTAssertEqual(MixCurve.bassShare(0.5, overlap: overlap, incoming: false), cos(Double.pi / 4), accuracy: 1e-9)

        /* the two together (powers added, as for two different songs), through the swap */
        var worstLow = 0.0, worstHigh = 0.0
        var line = ""
        for t in [2.4, 2.7, 3.0, 3.3, 3.6] {
            let low = dB(power(lowOut, rate: rate, around: t) + power(lowIn, rate: rate, around: t))
            let high = dB(power(highOut, rate: rate, around: t) + power(highIn, rate: rate, around: t))
            line += String(format: " %.1fs: bass %.2f dB, treble %.2f dB;", t, low, high)
            worstLow = max(worstLow, abs(low - high))
            worstHigh = max(worstHigh, abs(high))
        }
        print("RESULT bass hand-over, both songs together:\(line)")
        XCTAssertLessThan(worstHigh, 0.1, "what the high-pass does not touch keeps its power")
        XCTAssertLessThan(worstLow, 3.5, "the bass of the two together is never far below the rest")
    }

    /// A song that keeps all of its bass comes out exactly as it went in: the split into
    /// "what the high-pass lets through" and "the rest" adds up again.
    func testFullBassShareIsTransparent() {
        let rate = 44100.0
        var random = TestRandom(seed: 3)
        let noise = (0..<20000).map { _ in random.next() }
        /* the first 2 s of an 8 s beat-matched overlap: the outgoing song still has all its bass */
        let out = run(MixShaper(role: .outgoing, synced: true, overlap: 8, sampleRate: rate), noise, firstSample: 0, pieces: [1024])
        for i in stride(from: 0, to: 20000, by: 97) {
            let gain = MixCurve.outgoingGain(Double(i) / (8 * rate))
            XCTAssertEqual(Double(out.left[i]), Double(noise[i]) * gain, accuracy: 1e-5)
        }
    }
}
