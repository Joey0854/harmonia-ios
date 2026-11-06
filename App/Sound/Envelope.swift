import Foundation

/// Makes the "envelope" of a song: how strong the bass and the middle are, thirty times a
/// second, two bytes per step. The page moves its backdrop light by it.
///
/// Must give the same bytes as `ensureEnv` in the PC server (ytm-remote/server.js): mono mix at
/// 11025 Hz; three one-pole low-pass filters (180, 400, 2800 Hz); byte 0 from the 180 Hz one,
/// byte 1 from (2800 Hz − 400 Hz); each byte = 255 × fourth root of the mean square, capped.
///
/// Feed the mono mix piece by piece with `add`, then take `finish()`.
public final class EnvelopeMaker {
    private static let rate = 11025
    private static let stepsPerSecond = 30

    private let resampler: Resampler?
    private let aLow: Double, aLo: Double, aHi: Double
    private var low = 0.0, lo = 0.0, hi = 0.0
    private var bass = 0.0, mid = 0.0
    private var index = 0
    private var step = 0
    private var stepStart = 0
    private var stepEnd: Int
    private var bytes = Data()

    public init(sampleRate: Int) {
        let sr = Double(EnvelopeMaker.rate)
        resampler = sampleRate == EnvelopeMaker.rate ? nil : Resampler(from: sampleRate, to: EnvelopeMaker.rate)
        aLow = exp(-2 * Double.pi * 180 / sr)
        aLo = exp(-2 * Double.pi * 400 / sr)
        aHi = exp(-2 * Double.pi * 2800 / sr)
        stepEnd = EnvelopeMaker.rate / EnvelopeMaker.stepsPerSecond
    }

    public func add(mono: [Float]) {
        consume(resampler?.process(mono) ?? mono)
    }

    public func finish() -> Data {
        if let r = resampler { consume(r.finish()) }
        return bytes
    }

    private func consume(_ samples: [Float]) {
        for sample in samples {
            let v = Double(sample)
            low = low * aLow + v * (1 - aLow)
            lo = lo * aLo + v * (1 - aLo)
            hi = hi * aHi + v * (1 - aHi)
            let m = hi - lo
            bass += low * low
            mid += m * m
            index += 1
            if index == stepEnd {
                let length = Double(max(1, stepEnd - stepStart))
                bytes.append(EnvelopeMaker.byte(bass / length))
                bytes.append(EnvelopeMaker.byte(mid / length))
                bass = 0
                mid = 0
                step += 1
                stepStart = stepEnd
                /* 367.5 samples per step: the ends alternate between 367 and 368 apart. */
                stepEnd = (step + 1) * EnvelopeMaker.rate / EnvelopeMaker.stepsPerSecond
            }
        }
    }

    /// Square root twice: the byte keeps detail in quiet passages.
    private static func byte(_ meanSquare: Double) -> UInt8 {
        let value = (255 * meanSquare.squareRoot().squareRoot()).rounded()
        return UInt8(min(255, max(0, value)))
    }
}
