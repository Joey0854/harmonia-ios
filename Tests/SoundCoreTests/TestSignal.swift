import Foundation

/// The 6-second, 48 kHz stereo test signal: noise bursts of changing strength, two sweeping
/// tones (up in the left channel, down in the right), and a silent stretch at 4.0 - 4.75 s.
///
/// Made with whole-number arithmetic only, so that Tests/tools/make-fixtures.js (which fed the
/// same signal to ffmpeg to get the expected results) produces exactly the same samples.
/// `checksum` is compared with the one that script stored.
enum TestSignal {
    static let sampleRate = 48000
    static let frames = 288000

    static func make() -> (left: [Int16], right: [Int16]) {
        var left = [Int16](repeating: 0, count: frames)
        var right = [Int16](repeating: 0, count: frames)
        var sa: UInt32 = 12345
        var sb: UInt32 = 987654321
        var pa: UInt32 = 0
        var pb: UInt32 = 0
        for n in 0..<frames {
            sa = sa &* 1664525 &+ 1013904223
            sb = sb &* 22695477 &+ 1
            let na = Int((sa >> 16) & 0xFFFF) - 32768
            let nb = Int((sb >> 16) & 0xFFFF) - 32768
            pa = pa &+ UInt32(8947849 + 2454 * n)
            pb = pb &+ UInt32(715000000 - 2454 * n)
            let qa = Int(pa >> 16)
            let qb = Int(pb >> 16)
            let ta = qa < 32768 ? qa * 2 - 32768 : (65535 - qa) * 2 - 32768
            let tb = qb < 32768 ? qb * 2 - 32768 : (65535 - qb) * 2 - 32768
            let ka = n / 36000
            let kb = (n + 12000) / 36000
            let ampA = (n % 36000) < 24000 ? 1 + (ka * 3) % 6 : 0
            let ampB = ((n + 12000) % 36000) < 24000 ? 1 + (kb * 5) % 6 : 0
            let quiet = n >= 192000 && n < 228000
            let sweep = n < 192000
            let l = ((na * ampA) >> 4) + (sweep ? (ta >> 2) : 0)
            let r = ((nb * ampB) >> 4) + (sweep ? (tb >> 2) : 0)
            left[n] = quiet ? 0 : Int16(l)
            right[n] = quiet ? 0 : Int16(r)
        }
        return (left, right)
    }

    static func checksum(_ signal: (left: [Int16], right: [Int16])) -> UInt32 {
        var h: UInt32 = 0
        for n in 0..<frames {
            h = h &* 31 &+ UInt32(UInt16(bitPattern: signal.left[n]))
            h = h &* 31 &+ UInt32(UInt16(bitPattern: signal.right[n]))
        }
        return h
    }

    static func floats(_ samples: [Int16]) -> [Float] {
        return samples.map { Float($0) / 32768 }
    }
}

/// Repeatable random numbers for the tests.
struct TestRandom {
    private var state: UInt32
    init(seed: UInt32) { state = seed }
    /// Evenly spread in −1 ..< 1.
    mutating func next() -> Float {
        state = state &* 1664525 &+ 1013904223
        return Float(Int32(bitPattern: state) >> 8) / 8388608
    }
}

enum Fixtures {
    static func url(_ name: String) -> URL {
        return Bundle.module.resourceURL!.appendingPathComponent("Fixtures").appendingPathComponent(name)
    }
    static func data(_ name: String) throws -> Data {
        return try Data(contentsOf: url(name))
    }
    static func info() throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data("fixture.json"))
        return object as? [String: Any] ?? [:]
    }
}
