import XCTest
@testable import SoundCore

/// The made-up song of Tests/tools/make-mixanalysis-expected.js, and what the PC's own analysis
/// (analysePcm in the old server code) said about it:
/// {"bpm":119.98,"beat0":0.098,"conf":33.14,"dur":70,"introStart":3,"soundStart":3,
///  "bodyStart":8,"bodyEnd":65,"outroStart":67.5,"quietStart":69.5,"tailEnd":70}
final class MixAnalyzerTests: XCTestCase {
    private func value(at t: Double) -> Double {
        var v = 0.0
        if t >= 3 && t < 8 { v = 0.02 * sin(2 * Double.pi * 220 * t) }
        if t >= 8 {
            var amp = 1.0
            if t >= 60 { amp = max(0, 1 - (t - 60) / 10) }
            let since = fmod(t - 8.1, 0.5)
            let kick = t >= 8.1 ? 0.8 * sin(2 * Double.pi * 60 * since) * exp(-since * 20) : 0
            v = amp * (kick + 0.15 * sin(2 * Double.pi * 330 * t))
        }
        return v
    }

    private func song(rate: Int) -> [Float] {
        return (0..<(70 * rate)).map { Float(value(at: Double($0) / Double(rate))) }
    }

    func testSameAnswerAsThePcOnTheSamePcm() throws {
        let rate = 11025
        let pcm: [Int16] = (0..<(70 * rate)).map {
            let v = (value(at: Double($0) / Double(rate)) * 32767).rounded(.towardZero)
            return Int16(max(-32768, min(32767, v)))
        }
        let a = try XCTUnwrap(MixAnalyzer.analyze(pcm))
        XCTAssertEqual(a.bpm ?? 0, 119.98, accuracy: 0.1)
        XCTAssertEqual(a.beat0 ?? -1, 0.098, accuracy: 0.03)
        XCTAssertEqual(a.conf ?? 0, 33.14, accuracy: 6)
        XCTAssertEqual(a.dur ?? 0, 70, accuracy: 0.01)
        XCTAssertEqual(a.soundStart ?? -1, 3, accuracy: 0.6)
        XCTAssertEqual(a.bodyStart ?? -1, 8, accuracy: 0.6)
        XCTAssertEqual(a.bodyEnd ?? -1, 65, accuracy: 0.6)
        XCTAssertEqual(a.outroStart ?? -1, 67.5, accuracy: 0.6)
        XCTAssertEqual(a.quietStart ?? -1, 69.5, accuracy: 0.6)
        XCTAssertEqual(a.tailEnd ?? -1, 70, accuracy: 0.6)
    }

    func testFromStereoAt44100() throws {
        let mono = song(rate: 44100)
        var maker = Mono11k(sampleRate: 44100)
        var i = 0
        while i < mono.count {
            let end = min(mono.count, i + 4096)
            let piece = Array(mono[i..<end])
            maker.add(left: piece, right: piece)
            i = end
        }
        XCTAssertEqual(Double(maker.samples.count), 70 * 11025, accuracy: 4)
        let a = try XCTUnwrap(MixAnalyzer.analyze(maker.samples))
        XCTAssertEqual(a.bpm ?? 0, 119.98, accuracy: 0.3)
        XCTAssertEqual(a.beat0 ?? -1, 0.098, accuracy: 0.05)
        XCTAssertEqual(a.bodyStart ?? -1, 8, accuracy: 0.6)
        XCTAssertEqual(a.bodyEnd ?? -1, 65, accuracy: 0.6)
    }

    func testOddSampleRateKeepsTheLength() {
        var maker = Mono11k(sampleRate: 48000)
        let steady = [Float](repeating: 0.5, count: 48000)
        maker.add(left: steady, right: steady)
        XCTAssertEqual(Double(maker.samples.count), 11025, accuracy: 2)
        XCTAssertEqual(Double(maker.samples[100]), 16384, accuracy: 4)
    }

    func testShortSongGivesNothing() {
        XCTAssertNil(MixAnalyzer.analyze([Int16](repeating: 100, count: 11025 * 10)))
    }
}
