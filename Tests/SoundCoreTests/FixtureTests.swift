import XCTest
import SoundCore

/// Checks against results computed on the PC with ffmpeg (see Tests/tools/make-fixtures.js).
final class FixtureTests: XCTestCase {
    private func signal() throws -> (left: [Float], right: [Float]) {
        let s = TestSignal.make()
        /* The same samples ffmpeg was given? Everything below depends on it. */
        let stored = (try Fixtures.info()["checksum"] as? NSNumber)?.uint32Value
        XCTAssertEqual(TestSignal.checksum(s), 4017779941)
        XCTAssertEqual(stored, 4017779941)
        return (TestSignal.floats(s.left), TestSignal.floats(s.right))
    }

    /// Our surround equals the PC server's ffmpeg graph (aresample 48000, pan, 2 x afir, amix)
    /// on six seconds of sound, entirely at 48 kHz so that no resampler is involved.
    func testSurroundEqualsFfmpeg() throws {
        let s = try signal()
        let irL = try WavFile(data: Fixtures.data("irL.wav"))
        let irR = try WavFile(data: Fixtures.data("irR.wav"))
        XCTAssertEqual(irL.sampleRate, 48000)
        XCTAssertEqual(irL.channels.count, 2)
        XCTAssertEqual(irR.channels.count, 2)

        let c = TrueStereoConvolver(irLeft: irL.channels, irRight: irR.channels)
        var outL: [Float] = [], outR: [Float] = []
        var at = 0
        while at < s.left.count {
            let n = min(10000, s.left.count - at)
            let out = c.process(left: Array(s.left[at..<(at + n)]), right: Array(s.right[at..<(at + n)]))
            outL.append(contentsOf: out.left)
            outR.append(contentsOf: out.right)
            at += n
        }
        let rest = c.flush()
        outL.append(contentsOf: rest.left)
        outR.append(contentsOf: rest.right)
        XCTAssertEqual(outL.count, TestSignal.frames)

        let info = try Fixtures.info()
        let scale = (info["surroundScale"] as? NSNumber)?.doubleValue ?? 0
        XCTAssertGreaterThan(scale, 0)
        let raw = try Fixtures.data("expected-surround.s16")
        let frames = min(raw.count / 4, outL.count)
        XCTAssertEqual(frames, TestSignal.frames)
        var errorPower = 0.0, power = 0.0
        raw.withUnsafeBytes { bytes in
            for n in 0..<frames {
                let wl = Double(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: n * 4, as: Int16.self))) / scale
                let wr = Double(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: n * 4 + 2, as: Int16.self))) / scale
                let dl = Double(outL[n]) - wl, dr = Double(outR[n]) - wr
                errorPower += dl * dl + dr * dr
                power += wl * wl + wr * wr
            }
        }
        let relative = 10 * log10(errorPower / power)
        print("RESULT surround vs ffmpeg: relative error \(String(format: "%.1f", relative)) dB")
        XCTAssertLessThan(relative, -60)
    }

    /// Strength of a filter at one frequency, in dB.
    private func level(_ h: [Float], rate: Double, at f: Double) -> Double {
        var re = 0.0, im = 0.0
        for n in 0..<h.count {
            let a = -2 * Double.pi * f * Double(n) / rate
            re += Double(h[n]) * cos(a)
            im += Double(h[n]) * sin(a)
        }
        return 20 * log10((re * re + im * im).squareRoot())
    }

    /// An impulse response brought from 48 kHz to 44.1 kHz must filter exactly as before.
    /// This pins down the scale factor (source rate / target rate = 1.088): without it every
    /// frequency would come out 0.74 dB too quiet, with its inverse 1.47 dB.
    func testImpulseResponseKeepsItsFrequencyResponseAt44100() throws {
        let ir = try WavFile(data: Fixtures.data("irL.wav"))
        for channel in ir.channels {
            let moved = Resampler.convertImpulseResponse(channel, from: 48000, to: 44100)
            XCTAssertEqual(Double(moved.count), Double(channel.count) * 44100 / 48000, accuracy: 2)
            for f in [100.0, 1000, 5000, 10000, 15000, 17500] {
                let difference = level(moved, rate: 44100, at: f) - level(channel, rate: 48000, at: f)
                XCTAssertEqual(difference, 0, accuracy: 0.3, "at \(f) Hz")
            }
        }
        let plain = Resampler.convert(ir.channels[0], from: 48000, to: 44100, filterSize: 64, cutoff: 0.96)
        let unscaled = level(plain, rate: 44100, at: 1000) - level(ir.channels[0], rate: 48000, at: 1000)
        XCTAssertEqual(unscaled, 20 * log10(44100.0 / 48000.0), accuracy: 0.05, "without the factor the level is wrong by exactly the rate ratio")
    }

    private func sine(_ frequency: Double, peakDb: Double, rate: Double, seconds: Double) -> [Float] {
        let amplitude = pow(10, peakDb / 20)
        return (0..<Int(rate * seconds)).map { Float(amplitude * sin(2 * Double.pi * frequency * Double($0) / rate)) }
    }

    private func loudness(_ l: [Float], _ r: [Float], rate: Double, piece: Int = 4096) -> Double? {
        let meter = LoudnessMeter(sampleRate: rate)
        var at = 0
        while at < l.count {
            let n = min(piece, l.count - at)
            meter.add(left: Array(l[at..<(at + n)]), right: Array(r[at..<(at + n)]))
            at += n
        }
        return meter.integrated()
    }

    /// Reference: EBU Tech 3341, test signal 1 - a 1000 Hz stereo sine with a peak level of
    /// −23.0 dBFS in each channel must read −23.0 ± 0.1 LUFS. (Same thing as ITU-R BS.1770:
    /// a 997 Hz full-scale sine in one channel reads −3.01 LKFS.) So a −20 dBFS-peak stereo
    /// sine reads −20.0, not −23.
    func testSineReadsItsPeakLevel() throws {
        for rate in [48000.0, 44100.0] {
            let a = sine(1000, peakDb: -23, rate: rate, seconds: 5)
            XCTAssertEqual(try XCTUnwrap(loudness(a, a, rate: rate)), -23.0, accuracy: 0.1, "rate \(rate)")
            let b = sine(1000, peakDb: -20, rate: rate, seconds: 5)
            XCTAssertEqual(try XCTUnwrap(loudness(b, b, rate: rate)), -20.0, accuracy: 0.1, "rate \(rate)")
            /* One channel only: half the power, 3.01 LU less. */
            let silent = [Float](repeating: 0, count: b.count)
            XCTAssertEqual(try XCTUnwrap(loudness(b, silent, rate: rate)), -23.01, accuracy: 0.1, "rate \(rate)")
        }
    }

    func testSilenceAndShortInputHaveNoLoudness() {
        XCTAssertNil(loudness([Float](repeating: 0, count: 48000), [Float](repeating: 0, count: 48000), rate: 48000))
        XCTAssertNil(loudness([0.5, 0.5], [0.5, 0.5], rate: 48000))
    }

    /// Second, independent check: ffmpeg's meter on the six-second test signal.
    ///   ffmpeg -i signal.wav -af ebur128=framelog=quiet -f null -      ->  I: -9.5 LUFS
    /// (ffmpeg 8.1; signal.wav is the test signal as 16-bit 48 kHz stereo.)
    func testLoudnessEqualsFfmpegOnTheTestSignal() throws {
        let s = try signal()
        let ours = try XCTUnwrap(loudness(s.left, s.right, rate: 48000, piece: 1777))
        print("RESULT loudness of the test signal: \(String(format: "%.2f", ours)) LUFS (ffmpeg: -9.5)")
        XCTAssertEqual(ours, -9.5, accuracy: 0.3)
        let stored = (try Fixtures.info()["lufs"] as? NSNumber)?.doubleValue
        XCTAssertEqual(stored, -9.5)
    }

    /// The envelope bytes equal the ones made the PC server's way (ffmpeg to 11025 Hz mono,
    /// then the arithmetic of ensureEnv in server.js), give or take one.
    func testEnvelopeEqualsThePcServers() throws {
        let s = try signal()
        let mono = zip(s.left, s.right).map { ($0 + $1) / 2 }
        let maker = EnvelopeMaker(sampleRate: 48000)
        var at = 0
        while at < mono.count {
            let n = min(5000, mono.count - at)
            maker.add(mono: Array(mono[at..<(at + n)]))
            at += n
        }
        let got = [UInt8](maker.finish())
        let want = [UInt8](try Fixtures.data("expected-env.bin"))
        XCTAssertEqual(got.count, want.count)
        XCTAssertEqual(want.count, 360)
        var worst = 0
        for i in 0..<min(got.count, want.count) { worst = max(worst, abs(Int(got[i]) - Int(want[i]))) }
        print("RESULT envelope: largest difference \(worst) of 255")
        XCTAssertLessThanOrEqual(worst, 1)
        XCTAssertGreaterThan(want.max() ?? 0, 60, "the fixture must not be all zeros")
    }

    func testResamplerInPiecesEqualsInOneGo() {
        var random = TestRandom(seed: 5)
        let x = (0..<20000).map { _ in random.next() }
        let whole = Resampler.convert(x, from: 44100, to: 11025)
        let r = Resampler(from: 44100, to: 11025)
        var pieces: [Float] = []
        var at = 0
        for n in [1, 999, 4096, 3, 14901] {
            pieces.append(contentsOf: r.process(Array(x[at..<(at + n)])))
            at += n
        }
        pieces.append(contentsOf: r.finish())
        XCTAssertEqual(whole.count, 5000)
        XCTAssertEqual(pieces.count, whole.count)
        for i in 0..<min(pieces.count, whole.count) {
            XCTAssertEqual(pieces[i], whole[i], accuracy: 1e-5)
        }
    }

    /// How fast the surround runs: seconds of 44.1 kHz stereo sound per second of computing,
    /// with the real impulse responses (brought to 44.1 kHz) and the block size the app uses.
    func testConvolverThroughput() throws {
        let settings = SurroundSettings(key: "t", surround: true, irLeft: try Fixtures.data("irL.wav"),
                                        irRight: try Fixtures.data("irR.wav"), makeup: 0.7)
        let chain = SurroundChain(settings: settings, sampleRate: 44100)
        XCTAssertNil(chain.problem)
        var random = TestRandom(seed: 9)
        let piece = (0..<8192).map { _ in random.next() * 0.3 }
        let seconds = 60.0
        let rounds = Int(seconds * 44100 / 8192)
        var frames = 0
        let start = Date()
        for _ in 0..<rounds { frames += chain.process(left: piece, right: piece).left.count }
        let took = Date().timeIntervalSince(start)
        let speed = Double(frames) / 44100 / took
        print("RESULT convolver throughput: \(String(format: "%.0f", speed)) s of 44.1 kHz stereo audio per second (\(String(format: "%.3f", took)) s for \(String(format: "%.1f", Double(frames) / 44100)) s)")
        XCTAssertGreaterThan(speed, 10)
    }
}
