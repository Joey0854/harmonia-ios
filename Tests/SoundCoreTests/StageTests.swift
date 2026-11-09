import XCTest
import SoundCore

/// The expected numbers come from a double-precision reference of the same algorithm (Node,
/// same test signals, same random numbers); the tolerances allow for Float.
final class StageTests: XCTestCase {
    private let rate = 44100
    private let count = 44100
    private let pieces = [1000, 37, 4096, 513]

    private func sine(_ frequency: Double, amplitude: Double = 0.5) -> [Float] {
        return (0..<count).map { Float(amplitude * sin(2 * Double.pi * frequency * Double($0) / Double(rate))) }
    }

    private func noise(seed: UInt32) -> [Float] {
        var random = TestRandom(seed: seed)
        return (0..<count).map { _ in random.next() * 0.5 }
    }

    private func energy(_ x: [Float], from: Int = 0) -> Double {
        var e = 0.0
        for i in from..<x.count { e += Double(x[i]) * Double(x[i]) }
        return e
    }

    private func finite(_ x: [Float]) -> Bool {
        return !x.contains { !$0.isFinite }
    }

    /// Feeds the splitter in pieces of the given sizes and joins each source's output.
    private func split(_ l: [Float], _ r: [Float], pieces: [Int]? = nil) -> [[[Float]]] {
        let splitter = StageSplitter(sampleRate: rate)
        var out = [[[Float]]](repeating: [[], []], count: StageSplitter.sourceCount)
        func add(_ part: [[[Float]]]) {
            for s in 0..<StageSplitter.sourceCount {
                out[s][0].append(contentsOf: part[s][0])
                out[s][1].append(contentsOf: part[s][1])
            }
        }
        let sizes = pieces ?? self.pieces
        var at = 0, turn = 0
        while at < l.count {
            let n = min(sizes[turn % sizes.count], l.count - at)
            add(splitter.process(left: Array(l[at..<(at + n)]), right: Array(r[at..<(at + n)])))
            at += n
            turn += 1
        }
        add(splitter.flush())
        return out
    }

    private func stage(_ params: StageParams, _ l: [Float], _ r: [Float], pieces: [Int]? = nil) -> (left: [Float], right: [Float]) {
        let p = StageProcessor(params: params, sampleRate: rate)
        var outL: [Float] = [], outR: [Float] = []
        let sizes = pieces ?? self.pieces
        var at = 0, turn = 0
        while at < l.count {
            let n = min(sizes[turn % sizes.count], l.count - at)
            let o = p.process(left: Array(l[at..<(at + n)]), right: Array(r[at..<(at + n)]))
            outL.append(contentsOf: o.left)
            outR.append(contentsOf: o.right)
            at += n
            turn += 1
        }
        let rest = p.finish()
        outL.append(contentsOf: rest.left)
        outR.append(contentsOf: rest.right)
        return (outL, outR)
    }

    /// Share of the input's energy that ends up in each source (the first 4096 samples, while
    /// the averages settle, are left out).
    private func shares(_ l: [Float], _ r: [Float]) -> [Double] {
        let o = split(l, r)
        let from = 4096
        let total = energy(l, from: from) + energy(r, from: from)
        return o.map { (energy($0[0], from: from) + energy($0[1], from: from)) / total }
    }

    func testSourcesAddUpToTheInput() {
        let a = noise(seed: 1), b = noise(seed: 2), tone = sine(440, amplitude: 0.3)
        let l = (0..<count).map { a[$0] + tone[$0] }
        let r = (0..<count).map { 0.6 * a[$0] + 0.4 * b[$0] }
        let o = split(l, r)
        var worst: Float = 0
        for s in 0..<StageSplitter.sourceCount {
            XCTAssertEqual(o[s][0].count, count)
            XCTAssertEqual(o[s][1].count, count)
            XCTAssertTrue(finite(o[s][0]) && finite(o[s][1]))
        }
        for i in 0..<count {
            var sl: Float = 0, sr: Float = 0
            for s in 0..<StageSplitter.sourceCount {
                sl += o[s][0][i]
                sr += o[s][1][i]
            }
            worst = max(worst, abs(sl - l[i]), abs(sr - r[i]))
        }
        /* reference (double): 5.6e-16 */
        XCTAssertLessThan(worst, 1e-4)
    }

    func testTestSignalsLandInTheRightSource() {
        let tone = sine(1000), silent = [Float](repeating: 0, count: count)
        /* reference shares: 1.0000 in each case */
        XCTAssertGreaterThan(shares(tone, tone)[1], 0.99, "centre sine -> center")
        XCTAssertGreaterThan(shares(tone, silent)[2], 0.99, "left-only sine -> sideL")
        XCTAssertGreaterThan(shares(silent, tone)[3], 0.99, "right-only sine -> sideR")
        XCTAssertGreaterThan(shares(tone.map { 0.8 * $0 }, tone.map { 0.2 * $0 })[2], 0.95, "left-leaning sine -> sideL")
        /* reference: 0.9998 */
        let low = sine(60)
        XCTAssertGreaterThan(shares(low, low)[0], 0.99, "60 Hz -> low")
        /* reference: ambience 0.6029 for independent noise, center 0.9943 for identical noise */
        XCTAssertEqual(shares(noise(seed: 3), noise(seed: 4))[4], 0.6029, accuracy: 0.03)
        let same = noise(seed: 5)
        XCTAssertEqual(shares(same, same)[1], 0.9943, accuracy: 0.01)
    }

    func testPlacerDirectionAndNeutral() {
        let placer = StagePlacer(sources: 1, sampleRate: rate)
        placer.positions = [StagePosition(azimuth: 60, depth: 0, width: 1, gain: 1)]
        var impulse = [Float](repeating: 0, count: 200)
        impulse[10] = 1
        let out = placer.process([[impulse]])
        XCTAssertEqual(placer.delaySamples(azimuth: 60), 27)
        XCTAssertEqual(out.right.firstIndex(where: { $0 != 0 }), 10)
        XCTAssertEqual(out.left.firstIndex(where: { $0 != 0 }), 37)
        XCTAssertEqual(out.right[10], 1.3660, accuracy: 1e-3)
        XCTAssertEqual(out.left[37], 0.3660, accuracy: 1e-3)

        let neutral = StagePlacer(sources: 1, sampleRate: rate)
        let l = Array(noise(seed: 7).prefix(5000)), r = Array(noise(seed: 8).prefix(5000))
        let same = neutral.process([[l, r]])
        var worst: Float = 0
        for i in 0..<5000 { worst = max(worst, abs(same.left[i] - l[i]), abs(same.right[i] - r[i])) }
        XCTAssertLessThan(worst, 1e-6)
    }

    func testNeutralStageGivesTheInputBack() {
        let l = noise(seed: 11), n = noise(seed: 12)
        let r = (0..<count).map { 0.5 * n[$0] + 0.5 * l[$0] }
        let out = stage(.neutral, l, r)
        XCTAssertEqual(out.left.count, count)
        XCTAssertEqual(out.right.count, count)
        var worst: Float = 0
        for i in 0..<count { worst = max(worst, abs(out.left[i] - l[i]), abs(out.right[i] - r[i])) }
        /* reference: 4.4e-16, energy ratio 1.000000 */
        XCTAssertLessThan(worst, 1e-4)
        XCTAssertEqual((energy(out.left) + energy(out.right)) / (energy(l) + energy(r)), 1, accuracy: 1e-4)
    }

    func testStageLevelsAndPieces() {
        let l = noise(seed: 11), n = noise(seed: 12)
        let r = (0..<count).map { 0.5 * n[$0] + 0.5 * l[$0] }
        let car = StageParams(width: 60, depth: 40, vocal: 30)
        let whole = stage(car, l, r, pieces: [count]), bits = stage(car, l, r)
        var worst: Float = 0
        for i in 0..<count { worst = max(worst, abs(whole.left[i] - bits.left[i]), abs(whole.right[i] - bits.right[i])) }
        XCTAssertLessThan(worst, 1e-6, "piece sizes must not matter")
        /* reference energy ratios (output / input) for noise */
        let cases: [(StageParams, Double)] = [
            (car, 1.0255),
            (StageParams(width: 100, depth: 100, vocal: 100), 1.3331),
            (StageParams(width: 100, depth: 0, vocal: 0), 1.2507),
            (StageParams(width: 0, depth: 100, vocal: 0), 0.9659),
            (StageParams(width: 0, depth: 0, vocal: 100), 1.0352)
        ]
        for (params, want) in cases {
            let out = stage(params, l, r, pieces: [count])
            XCTAssertEqual(out.left.count, count)
            XCTAssertTrue(finite(out.left) && finite(out.right), "\(params)")
            XCTAssertEqual((energy(out.left) + energy(out.right)) / (energy(l) + energy(r)), want, accuracy: 0.02, "\(params)")
        }
    }

    func testStageKeepsTheCentreAndWidensTheSides() {
        let car = StageParams(width: 60, depth: 40, vocal: 30)
        let tone = sine(1000)
        let centre = stage(car, tone, tone, pieces: [count])
        let el = energy(centre.left, from: 4096), er = energy(centre.right, from: 4096)
        XCTAssertLessThan(abs(el - er) / (el + er), 1e-4, "a centred sound stays centred")
        let a = tone.map { 0.8 * $0 }, b = tone.map { 0.2 * $0 }
        let lean = stage(car, a, b, pieces: [count])
        let before = energy(a, from: 4096) / (energy(a, from: 4096) + energy(b, from: 4096))
        let after = energy(lean.left, from: 4096) / (energy(lean.left, from: 4096) + energy(lean.right, from: 4096))
        /* reference: 0.9412 -> 0.9536 */
        XCTAssertGreaterThan(after, before + 0.005)
    }

    func testSurroundChainStageMode() {
        let l = noise(seed: 21), r = noise(seed: 22)
        let settings = SurroundSettings(key: "stage-0-0-0", surround: true, irLeft: nil, irRight: nil, makeup: 0.5,
                                        mode: .stage, stage: .neutral)
        let chain = SurroundChain(settings: settings, sampleRate: rate)
        XCTAssertNil(chain.problem)
        var outL: [Float] = [], outR: [Float] = []
        var at = 0
        while at < count {
            let n = min(3000, count - at)
            let o = chain.process(left: Array(l[at..<(at + n)]), right: Array(r[at..<(at + n)]))
            outL.append(contentsOf: o.left)
            outR.append(contentsOf: o.right)
            at += n
        }
        let rest = chain.finish()
        outL.append(contentsOf: rest.left)
        outR.append(contentsOf: rest.right)
        XCTAssertEqual(outL.count, count)
        XCTAssertEqual(outR.count, count)
        var worst: Float = 0
        for i in 0..<count { worst = max(worst, abs(outL[i] - 0.5 * l[i]), abs(outR[i] - 0.5 * r[i])) }
        XCTAssertLessThan(worst, 1e-4, "output sample n belongs to input sample n")
    }
}
