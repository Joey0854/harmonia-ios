import XCTest
@testable import SoundCore

final class ListenCounterTests: XCTestCase {
    private func play(_ c: inout ListenCounter, id: String, from: Double, seconds: Double, dur: Double = 200) -> Int {
        var counted = 0
        var t = from
        let end = from + seconds
        while t < end {
            if c.feed(id: id, position: t, playing: true, duration: dur) { counted += 1 }
            t += 0.25
        }
        return counted
    }

    func testCountsAfterThirtySeconds() {
        var c = ListenCounter()
        XCTAssertEqual(play(&c, id: "a", from: 0, seconds: 25), 0)
        XCTAssertEqual(play(&c, id: "a", from: 25, seconds: 10), 1)
        XCTAssertEqual(play(&c, id: "a", from: 35, seconds: 60), 0)
    }

    func testShortSongCountsAtHalf() {
        var c = ListenCounter()
        XCTAssertEqual(play(&c, id: "a", from: 0, seconds: 25, dur: 40), 1)
    }

    func testSeekingIsNotListening() {
        var c = ListenCounter()
        var counted = 0
        var t = 0.0
        for _ in 0..<20 {
            t += 20
            if c.feed(id: "a", position: t, playing: true, duration: 600) { counted += 1 }
        }
        XCTAssertEqual(counted, 0)
    }

    func testPausedTimeIsNotCounted() {
        var c = ListenCounter()
        for _ in 0..<400 { _ = c.feed(id: "a", position: 10, playing: false, duration: 200) }
        XCTAssertEqual(play(&c, id: "a", from: 10, seconds: 20), 0)
    }

    func testAnotherSongStartsOver() {
        var c = ListenCounter()
        XCTAssertEqual(play(&c, id: "a", from: 0, seconds: 20), 0)
        XCTAssertEqual(play(&c, id: "b", from: 0, seconds: 20), 0)
        XCTAssertEqual(play(&c, id: "b", from: 20, seconds: 15), 1)
    }

    func testPlayedAgainCountsAgain() {
        var c = ListenCounter()
        XCTAssertEqual(play(&c, id: "a", from: 0, seconds: 35), 1)
        XCTAssertEqual(play(&c, id: "a", from: 0, seconds: 35), 1)
    }
}
