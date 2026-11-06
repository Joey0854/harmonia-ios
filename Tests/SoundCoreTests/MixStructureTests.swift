import XCTest
@testable import SoundCore

final class MixStructureTests: XCTestCase {
    /// levels (rms) from a list of (seconds, decibels), a tenth of a second each
    private func track(_ parts: [(Double, Double)]) -> [Float] {
        var out: [Float] = []
        for (seconds, db) in parts {
            for _ in 0..<Int(seconds * 10) { out.append(Float(pow(10, db / 20))) }
        }
        return out
    }

    func testFindsTheParts() throws {
        // 2 s of near silence, 8 s soft, 90 s loud, a 10 s fade, then silence
        var parts: [(Double, Double)] = [(2, -90), (8, -34), (90, -10)]
        for k in 0..<10 { parts.append((1, -10 - Double(k) * 5.5)) }
        parts.append((3, -90))
        let a = try XCTUnwrap(MixStructure.analyze(levels: track(parts)))
        XCTAssertEqual(a.soundStart ?? -1, 2, accuracy: 1)
        XCTAssertEqual(a.bodyStart ?? -1, 10, accuracy: 1.5)
        XCTAssertEqual(a.bodyEnd ?? -1, 101, accuracy: 2)
        XCTAssertEqual(a.tailEnd ?? -1, 109, accuracy: 2.5)
        XCTAssertGreaterThanOrEqual(a.quietStart ?? 0, a.bodyEnd ?? 999)
        XCTAssertLessThanOrEqual(a.quietStart ?? 999, a.tailEnd ?? 0)
    }

    func testSongThatStaysLoudToTheEnd() throws {
        let a = try XCTUnwrap(MixStructure.analyze(levels: track([(1, -90), (179, -9)])))
        XCTAssertEqual(a.bodyEnd ?? -1, 180, accuracy: 1)
        XCTAssertEqual(a.tailEnd ?? -1, 180, accuracy: 1)
        XCTAssertEqual(a.dur ?? -1, 180, accuracy: 0.2)
    }

    func testSilenceAndShortThingsGiveNothing() {
        XCTAssertNil(MixStructure.analyze(levels: track([(60, -100)])))
        XCTAssertNil(MixStructure.analyze(levels: track([(0.5, -10)])))
    }

    func testPlannerAcceptsTheResult() throws {
        let a = try XCTUnwrap(MixStructure.analyze(levels: track([(1, -90), (179, -9)])))
        let b = try XCTUnwrap(MixStructure.analyze(levels: track([(2, -40), (178, -9)])))
        let d = MixPlanner.plan(a: a, b: b, durationA: 180, availableB: 180, mixOn: true)
        guard case .plan(let p) = d else { return XCTFail("no plan: \(d)") }
        XCTAssertFalse(p.synced)
        XCTAssertEqual(p.end, 180, accuracy: 1)
        XCTAssertGreaterThan(p.startA, 90)
    }

    func testCounterMakesTenthSecondFrames() {
        var t = LevelTrack(sampleRate: 1000)
        let ones = [Float](repeating: 1, count: 1000)
        t.add(left: ones, right: ones)
        let levels = t.finish()
        XCTAssertEqual(levels.count, 10)
        XCTAssertEqual(levels[0], 1, accuracy: 0.001)
    }
}
