import XCTest
import SoundCore

final class PlaybackReportTests: XCTestCase {
    func testSongChangeFromThePageIsInvisible() {
        var r = PlaybackReport()
        XCTAssertEqual(r.want(true, source: .page, now: 0), true)
        /* the page: pause, load, play */
        XCTAssertNil(r.want(false, source: .page, now: 10))
        XCTAssertNil(r.want(true, source: .page, now: 10.02))
        XCTAssertNil(r.resolve(now: 12))
        XCTAssertTrue(r.playing)
        /* a quick pause / play from the page button within the grace */
        XCTAssertNil(r.want(false, source: .page, now: 20))
        XCTAssertNil(r.want(true, source: .page, now: 21.2))
        XCTAssertNil(r.resolve(now: 21.5))
        XCTAssertTrue(r.playing)
    }

    func testARealPageHoldIsReportedAfterTheGrace() {
        var r = PlaybackReport()
        _ = r.want(true, source: .page, now: 0)
        XCTAssertNil(r.want(false, source: .page, now: 5))
        XCTAssertNil(r.want(false, source: .page, now: 6), "a second pause does not push it back")
        XCTAssertNil(r.resolve(now: 6.4))
        XCTAssertEqual(r.resolve(now: 6.5), false)
        XCTAssertFalse(r.playing)
        XCTAssertNil(r.resolve(now: 9))
        XCTAssertEqual(r.want(true, source: .page, now: 10), true)
    }

    func testImmediatePauseAndRepeats() {
        var r = PlaybackReport()
        XCTAssertNil(r.want(false, source: .immediate, now: 0), "already paused")
        XCTAssertEqual(r.want(true, source: .immediate, now: 1), true)
        XCTAssertNil(r.want(true, source: .page, now: 2), "already playing")
        XCTAssertNil(r.want(false, source: .page, now: 3))
        XCTAssertEqual(r.want(false, source: .immediate, now: 3.2), false, "CarPlay pause is not held")
        XCTAssertNil(r.pendingPauseAt)
        XCTAssertNil(r.resolve(now: 10))
    }
}
