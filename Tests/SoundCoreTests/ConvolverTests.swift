import XCTest
import SoundCore

final class ConvolverTests: XCTestCase {
    /// Slow, obviously correct convolution: out[n] = sum of x[n - k] * h[k].
    private func direct(_ x: [Float], _ h: [Float]) -> [Double] {
        var out = [Double](repeating: 0, count: x.count)
        for n in 0..<x.count {
            var sum = 0.0
            let last = min(n, h.count - 1)
            if last >= 0 {
                for k in 0...last { sum += Double(x[n - k]) * Double(h[k]) }
            }
            out[n] = sum
        }
        return out
    }

    private func trueStereo(_ l: [Float], _ r: [Float], _ irL: [[Float]], _ irR: [[Float]]) -> (left: [Double], right: [Double]) {
        let a = direct(l, irL[0]), b = direct(r, irR[0]), c = direct(l, irL[1]), d = direct(r, irR[1])
        return (zip(a, b).map { $0 + $1 }, zip(c, d).map { $0 + $1 })
    }

    private func noise(_ count: Int, seed: UInt32, scale: Float = 1) -> [Float] {
        var random = TestRandom(seed: seed)
        return (0..<count).map { _ in random.next() * scale }
    }

    private func worst(_ got: [Float], _ want: [Double]) -> Double {
        var w = 0.0
        for i in 0..<min(got.count, want.count) { w = max(w, abs(Double(got[i]) - want[i])) }
        return w
    }

    /// Feeds the convolver pieces of the given sizes (repeating the list) and joins the output.
    private func run(_ c: TrueStereoConvolver, _ l: [Float], _ r: [Float], pieces: [Int]) -> (left: [Float], right: [Float]) {
        var outL: [Float] = [], outR: [Float] = []
        var at = 0, turn = 0
        while at < l.count {
            let n = min(pieces[turn % pieces.count], l.count - at)
            let out = c.process(left: Array(l[at..<(at + n)]), right: Array(r[at..<(at + n)]))
            XCTAssertEqual(out.left.count % c.blockSize, 0, "output must come in whole blocks")
            outL.append(contentsOf: out.left)
            outR.append(contentsOf: out.right)
            at += n
            turn += 1
        }
        let rest = c.flush()
        outL.append(contentsOf: rest.left)
        outR.append(contentsOf: rest.right)
        return (outL, outR)
    }

    private let count = 3000
    /* Different lengths on purpose, and longer than several blocks of 64. */
    private lazy var irL: [[Float]] = [noise(150, seed: 11, scale: 0.1), noise(97, seed: 12, scale: 0.1)]
    private lazy var irR: [[Float]] = [noise(131, seed: 13, scale: 0.1), noise(200, seed: 14, scale: 0.1)]
    private lazy var inL: [Float] = noise(count, seed: 1)
    private lazy var inR: [Float] = noise(count, seed: 2)

    func testEqualsDirectConvolutionWithAwkwardPieceSizes() {
        let want = trueStereo(inL, inR, irL, irR)
        for pieces in [[3000], [64], [1], [63, 65, 1, 200, 7, 129], [1000, 13], [4096]] {
            let c = TrueStereoConvolver(irLeft: irL, irRight: irR, blockSize: 64)
            let got = run(c, inL, inR, pieces: pieces)
            XCTAssertEqual(got.left.count, count, "pieces \(pieces)")
            XCTAssertEqual(got.right.count, count, "pieces \(pieces)")
            XCTAssertLessThan(worst(got.left, want.left), 1e-4, "left ear, pieces \(pieces)")
            XCTAssertLessThan(worst(got.right, want.right), 1e-4, "right ear, pieces \(pieces)")
        }
    }

    func testOtherBlockSizesGiveTheSame() {
        let want = trueStereo(inL, inR, irL, irR)
        for size in [16, 256, 1024] {
            let c = TrueStereoConvolver(irLeft: irL, irRight: irR, blockSize: size)
            XCTAssertEqual(c.blockSize, size)
            let got = run(c, inL, inR, pieces: [777])
            XCTAssertLessThan(worst(got.left, want.left), 1e-4, "block \(size)")
            XCTAssertLessThan(worst(got.right, want.right), 1e-4, "block \(size)")
        }
    }

    /// What a seek does. Processing restarted at sample `s` knows nothing of the sound before
    /// it. So (1) its output is exactly the convolution of the input from `s` on, as if
    /// silence came before; and (2) compared with the uninterrupted result it only lacks the
    /// echo of the earlier sound, which has died out after (longest response − 1) samples:
    /// from there on the two are identical.
    func testRestartAtAnOffset() {
        let s = 1234
        let full = trueStereo(inL, inR, irL, irR)
        let tailL = Array(inL[s...]), tailR = Array(inR[s...])
        let alone = trueStereo(tailL, tailR, irL, irR)

        let c = TrueStereoConvolver(irLeft: irL, irRight: irR, blockSize: 64)
        /* Used first for something else, then reset: must behave like a new one. */
        _ = c.process(left: Array(inL[0..<500]), right: Array(inR[0..<500]))
        c.reset()
        let got = run(c, tailL, tailR, pieces: [100, 333])
        XCTAssertEqual(got.left.count, count - s)
        XCTAssertLessThan(worst(got.left, alone.left), 1e-4)
        XCTAssertLessThan(worst(got.right, alone.right), 1e-4)

        let settled = 200 - 1
        var w = 0.0
        for n in settled..<(count - s) {
            w = max(w, abs(Double(got.left[n]) - full.left[s + n]), abs(Double(got.right[n]) - full.right[s + n]))
        }
        XCTAssertLessThan(w, 1e-4, "after the old echo has died out the output equals the uninterrupted one")
        /* And before that it really differs, otherwise this test would prove nothing. */
        XCTAssertGreaterThan(abs(Double(got.left[0]) - full.left[s]), 1e-3)
    }

    func testAnImpulseGivesBackTheImpulseResponses() {
        var l = [Float](repeating: 0, count: 400), r = [Float](repeating: 0, count: 400)
        l[0] = 1
        r[10] = 1
        let c = TrueStereoConvolver(irLeft: irL, irRight: irR, blockSize: 64)
        let got = run(c, l, r, pieces: [50])
        /* Left ear hears irL[0] from the left input and irR[0], ten samples later, from the right. */
        for n in 0..<300 {
            let a = n < irL[0].count ? irL[0][n] : 0
            let b = (n >= 10 && n - 10 < irR[0].count) ? irR[0][n - 10] : 0
            XCTAssertEqual(got.left[n], a + b, accuracy: 1e-5)
        }
    }

    func testSurroundChainAppliesMakeupAndPassesThroughWhenOff() {
        let off = SurroundChain(settings: SurroundSettings(key: "off", surround: false, irLeft: nil, irRight: nil, makeup: 0.5), sampleRate: 44100)
        let out = off.process(left: [1, -1, 0.25], right: [0.5, 0, 1])
        XCTAssertEqual(out.left, [0.5, -0.5, 0.125])
        XCTAssertEqual(out.right, [0.25, 0, 0.5])
        XCTAssertNil(off.problem)
        XCTAssertEqual(off.finish().left.count, 0)

        let broken = SurroundChain(settings: SurroundSettings(key: "x", surround: true, irLeft: Data([1, 2, 3]), irRight: Data(), makeup: 1), sampleRate: 44100)
        XCTAssertNotNil(broken.problem, "a bad impulse response must be reported, not ignored silently")
        XCTAssertEqual(broken.process(left: [0.3], right: [0.4]).left, [0.3])
    }
}
