import Accelerate
import Foundation

/// "True stereo" convolution: the left input goes through a two-channel impulse response
/// (one channel per ear), the right input through another, and each ear gets the sum.
///
///     outLeft  = left * irLeft[0]  + right * irRight[0]
///     outRight = left * irLeft[1]  + right * irRight[1]
///
/// Method: the impulse responses are cut into pieces of `blockSize` samples and each piece is
/// kept as its spectrum. Input is taken in blocks of `blockSize`; the spectrum of the last two
/// blocks is multiplied with the first piece, the spectrum from one block earlier with the
/// second piece, and so on; everything is added up and one inverse transform per ear gives
/// `blockSize` finished samples. The result is the same as slow sample-by-sample convolution
/// (the tests compare the two), with no delay: output sample n belongs to input sample n.
///
/// Input may arrive in pieces of any size; output comes in whole blocks, the rest waits for
/// more input (or `flush`). After `reset` the convolver has forgotten all earlier sound, as if
/// silence had come before.
///
/// Not thread-safe: use one instance from one queue.
public final class TrueStereoConvolver {
    public let blockSize: Int

    private let fftSize: Int
    private let log2n: vDSP_Length
    private let bins: Int            // fftSize / 2 + 1: the half of the spectrum we work with
    private let partitions: Int
    private let setup: FFTSetup

    /* Spectra of the impulse-response pieces: index (ear * 2 + input), then piece, then bin. */
    private let hRe: UnsafeMutablePointer<Float>
    private let hIm: UnsafeMutablePointer<Float>
    /* Spectra of the most recent input blocks, as a ring: index input, then slot, then bin. */
    private let xRe: UnsafeMutablePointer<Float>
    private let xIm: UnsafeMutablePointer<Float>
    private var ring = 0
    /* The previous input block per input channel. */
    private let previous: UnsafeMutablePointer<Float>
    /* Work space for one transform. */
    private let inRe: UnsafeMutablePointer<Float>
    private let inIm: UnsafeMutablePointer<Float>
    private let outRe: UnsafeMutablePointer<Float>
    private let outIm: UnsafeMutablePointer<Float>
    private let accRe: UnsafeMutablePointer<Float>
    private let accIm: UnsafeMutablePointer<Float>

    private var pendingLeft: [Float] = []
    private var pendingRight: [Float] = []

    /// `irLeft` and `irRight` each hold two channels (ear 0 = left ear, ear 1 = right ear); a
    /// single channel is used for both ears. `blockSize` must be a power of two.
    public init(irLeft: [[Float]], irRight: [[Float]], blockSize: Int = 4096) {
        var size = 16
        var log = 4
        while size < blockSize { size *= 2; log += 1 }
        self.blockSize = size
        fftSize = size * 2
        log2n = vDSP_Length(log + 1)
        bins = size + 1
        /* ear * 2 + input */
        let responses: [[Float]] = [
            irLeft.first ?? [], irRight.first ?? [],
            irLeft.count > 1 ? irLeft[1] : (irLeft.first ?? []),
            irRight.count > 1 ? irRight[1] : (irRight.first ?? [])
        ]
        let longest = responses.map { $0.count }.max() ?? 0
        partitions = max(1, (longest + size - 1) / size)
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!

        func zeros(_ count: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: count)
            p.initialize(repeating: 0, count: count)
            return p
        }
        hRe = zeros(4 * partitions * bins)
        hIm = zeros(4 * partitions * bins)
        xRe = zeros(2 * partitions * bins)
        xIm = zeros(2 * partitions * bins)
        previous = zeros(2 * size)
        inRe = zeros(fftSize)
        inIm = zeros(fftSize)
        outRe = zeros(fftSize)
        outIm = zeros(fftSize)
        accRe = zeros(bins)
        accIm = zeros(bins)

        for (index, response) in responses.enumerated() {
            for piece in 0..<partitions {
                let from = piece * size
                for i in 0..<fftSize {
                    let source = from + i
                    inRe[i] = (i < size && source < response.count) ? response[source] : 0
                    inIm[i] = 0
                }
                transform(inverse: false)
                let at = (index * partitions + piece) * bins
                for k in 0..<bins {
                    hRe[at + k] = outRe[k]
                    hIm[at + k] = outIm[k]
                }
            }
        }
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        for p in [hRe, hIm, xRe, xIm, previous, inRe, inIm, outRe, outIm, accRe, accIm] {
            p.deallocate()
        }
    }

    /// Forgets all sound heard so far, including input still waiting for a full block.
    public func reset() {
        let count = 2 * partitions * bins
        for i in 0..<count {
            xRe[i] = 0
            xIm[i] = 0
        }
        for i in 0..<(2 * blockSize) { previous[i] = 0 }
        ring = 0
        pendingLeft.removeAll(keepingCapacity: true)
        pendingRight.removeAll(keepingCapacity: true)
    }

    /// Takes more input (both channels the same length) and returns the output that is
    /// complete: a whole number of blocks, possibly none.
    public func process(left: [Float], right: [Float]) -> (left: [Float], right: [Float]) {
        let count = min(left.count, right.count)
        pendingLeft.append(contentsOf: left[0..<count])
        pendingRight.append(contentsOf: right[0..<count])
        return drain()
    }

    /// Returns the output for input that was still waiting for a full block. Afterwards the
    /// convolver is as after `reset`.
    public func flush() -> (left: [Float], right: [Float]) {
        let waiting = pendingLeft.count
        if waiting == 0 {
            reset()
            return ([], [])
        }
        let padding = [Float](repeating: 0, count: blockSize - waiting)
        pendingLeft.append(contentsOf: padding)
        pendingRight.append(contentsOf: padding)
        let out = drain()
        reset()
        return (Array(out.left[0..<waiting]), Array(out.right[0..<waiting]))
    }

    private func drain() -> (left: [Float], right: [Float]) {
        let size = blockSize
        let blocks = pendingLeft.count / size
        if blocks == 0 { return ([], []) }
        var outLeft = [Float](repeating: 0, count: blocks * size)
        var outRight = [Float](repeating: 0, count: blocks * size)
        pendingLeft.withUnsafeBufferPointer { l in
            pendingRight.withUnsafeBufferPointer { r in
                outLeft.withUnsafeMutableBufferPointer { ol in
                    outRight.withUnsafeMutableBufferPointer { or in
                        guard let lp = l.baseAddress, let rp = r.baseAddress,
                              let olp = ol.baseAddress, let orp = or.baseAddress else { return }
                        for b in 0..<blocks {
                            block(left: lp + b * size, right: rp + b * size,
                                  outLeft: olp + b * size, outRight: orp + b * size)
                        }
                    }
                }
            }
        }
        pendingLeft.removeFirst(blocks * size)
        pendingRight.removeFirst(blocks * size)
        return (outLeft, outRight)
    }

    /// One block: exactly `blockSize` samples in, the same number out.
    private func block(left: UnsafePointer<Float>, right: UnsafePointer<Float>,
                       outLeft: UnsafeMutablePointer<Float>, outRight: UnsafeMutablePointer<Float>) {
        let size = blockSize
        /* Spectrum of [previous block, this block] for each input channel. */
        for input in 0..<2 {
            let current = input == 0 ? left : right
            let old = previous + input * size
            for i in 0..<size {
                inRe[i] = old[i]
                inRe[size + i] = current[i]
                old[i] = current[i]
            }
            for i in 0..<fftSize { inIm[i] = 0 }
            transform(inverse: false)
            let at = (input * partitions + ring) * bins
            for k in 0..<bins {
                xRe[at + k] = outRe[k]
                xIm[at + k] = outIm[k]
            }
        }
        let scale = 1 / Float(fftSize)
        for ear in 0..<2 {
            for k in 0..<bins {
                accRe[k] = 0
                accIm[k] = 0
            }
            for piece in 0..<partitions {
                /* The input spectrum from `piece` blocks ago meets piece number `piece`. */
                let slot = (ring - piece + partitions) % partitions
                for input in 0..<2 {
                    let xr = xRe + (input * partitions + slot) * bins
                    let xi = xIm + (input * partitions + slot) * bins
                    let hr = hRe + ((ear * 2 + input) * partitions + piece) * bins
                    let hi = hIm + ((ear * 2 + input) * partitions + piece) * bins
                    for k in 0..<bins {
                        let a = xr[k], b = xi[k], c = hr[k], d = hi[k]
                        accRe[k] += a * c - b * d
                        accIm[k] += a * d + b * c
                    }
                }
            }
            /* The other half of the spectrum of a real signal is the mirror image. */
            for k in 0..<bins {
                inRe[k] = accRe[k]
                inIm[k] = accIm[k]
            }
            for k in 1..<size {
                inRe[fftSize - k] = accRe[k]
                inIm[fftSize - k] = -accIm[k]
            }
            transform(inverse: true)
            /* Only the second half is free of wrap-around; that half is this block's output. */
            let out = ear == 0 ? outLeft : outRight
            for i in 0..<size { out[i] = outRe[size + i] * scale }
        }
        ring = (ring + 1) % partitions
    }

    /// Transforms (inRe, inIm) into (outRe, outIm). Neither direction is scaled.
    private func transform(inverse: Bool) {
        var input = DSPSplitComplex(realp: inRe, imagp: inIm)
        var output = DSPSplitComplex(realp: outRe, imagp: outIm)
        let direction = FFTDirection(inverse ? kFFTDirection_Inverse : kFFTDirection_Forward)
        vDSP_fft_zop(setup, &input, 1, &output, 1, log2n, direction)
    }
}
