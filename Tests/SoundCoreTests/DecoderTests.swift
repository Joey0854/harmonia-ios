import AVFoundation
import XCTest
import SoundCore

/// Does the system decoder read the kind of file YouTube delivers? `song-fragmented.m4a` is the
/// test signal as AAC in a fragmented MP4 laid out like those files (ftyp "dash", a segment
/// index, one-second fragments, and the full length already written in the movie header);
/// `song-plain.m4a` is the same sound as an ordinary file.
///
/// These run on macOS, which shares this decoder with iOS. They are the nearest thing to a
/// phone that the build machine has.
final class DecoderTests: XCTestCase {
    private func decodeAll(_ name: String, startAt: Double = 0) throws -> (left: [Float], right: [Float], decoder: SongDecoder) {
        let d = try SongDecoder(url: Fixtures.url(name), startAt: startAt)
        var l: [Float] = [], r: [Float] = []
        while let piece = try d.next() {
            XCTAssertEqual(piece.left.count, piece.right.count)
            l.append(contentsOf: piece.left)
            r.append(contentsOf: piece.right)
        }
        return (l, r, d)
    }

    private func power(_ x: [Float], rate: Double, from: Double, to: Double, offset: Double = 0) -> Double {
        let a = max(0, Int((from - offset) * rate)), b = min(x.count, Int((to - offset) * rate))
        if b <= a { return 0 }
        var sum = 0.0
        for i in a..<b { sum += Double(x[i]) * Double(x[i]) }
        return sum / Double(b - a)
    }

    private func check(_ name: String) throws {
        let all = try decodeAll(name)
        let d = all.decoder
        print("RESULT decode \(name): \(all.left.count) frames at \(d.sampleRate) Hz, \(d.channelCount) channels, stated length \(String(format: "%.3f", d.statedDuration)) s, first sample at \(String(format: "%.4f", d.startTime)) s")
        XCTAssertEqual(d.sampleRate, 44100)
        XCTAssertEqual(d.channelCount, 2)
        XCTAssertEqual(d.framesRead, all.left.count)
        /* Six seconds, give or take the encoder's padding. */
        XCTAssertEqual(Double(all.left.count), 6 * 44100, accuracy: 5000, "the whole song must come out, not just its first fragment")
        /* The stated length is the real one (AVFoundation alone said 11.975 s for the fragmented file). */
        XCTAssertEqual(d.statedDuration, Double(all.left.count) / 44100, accuracy: 0.1, "stated length")
        /* The right sound at the right time: loud at 1.0 - 1.4 s, silent at 4.2 - 4.6 s, loud again after. */
        XCTAssertGreaterThan(power(all.left, rate: 44100, from: 1.0, to: 1.4), 1e-3)
        XCTAssertLessThan(power(all.left, rate: 44100, from: 4.2, to: 4.6), 1e-5)
        XCTAssertGreaterThan(power(all.right, rate: 44100, from: 5.3, to: 5.8), 1e-4)
        XCTAssertNotEqual(all.left[40000], all.right[40000], "left and right are different signals")
    }

    func testPlainFile() throws {
        try check("song-plain.m4a")
    }

    func testFragmentedFileLikeYouTubes() throws {
        try check("song-fragmented.m4a")
    }

    private func checkSeek(_ name: String) throws {
        let part = try decodeAll(name, startAt: 3.0)
        let d = part.decoder
        print("RESULT seek \(name) to 3.0: first sample at \(String(format: "%.4f", d.startTime)) s, \(part.left.count) frames")
        XCTAssertEqual(d.startTime, 3.0, accuracy: 0.1)
        XCTAssertEqual(Double(part.left.count) / 44100 + d.startTime, 6.0, accuracy: 0.15)
        /* Still the right sound at the right time when counted from where the decoder says it started. */
        XCTAssertLessThan(power(part.left, rate: 44100, from: 4.2, to: 4.6, offset: d.startTime), 1e-5)
        XCTAssertGreaterThan(power(part.left, rate: 44100, from: 3.2, to: 3.6, offset: d.startTime), 1e-3)
    }

    func testSeekInPlainFile() throws {
        try checkSeek("song-plain.m4a")
    }

    func testSeekInFragmentedFile() throws {
        try checkSeek("song-fragmented.m4a")
    }

    /// Decodes with the reader killed after the second and the fifth piece (as the system does
    /// to a reader that is open when the app is suspended).
    private func decodeWithBreaks(_ name: String, startAt: Double, exact: Bool) throws -> (left: [Float], right: [Float], decoder: SongDecoder, messages: [String]) {
        let d = try SongDecoder(url: Fixtures.url(name), startAt: startAt, exact: exact)
        var messages: [String] = []
        d.onReopen = { messages.append($0) }
        var l: [Float] = [], r: [Float] = []
        var pieces = 0
        while let piece = try d.next() {
            l.append(contentsOf: piece.left)
            r.append(contentsOf: piece.right)
            pieces += 1
            if pieces == 2 || pieces == 5 { d.breakReaderForTesting() }
        }
        return (l, r, d, messages)
    }

    private func worstDifference(_ l: [Float], _ r: [Float], _ wantL: ArraySlice<Float>, _ wantR: ArraySlice<Float>) -> Float {
        let a = Array(wantL), b = Array(wantR)
        var worst: Float = 0
        for i in 0..<min(l.count, a.count) {
            worst = max(worst, abs(l[i] - a[i]), abs(r[i] - b[i]))
        }
        return worst
    }

    /// The reader is killed in the middle of the song, twice. The decoder must open the file
    /// again and carry on at the very sample where it stopped: what comes out is compared,
    /// sample for sample, with a decode that was never disturbed.
    func testReaderKilledMidFileIsReopenedAtTheSameSample() throws {
        for name in ["song-plain.m4a", "song-fragmented.m4a"] {
            let whole = try decodeAll(name)
            let broken = try decodeWithBreaks(name, startAt: 0, exact: false)
            XCTAssertGreaterThanOrEqual(broken.messages.count, 1, "the reader was killed, so the file must have been opened again")
            XCTAssertEqual(broken.left.count, whole.left.count, "\(name): nothing repeated, nothing left out")
            XCTAssertEqual(broken.decoder.framesRead, broken.left.count)
            let worst = worstDifference(broken.left, broken.right, whole.left[0...], whole.right[0...])
            print("RESULT resume \(name): reopened \(broken.messages.count) times, largest difference \(worst); \(broken.messages.joined(separator: " | "))")
            XCTAssertLessThanOrEqual(worst, 1e-6, "\(name): the samples after opening again are those of an undisturbed decode")
        }
    }

    /// `exact: true`: a decode that starts 1.2345 s into the song gives exactly the samples
    /// that a decode of the whole song has from that point on - also when its reader is killed
    /// on the way.
    func testExactStartGivesTheSongsOwnSamples() throws {
        for name in ["song-plain.m4a", "song-fragmented.m4a"] {
            let whole = try decodeAll(name)
            let at = Int((1.2345 * 44100).rounded())
            let d = try SongDecoder(url: Fixtures.url(name), startAt: 1.2345, exact: true)
            var l: [Float] = [], r: [Float] = []
            while let piece = try d.next() {
                l.append(contentsOf: piece.left)
                r.append(contentsOf: piece.right)
            }
            XCTAssertEqual(d.startTime, Double(at) / 44100, accuracy: 1e-9)
            XCTAssertEqual(l.count, whole.left.count - at, name)
            XCTAssertLessThanOrEqual(worstDifference(l, r, whole.left[at...], whole.right[at...]), 1e-6, name)

            let broken = try decodeWithBreaks(name, startAt: 1.2345, exact: true)
            XCTAssertGreaterThanOrEqual(broken.messages.count, 1)
            XCTAssertEqual(broken.left.count, whole.left.count - at, name)
            let worst = worstDifference(broken.left, broken.right, whole.left[at...], whole.right[at...])
            print("RESULT exact start \(name) with breaks: reopened \(broken.messages.count) times, largest difference \(worst)")
            XCTAssertLessThanOrEqual(worst, 1e-6, name)
        }
    }

    /// For the record, not a pass/fail matter: how a decode that the system starts in the
    /// middle of a song (the quick way, used for seeking) relates to the song's own samples,
    /// and what happens when its reader is killed.
    func testReportOnDecodesStartedMidSong() throws {
        let name = "song-fragmented.m4a"
        let whole = try decodeAll(name)
        let seeked = try decodeAll(name, startAt: 1.2345)
        let at = Int((seeked.decoder.startTime * 44100).rounded())
        /* at which shift do the first 2000 samples after 0.2 s fit the whole decode best? */
        var bestShift = 0
        var best = Float.greatestFiniteMagnitude
        for shift in -4000...4000 {
            var sum: Float = 0
            for i in 0..<2000 {
                let j = at + 8820 + i + shift
                if j < 0 || j >= whole.left.count || 8820 + i >= seeked.left.count { sum += 1; continue }
                sum += abs(seeked.left[8820 + i] - whole.left[j])
            }
            if sum < best {
                best = sum
                bestShift = shift
            }
        }
        print("RESULT decode started mid-song by the system: \(seeked.left.count) samples from \(seeked.decoder.startTime) s; fits the song's own samples best \(bestShift) samples later, mean difference there \(best / 2000)")
        let broken = try decodeWithBreaks(name, startAt: 1.2345, exact: false)
        print("RESULT the same with its reader killed twice: \(broken.left.count) samples (undisturbed \(seeked.left.count)); \(broken.messages.joined(separator: " | "))")
        XCTAssertGreaterThanOrEqual(broken.messages.count, 1)
        XCTAssertEqual(Double(broken.left.count), Double(seeked.left.count), accuracy: 13000)
    }

    /// Killed before anything was read: begins again from the asked-for place.
    func testReaderKilledBeforeTheFirstPiece() throws {
        let whole = try decodeAll("song-fragmented.m4a", startAt: 2.0)
        let d = try SongDecoder(url: Fixtures.url("song-fragmented.m4a"), startAt: 2.0)
        d.breakReaderForTesting()
        var count = 0
        while let piece = try d.next() { count += piece.left.count }
        XCTAssertEqual(count, whole.left.count)
        XCTAssertEqual(d.startTime, whole.decoder.startTime, accuracy: 1e-9)
    }

    func testMissingFileIsAnErrorWithAMessage() {
        XCTAssertThrowsError(try SongDecoder(url: URL(fileURLWithPath: "/nonexistent/song.m4a"))) { error in
            XCTAssertFalse("\(error)".isEmpty)
        }
    }

    /// Not a pass/fail test of our code: reports whether the system's own player accepts the
    /// fragmented file from disk (the phone app plays such files when the engine is not used).
    func testReportWhetherSystemPlayerAcceptsTheFragmentedFile() {
        for name in ["song-plain.m4a", "song-fragmented.m4a"] {
            let item = AVPlayerItem(url: Fixtures.url(name))
            let player = AVPlayer(playerItem: item)
            let deadline = Date().addingTimeInterval(8)
            while item.status == .unknown && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            let status = item.status == .readyToPlay ? "ready" : (item.status == .failed ? "FAILED" : "unknown after 8 s")
            print("RESULT system player with \(name): \(status), length \(String(format: "%.3f", item.duration.seconds)) s, error \(SongDecoder.describe(item.error))")
            player.replaceCurrentItem(with: nil)
        }
    }
}
