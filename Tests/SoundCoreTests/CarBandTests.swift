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
}
