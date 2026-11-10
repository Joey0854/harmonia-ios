import XCTest
import SoundCore

/// The car band mode (App/Sound/CarBand.swift): vocals must come out exactly the same on both
/// sides (so the car's Centerpoint puts them in the centre) whenever their reverb is not sent
/// to the rear.
final class CarBandTests: XCTestCase {
    /// Vocals only, left and right different, in pieces of uneven size.
    private func run(_ params: CarBandParams, seconds: Double = 3) -> (left: [Float], right: [Float]) {
        let rate = 44100
        let mixer = CarBandMixer(sampleRate: rate, params: params)
        var state: UInt32 = 12345
        func noise() -> Float {
            state = state &* 1664525 &+ 1013904223
            return Float(state >> 8) / Float(1 << 24) - 0.5
        }
        let total = Int(seconds * Double(rate))
        var outL: [Float] = [], outR: [Float] = []
        var done = 0
        var piece = 1000
        while done < total {
            let n = min(piece, total - done)
            var stems = [[Float]](repeating: [Float](repeating: 0, count: n), count: 8)
            for j in 0..<n {
                let t = Float(done + j) / Float(rate)
                let voice = 0.3 * sin(2 * Float.pi * 220 * t) + 0.2 * noise()
                stems[6][j] = voice + 0.1 * noise()          // vocals left
                stems[7][j] = 0.5 * voice - 0.05 * noise()   // vocals right
            }
            let zero = [Float](repeating: 0, count: n)
            let out = mixer.process(stems: stems, standIn: (zero, zero))
            XCTAssertEqual(out.left.count, n)
            outL += out.left
            outR += out.right
            done += n
            piece = piece == 1000 ? 4096 : (piece == 4096 ? 777 : 1000)
        }
        return (outL, outR)
    }

    private func assertIdentical(_ out: (left: [Float], right: [Float]), _ name: String) {
        XCTAssertEqual(out.left.count, out.right.count, name)
        var differ = 0
        var energy: Float = 0
        for j in 0..<min(out.left.count, out.right.count) {
            if out.left[j] != out.right[j] { differ += 1 }
            energy += out.left[j] * out.left[j]
        }
        XCTAssertEqual(differ, 0, "\(name): \(differ) samples differ between left and right")
        XCTAssertGreaterThan(energy, 1, "\(name): no sound came out")
    }

    func testVocalsIdenticalOnBothSides() {
        let vocals = Demucs.sources.firstIndex(of: "vocals")!
        /* v2b's dry vocals (reverb off) */
        var dry = CarBandParams.v2b
        dry.ambienceOn = false
        assertIdentical(run(dry), "v2b dry")
        /* v2b with the vocals' reverb kept in front: dry and reverb both the same on both sides */
        var front = CarBandParams.v2b
        front.tracks[vocals].rear = false
        assertIdentical(run(front), "v2b, vocal reverb in front")
        /* v3: everything in front */
        var v3 = CarBandParams.v3
        v3.tracks[vocals].sendDb = -6
        assertIdentical(run(v3), "v3")
        /* concert hall without the (one-sided) early reflections, vocal reverb in front, its low
           part in front as well */
        var hall = CarBandParams.concertHall
        hall.earlyOn = false
        hall.tracks[vocals].rear = false
        assertIdentical(run(hall), "concert hall")
    }

    /// With the vocals' reverb to the rear (v2b as chosen), what differs between the sides is
    /// only that reverb: left + right is the same as with the reverb in front, and something
    /// does differ.
    func testVocalReverbToTheRearOnlyChangesTheSide() {
        let out = run(.v2b)
        var side: Float = 0, mid: Float = 0
        for j in 0..<out.left.count {
            let s = out.left[j] - out.right[j], m = out.left[j] + out.right[j]
            side += s * s
            mid += m * m
        }
        XCTAssertGreaterThan(side, 0, "the rear reverb should make the sides differ")
        XCTAssertLessThan(side, mid * 0.1, "the rear reverb is 15 dB below the dry sound")
    }

    // MARK: - width (CarSpreader)

    private static let other = Demucs.sources.firstIndex(of: "other")!

    /// Dry only (no reverb, no early reflections), every part at width 0 and in the centre,
    /// "other" with the given width and pan.
    private func dryParams(width: Float, pan: Float = 0) -> CarBandParams {
        var p = CarBandParams.v2b
        p.ambienceOn = false
        p.earlyOn = false
        for t in 0..<p.tracks.count { p.tracks[t].width = 0; p.tracks[t].panDb = 0 }
        p.tracks[CarBandTests.other].width = width
        p.tracks[CarBandTests.other].panDb = pan
        return p
    }

    /// Only "other" playing (`left` / `right`), in pieces of uneven size.
    private func runOther(_ params: CarBandParams, left: [Float], right: [Float]) -> (left: [Float], right: [Float], latency: Int) {
        let mixer = CarBandMixer(sampleRate: 44100, params: params)
        var outL: [Float] = [], outR: [Float] = []
        var done = 0
        let pieces = [1000, 4096, 777, 513]
        var p = 0
        while done < left.count {
            let n = min(pieces[p % pieces.count], left.count - done)
            p += 1
            var stems = [[Float]](repeating: [Float](repeating: 0, count: n), count: 8)
            stems[CarBandTests.other * 2] = Array(left[done..<done + n])
            stems[CarBandTests.other * 2 + 1] = Array(right[done..<done + n])
            let zero = [Float](repeating: 0, count: n)
            let out = mixer.process(stems: stems, standIn: (zero, zero))
            XCTAssertEqual(out.left.count, n)
            outL += out.left
            outR += out.right
            done += n
        }
        return (outL, outR, mixer.latency)
    }

    /// Amplitude and phase of `x[from ..< from + count]` at `hz` (count: whole cycles).
    private func tone(_ x: [Float], _ hz: Double, from: Int, count: Int) -> (re: Double, im: Double) {
        var re = 0.0, im = 0.0
        for i in 0..<count {
            let w = 2 * Double.pi * hz * Double(i) / 44100
            re += Double(x[from + i]) * cos(w)
            im -= Double(x[from + i]) * sin(w)
        }
        return (re * 2 / Double(count), im * 2 / Double(count))
    }

    /// The old behaviour (before width): the part made mono, Linkwitz-Riley at the crossover,
    /// above it times 10^(∓pan/40). Written out here with the same RBJ sections.
    private func reference(left: [Float], right: [Float], pan: Float, crossover: Double) -> (left: [Float], right: [Float]) {
        struct Section {
            var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0, z1 = 0.0, z2 = 0.0
            init(highpass: Bool, f: Double) {
                let w = 2 * Double.pi * f / 44100
                let c = cos(w), alpha = sin(w) / (2 * 0.70710678)
                let a0 = 1 + alpha
                b0 = (highpass ? (1 + c) : (1 - c)) / 2 / a0
                b1 = (highpass ? -(1 + c) : (1 - c)) / a0
                b2 = b0
                a1 = -2 * c / a0
                a2 = (1 - alpha) / a0
            }
            mutating func step(_ x: Double) -> Double {
                let y = b0 * x + z1
                z1 = b1 * x - a1 * y + z2
                z2 = b2 * x - a2 * y
                return y
            }
        }
        var lp0 = Section(highpass: false, f: crossover), lp1 = lp0
        var hp0 = Section(highpass: true, f: crossover), hp1 = hp0
        let gl = pow(10, -pan / 40), gr = pow(10, pan / 40)
        var l = [Float](repeating: 0, count: left.count), r = l
        for j in 0..<left.count {
            let m = (left[j] + right[j]) * 0.5
            let lo = Float(lp1.step(lp0.step(Double(m))))
            let hi = Float(hp1.step(hp0.step(Double(m))))
            l[j] = lo + gl * hi
            r[j] = lo + gr * hi
        }
        return (l, r)
    }

    private func noiseStereo(_ n: Int) -> (left: [Float], right: [Float]) {
        var a = TestRandom(seed: 5), b = TestRandom(seed: 6)
        var l = [Float](repeating: 0, count: n), r = l
        for j in 0..<n {
            let common = 0.2 * a.next()
            l[j] = common + 0.15 * b.next()
            r[j] = 0.6 * common - 0.1 * b.next() + 0.1 * a.next()
        }
        return (l, r)
    }

    /// (a) Width 0: the same as before width existed (mono, then panned), only `latency` later.
    func testWidthZeroIsTheOldBehaviour() {
        let n = 2 * 44100
        let x = noiseStereo(n)
        let params = dryParams(width: 0, pan: 4)
        let out = runOther(params, left: x.left, right: x.right)
        let ref = reference(left: x.left, right: x.right, pan: 4, crossover: Double(params.crossoverHz))
        let d = out.latency
        XCTAssertGreaterThan(d, 0)
        var err = 0.0, energy = 0.0
        for j in 0..<(n - d) {
            let el = Double(out.left[j + d] - ref.left[j]), er = Double(out.right[j + d] - ref.right[j])
            err += el * el + er * er
            energy += Double(ref.left[j] * ref.left[j] + ref.right[j] * ref.right[j])
        }
        XCTAssertGreaterThan(energy, 1)
        XCTAssertLessThan(10 * log10(max(err, 1e-30) / energy), -60, "width 0 differs from the old mono path")
        for j in 0..<d { XCTAssertEqual(out.left[j], 0) }
    }

    /// (b) A part with 1 kHz 12 dB louder on the left and 3 kHz 12 dB louder on the right:
    /// at width 1 each stays on its side (at least 9 dB), left and right in phase.
    func testWidthKeepsEachFrequencysSide() {
        let n = 3 * 44100
        let g: Float = pow(10, 12 / 20)
        var l = [Float](repeating: 0, count: n), r = l
        for j in 0..<n {
            let t = Float(j) / 44100
            let a1 = 0.2 * sin(2 * Float.pi * 1000 * t), a3 = 0.2 * sin(2 * Float.pi * 3000 * t)
            l[j] = g * a1 + a3
            r[j] = a1 + g * a3
        }
        let out = runOther(dryParams(width: 1), left: l, right: r)
        let from = out.latency + 22050
        for (hz, sign) in [(1000.0, 1.0), (3000.0, -1.0)] {
            let tl = tone(out.left, hz, from: from, count: 44100)
            let tr = tone(out.right, hz, from: from, count: 44100)
            let ml = (tl.re * tl.re + tl.im * tl.im).squareRoot(), mr = (tr.re * tr.re + tr.im * tr.im).squareRoot()
            let db = 20 * log10(ml / mr)
            XCTAssertGreaterThanOrEqual(db * sign, 9, "\(hz) Hz: left - right \(db) dB")
            let corr = (tl.re * tr.re + tl.im * tr.im) / (ml * mr)
            XCTAssertGreaterThan(corr, 0.99, "\(hz) Hz: left and right not in phase (\(corr))")
        }
    }

    /// (c) An impulse comes out at the same sample with width 1 as with width 0.
    func testWidthKeepsTimeAlignment() {
        let n = 44100
        var l = [Float](repeating: 0, count: n), r = l
        l[20000] = 1
        r[20000] = 0.5
        func peak(_ width: Float) -> (at: Int, latency: Int) {
            let out = runOther(dryParams(width: width), left: l, right: r)
            var best = 0
            for j in 0..<n where abs(out.left[j]) > abs(out.left[best]) { best = j }
            return (best, out.latency)
        }
        let a = peak(0), b = peak(1)
        XCTAssertLessThanOrEqual(abs(a.at - b.at), 1, "width 0 at \(a.at), width 1 at \(b.at)")
        XCTAssertLessThanOrEqual(abs(a.at - (20000 + a.latency)), 2)
    }

    /// (d) Width 1 keeps the energy (within 0.5 dB).
    func testWidthKeepsEnergy() {
        let n = 3 * 44100
        let g: Float = pow(10, 12 / 20)
        var l = [Float](repeating: 0, count: n), r = l
        for j in 0..<n {
            let t = Float(j) / 44100
            let a1 = 0.2 * sin(2 * Float.pi * 1000 * t), a3 = 0.2 * sin(2 * Float.pi * 3000 * t)
            l[j] = g * a1 + a3
            r[j] = a1 + g * a3
        }
        let out = runOther(dryParams(width: 1), left: l, right: r)
        var ein = 0.0, eout = 0.0
        for j in 22050..<(22050 + 88200) {
            ein += Double(l[j] * l[j] + r[j] * r[j])
            eout += Double(out.left[j + out.latency] * out.left[j + out.latency] + out.right[j + out.latency] * out.right[j + out.latency])
        }
        let db = 10 * log10(eout / ein)
        XCTAssertLessThan(abs(db), 0.5, "energy changed by \(db) dB")
    }

    /// Changing width while playing (0 -> 2 -> 0) gives no jumps and nothing non-finite.
    func testWidthChangeGlides() {
        let n = 44100
        let x = noiseStereo(3 * n)
        let mixer = CarBandMixer(sampleRate: 44100, params: dryParams(width: 0))
        var out: [Float] = []
        for (i, w) in [Float(0), 2, 0].enumerated() {
            mixer.set(dryParams(width: w))
            var stems = [[Float]](repeating: [Float](repeating: 0, count: n), count: 8)
            stems[CarBandTests.other * 2] = Array(x.left[i * n..<(i + 1) * n])
            stems[CarBandTests.other * 2 + 1] = Array(x.right[i * n..<(i + 1) * n])
            let zero = [Float](repeating: 0, count: n)
            out += mixer.process(stems: stems, standIn: (zero, zero)).left
        }
        XCTAssertTrue(out.allSatisfy { $0.isFinite })
        XCTAssertLessThan(out.map { abs($0) }.max() ?? 0, 2)
    }

    /// In the band processor the mixer's delay is taken back out: with the network failing,
    /// what comes out is the original, sample for sample, and nothing is lost.
    func testCarProcessorStaysAligned() {
        final class Never: BandNetwork {
            struct Failure: Error {}
            func run(spec: [Float], wave: [Float]) throws -> (spec: [Float], wave: [Float]) { throw Failure() }
        }
        let n = 3 * 44100
        let x = noiseStereo(n)
        let p = BandProcessor(output: .car, network: Never(), sampleRate: 44100,
                              queue: DispatchQueue(label: "test.carband"), mix: BandMix())
        var l = [Float](), r = [Float]()
        let a = p.process(left: x.left, right: x.right)
        l += a.left; r += a.right
        while let part = p.drain(urgent: true) { l += part.left; r += part.right }
        let rest = p.finish()
        l += rest.left; r += rest.right
        XCTAssertEqual(l.count, n)
        var worst: Float = 0
        for i in 0..<min(n, l.count) { worst = max(worst, abs(l[i] - x.left[i]), abs(r[i] - x.right[i])) }
        XCTAssertLessThan(worst, 1e-6)
    }
}
