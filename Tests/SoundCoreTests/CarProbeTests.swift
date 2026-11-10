import XCTest
import SoundCore

/// The "measure this car" analysis (App/Sound/CarProbeCore.swift) on made-up recordings: the
/// probe's left channel as if one speaker played it, each cell with its own known gain, some
/// background noise, and the probe starting at a different place in the recording.
final class CarProbeTests: XCTestCase {
    /// What a speaker with these per-cell gains (dB) would give: the left channel of the probe,
    /// `lead` seconds of silence in front, white noise of `noiseDb` dBFS RMS on top.
    private func recording(rate: Double, gains: [String: Double], lead: Double, noiseDb: Double,
                           seed: UInt32, extraGain: Double = 1) -> [Float] {
        let probe = CarProbe.generate(sampleRate: rate).left
        let start = Int((lead * rate).rounded())
        var out = [Float](repeating: 0, count: start + probe.count + Int(1.0 * rate))
        let cells = CarProbe.cells.map { ($0.start - 0.05, $0.start + CarProbe.cellDuration + 0.05, pow(10, (gains[$0.id] ?? 0) / 20)) }
        for (i, v) in probe.enumerated() {
            let t = Double(i) / rate
            var g = 1.0
            for c in cells where t >= c.0 && t < c.1 { g = c.2 }
            out[start + i] = Float(Double(v) * g * extraGain)
        }
        var random = TestRandom(seed: seed)
        let sigma = Float(pow(10, noiseDb / 20) * 3.0.squareRoot())   // uniform -1..1 has RMS 1/sqrt(3)
        for i in 0..<out.count { out[i] += random.next() * sigma }
        if extraGain > 1 { for i in 0..<out.count { out[i] = max(-1, min(1, out[i])) } }
        return out
    }

    /// The level each cell should come out at, relative to the reference: its own gain plus the
    /// designed level of the left channel.
    private func expected(_ gains: [String: Double]) -> [String: Double] {
        func left(_ cell: CarProbeCell) -> Double {
            return 20 * log10(CarProbe.channelGains(diffDb: cell.diffDb).0) + (gains[cell.id] ?? 0)
        }
        let ref = left(CarProbe.cells.first { $0.id == CarProbe.referenceId }!)
        var out: [String: Double] = [:]
        for cell in CarProbe.cells { out[cell.id] = left(cell) - ref }
        return out
    }

    private let gains: [String: Double] = [
        "B1/inphase/0": 0, "B1/inphase/+15": 4, "B1/inphase/-15": -6, "B1/indep/0": 2.5,
        "B1/anti/0": -3, "B1/anti/+15": 5, "B2/inphase/0": -2, "B2/anti/0": 1,
        "LF/inphase/0": 3, "LF/anti/0": -8
    ]

    func testProbeIsRepeatableAndDescribed() {
        XCTAssertEqual(CarProbe.cells.count, 10)
        XCTAssertEqual(CarProbe.cells.first?.id, CarProbe.referenceId)
        XCTAssertEqual(Set(CarProbe.cells.map { $0.id }).count, 10)
        XCTAssertFalse(CarProbe.version.isEmpty)
        XCTAssertEqual((CarProbe.definition["cells"] as? [[String: Any]])?.count, 10)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(CarProbe.definition))
        XCTAssertEqual(CarProbe.duration, 12.7, accuracy: 1e-9)
        let a = CarProbe.generate(sampleRate: 48000)
        let b = CarProbe.generate(sampleRate: 48000)
        XCTAssertEqual(a.left, b.left)
        XCTAssertEqual(a.right, b.right)
        XCTAssertEqual(a.left.count, Int((CarProbe.duration * 48000).rounded()))
        let peak = max(a.left.map { abs($0) }.max() ?? 0, a.right.map { abs($0) }.max() ?? 0)
        XCTAssertLessThan(peak, 0.7)
        XCTAssertGreaterThan(peak, 0.05)
        XCTAssertFalse(a.left.contains { !$0.isFinite })
    }

    /// Each cell's total power is the same, and the left/right relation is the designed one.
    func testCellsHaveTheDesignedLevels() {
        let rate = 48000.0
        let p = CarProbe.generate(sampleRate: rate)
        for cell in CarProbe.cells {
            let a = Int(((cell.start + CarProbe.analysisOffset) * rate).rounded())
            let b = a + Int((CarProbe.analysisLength * rate).rounded())
            var pl = 0.0, pr = 0.0, lr = 0.0
            for i in a..<b {
                pl += Double(p.left[i]) * Double(p.left[i])
                pr += Double(p.right[i]) * Double(p.right[i])
                lr += Double(p.left[i]) * Double(p.right[i])
            }
            let n = Double(b - a)
            XCTAssertEqual(10 * log10((pl + pr) / n), CarProbe.totalRmsDb, accuracy: 0.05, cell.id)
            XCTAssertEqual(10 * log10(pl / pr), cell.diffDb, accuracy: 0.05, cell.id)
            let corr = lr / (pl * pr).squareRoot()
            let want: Double = cell.state == "inphase" ? 1 : (cell.state == "anti" ? -1 : 0)
            XCTAssertEqual(corr, want, accuracy: 0.02, cell.id)
        }
    }

    func testLevelsComeOutRightAtEveryStartOffset() {
        for rate in [48000.0, 44100.0] {
            /* nominal latency 0.25 s, then -100 ms, +100 ms and in between */
            for (k, lead) in [0.25, 0.15, 0.35, 0.187, 0.311].enumerated() {
                let rec = recording(rate: rate, gains: gains, lead: lead, noiseDb: -75, seed: UInt32(7 + k))
                let r = CarProbeAnalyzer.analyze(rec, sampleRate: rate)
                guard let sync = r.sync else { return XCTFail("no beep found, lead \(lead)") }
                XCTAssertTrue(sync.found, "lead \(lead): ncc \(sync.ncc) ratio \(sync.ratio)")
                let truth = Int(((lead + CarProbe.beepStart) * rate).rounded())
                XCTAssertLessThanOrEqual(abs(sync.sample - truth), 2, "rate \(rate) lead \(lead)")
                XCTAssertEqual(r.latency, lead, accuracy: 0.001)
                let want = expected(gains)
                XCTAssertEqual(r.levels.count, CarProbe.cells.count)
                for (id, v) in want {
                    guard let got = r.levels[id] else { XCTFail("missing \(id)"); continue }
                    XCTAssertEqual(got, v, accuracy: 0.5, "rate \(rate) lead \(lead) \(id)")
                }
                XCTAssertFalse(r.clipped)
                XCTAssertFalse(r.needsRetake, "\(r.problems)")
                XCTAssertGreaterThan(r.snrDb ?? 0, 10)
                XCTAssertEqual(r.snrByCell.count, CarProbe.cells.count)
                XCTAssertEqual(r.snrByCell[CarProbe.referenceId] ?? 0, r.snrDb ?? -1, accuracy: 0.01)
            }
        }
    }

    func testLowSignalAskForARetake() {
        let rate = 48000.0
        /* reference cell about -23 dBFS, white noise -25 dBFS (about -31 dBFS in the measuring band): under 10 dB */
        let rec = recording(rate: rate, gains: gains, lead: 0.3, noiseDb: -25, seed: 99)
        let r = CarProbeAnalyzer.analyze(rec, sampleRate: rate)
        if let snr = r.snrDb {
            XCTAssertLessThan(snr, CarProbeAnalyzer.minSnrDb)
        }
        XCTAssertTrue(r.needsRetake)

        /* the same with quiet background: about 40 dB, fine */
        let good = CarProbeAnalyzer.analyze(recording(rate: rate, gains: gains, lead: 0.3, noiseDb: -70, seed: 98), sampleRate: rate)
        XCTAssertGreaterThan(good.snrDb ?? 0, 30)
        XCTAssertFalse(good.needsRetake, "\(good.problems)")
    }

    func testClippingAsksForARetake() {
        let rate = 48000.0
        let rec = recording(rate: rate, gains: gains, lead: 0.3, noiseDb: -70, seed: 5, extraGain: 8)
        let r = CarProbeAnalyzer.analyze(rec, sampleRate: rate)
        XCTAssertTrue(r.clipped)
        XCTAssertTrue(r.needsRetake)
    }

    func testNoBeepInNoise() {
        var random = TestRandom(seed: 3)
        let rec = (0..<Int(14 * 48000.0)).map { _ in random.next() * 0.05 }
        let r = CarProbeAnalyzer.analyze(rec, sampleRate: 48000)
        XCTAssertFalse(r.sync?.found ?? false)
        XCTAssertTrue(r.needsRetake)
        XCTAssertTrue(r.levels.isEmpty)
    }

    func testCutShortRecording() {
        let rate = 48000.0
        let full = recording(rate: rate, gains: gains, lead: 0.25, noiseDb: -70, seed: 11)
        let short = Array(full[0..<Int(8 * rate)])
        let r = CarProbeAnalyzer.analyze(short, sampleRate: rate)
        XCTAssertTrue(r.sync?.found ?? false)
        XCTAssertTrue(r.needsRetake)
        XCTAssertLessThan(r.levels.count, CarProbe.cells.count)
        XCTAssertFalse(r.levels.values.contains { !$0.isFinite })
    }
}
