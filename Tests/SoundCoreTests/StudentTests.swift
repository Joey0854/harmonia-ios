import XCTest
import SoundCore

/// The student network's pre- and post-processing (App/Sound/StudentSeparator.swift), with a fake
/// network whose masks are known: what goes back must be exactly the masked mix.
final class StudentTests: XCTestCase {
    /// "other" gets mask 1 + 0i on both channels, "bass" 0 + 1i on the left only, the rest 0.
    final class FakeStudent: StudentNetwork {
        var inputCount = 0
        func run(spec: [Float]) throws -> [Float] {
            inputCount = spec.count
            let plane = Demucs.bins * Demucs.frames
            var m = [Float](repeating: 0, count: 20 * plane)
            let other = Student.stems.firstIndex(of: "other")! * 4
            let bass = Student.stems.firstIndex(of: "bass")! * 4
            for k in 0..<plane {
                m[(other + 0) * plane + k] = 1
                m[(other + 2) * plane + k] = 1
                m[(bass + 1) * plane + k] = 1
            }
            return m
        }
    }

    private func signal() -> (left: [Float], right: [Float]) {
        let n = Demucs.segment
        let left = (0..<n).map { Float(0.3 * sin(2 * Double.pi * 220 * Double($0) / 44100)) }
        let right = (0..<n).map { Float(0.2 * sin(2 * Double.pi * 331 * Double($0) / 44100 + 1)) }
        return (left, right)
    }

    func testMasksAreAppliedToTheMix() throws {
        let x = signal()
        let net = FakeStudent()
        let stems = try Student.separate(left: x.left, right: x.right, network: net)
        XCTAssertEqual(net.inputCount, 4 * Demucs.bins * Demucs.frames)
        XCTAssertEqual(stems.count, 5)
        XCTAssertEqual(stems[0].count, 2)
        XCTAssertEqual(stems[0][0].count, Demucs.segment)
        let other = Student.stems.firstIndex(of: "other")!
        let bass = Student.stems.firstIndex(of: "bass")!
        let vocals = Student.stems.firstIndex(of: "vocals")!
        let zl = Demucs.spectrum(x.left), zr = Demucs.spectrum(x.right)
        let refL = Demucs.inverse(re: zl.re, im: zl.im), refR = Demucs.inverse(re: zr.re, im: zr.im)
        /* i × spectrum: re = -im, im = re */
        let rotL = Demucs.inverse(re: zl.im.map { -$0 }, im: zl.re)
        for n in stride(from: 0, to: Demucs.segment, by: 997) {
            XCTAssertEqual(stems[other][0][n], refL[n], accuracy: 1e-6)
            XCTAssertEqual(stems[other][1][n], refR[n], accuracy: 1e-6)
            XCTAssertEqual(stems[bass][0][n], rotL[n], accuracy: 1e-6)
            XCTAssertEqual(stems[bass][1][n], 0, accuracy: 1e-9)
            XCTAssertEqual(stems[vocals][0][n], 0, accuracy: 1e-9)
        }
    }
}
