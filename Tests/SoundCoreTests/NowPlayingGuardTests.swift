import XCTest
import SoundCore

/// The lock screen describes the song being heard, also after the app moved on by itself.
final class NowPlayingGuardTests: XCTestCase {
    let old = NowPlayingMeta(title: "Old song", artist: "Old artist", artwork: "https://x/old.jpg", duration: 201)
    let new = NowPlayingMeta(title: "New song", artist: "New artist", artwork: "https://x/new.jpg", duration: 187)

    func testAfterAMixHandOverThePagesOldDescriptionIsDropped() {
        var g = NowPlayingGuard()
        g.advancedBySelf(from: old, now: 100)
        /* the page's "playing" handler still describes its old song */
        XCTAssertFalse(g.acceptMeta(old, id: nil, current: "new", now: 100.2))
        XCTAssertFalse(g.acceptDuration(201, id: nil, current: "new", now: 100.2))
        /* once it describes the new song, everything goes through again */
        XCTAssertTrue(g.acceptMeta(new, id: nil, current: "new", now: 101))
        XCTAssertTrue(g.acceptMeta(NowPlayingMeta(title: "New song", artist: "New artist", artwork: "https://x/hd.jpg", duration: 187),
                                   id: nil, current: "new", now: 102), "late artwork for the new song")
        XCTAssertTrue(g.acceptDuration(201, id: nil, current: "new", now: 102))
    }

    func testNaturalEndWithoutAMixBehavesTheSame() {
        var g = NowPlayingGuard()
        g.advancedBySelf(from: old, now: 50)
        XCTAssertFalse(g.acceptMeta(old, id: nil, current: "b", now: 50.05))
        XCTAssertTrue(g.acceptDuration(187, id: nil, current: "b", now: 50.05), "the new song's own length")
    }

    func testTheGuardEndsAfterItsWindow() {
        var g = NowPlayingGuard()
        g.advancedBySelf(from: old, now: 0)
        XCTAssertTrue(g.acceptMeta(old, id: nil, current: "b", now: NowPlayingGuard.window + 0.1))
    }

    func testAPageChoiceIsAlwaysBelieved() {
        var g = NowPlayingGuard()
        g.advancedBySelf(from: old, now: 0)
        g.pageChose()   // the user went back to the old song
        XCTAssertTrue(g.acceptMeta(old, id: nil, current: "a", now: 1))
        XCTAssertTrue(g.acceptMeta(old, id: nil, current: "a", now: 1), "no guard without a change by the app")
    }

    func testMessagesWithAnIdCountOnlyForTheSongBeingHeard() {
        var g = NowPlayingGuard()
        XCTAssertFalse(g.acceptMeta(new, id: "a", current: "b", now: 0))
        XCTAssertTrue(g.acceptMeta(new, id: "b", current: "b", now: 0))
        XCTAssertFalse(g.acceptDuration(187, id: "a", current: "b", now: 0))
        g.advancedBySelf(from: old, now: 0)
        XCTAssertTrue(g.acceptMeta(old, id: "b", current: "b", now: 0.1), "the id decides")
    }

    func testADescriptionOfTheNextSongIsKeptUntilItPlays() {
        var g = NowPlayingGuard()
        /* the page chose "b" and describes it before asking for it; "a" still plays */
        XCTAssertFalse(g.acceptMeta(new, id: "b", current: "a", now: 0))
        g.hold(new, id: "b")
        XCTAssertNil(g.takeHeld(for: "a"))
        XCTAssertNil(g.takeHeld(for: nil))
        XCTAssertEqual(g.takeHeld(for: "b"), new)
        XCTAssertNil(g.takeHeld(for: "b"), "used once")
    }
}
