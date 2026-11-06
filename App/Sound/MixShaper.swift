import Foundation

/// The level and bass curves of a mix, as plain functions of `x` = how far the overlap has
/// got (0 at its start, 1 at its end).
public enum MixCurve {
    /// Level of the song coming in. Beat-matched: a sine over the whole overlap. Otherwise a
    /// sine that is at full level by the middle and stays there.
    public static func incomingGain(_ x: Double, synced: Bool) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        return sin(min(1, synced ? x : x / 0.5) * Double.pi / 2)
    }

    /// Level of the song going out: a cosine over the whole overlap.
    public static func outgoingGain(_ x: Double) -> Double {
        if x <= 0 { return 1 }
        if x >= 1 { return 0 }
        return cos(x * Double.pi / 2)
    }

    /// Beat-matched mixes only: how much of its bass a song keeps (1 = all, 0 = none; what is
    /// taken away is everything a 320 Hz high-pass removes). The bass changes hands around the
    /// middle, over an eighth of the overlap (a second at most). The two shares are a sine and
    /// a cosine, so the bass of the two together stays as strong as that of one song.
    public static func bassShare(_ x: Double, overlap: Double, incoming: Bool) -> Double {
        let swap = min(1, overlap / 8)
        if swap <= 0 { return incoming ? (x >= 0.5 ? 1 : 0) : (x >= 0.5 ? 0 : 1) }
        let u = min(1, max(0, (x * overlap - (overlap / 2 - swap / 2)) / swap))
        return incoming ? sin(u * Double.pi / 2) : cos(u * Double.pi / 2)
    }
}

public extension Biquad {
    /// A second-order (12 dB per octave) high-pass.
    static func highPass(frequency: Double, q: Double = 0.7071067811865476, sampleRate: Double) -> Biquad {
        let w = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w) / (2 * q)
        let c = cos(w)
        let a0 = 1 + alpha
        return Biquad(b0: (1 + c) / 2 / a0, b1: -(1 + c) / a0, b2: (1 + c) / 2 / a0,
                      a1: -2 * c / a0, a2: (1 - alpha) / a0)
    }
}

/// Applies the curves of a mix to one of its two songs, sample by sample, as the song is being
/// processed ahead of playback. Keeps its filter state between calls: hand it the song's
/// pieces in order, each with the position of its first sample counted from the start of the
/// overlap (negative before it).
///
/// Before the overlap the outgoing song passes untouched; after it, it is silent. The incoming
/// song is silent before the overlap and passes untouched after it.
public final class MixShaper {
    public enum Role {
        case incoming
        case outgoing
    }

    public static let bassFrequency = 320.0

    private let role: Role
    private let synced: Bool
    private let overlap: Double
    private let samples: Int
    private var left: Biquad
    private var right: Biquad

    public init(role: Role, synced: Bool, overlap: Double, sampleRate: Double) {
        self.role = role
        self.synced = synced
        self.overlap = overlap
        samples = max(1, Int((overlap * sampleRate).rounded()))
        left = Biquad.highPass(frequency: MixShaper.bassFrequency, sampleRate: sampleRate)
        right = left
    }

    /// Length of the overlap in samples.
    public var overlapSamples: Int { return samples }

    public func process(left l: inout [Float], right r: inout [Float], firstSample: Int) {
        let count = min(l.count, r.count)
        if count == 0 { return }
        /* Wholly outside the overlap: nothing to compute. */
        if firstSample >= samples {
            if role == .outgoing {
                for i in 0..<count {
                    l[i] = 0
                    r[i] = 0
                }
            }
            return
        }
        if firstSample + count <= 0 && role == .outgoing { return }

        var hl = left, hr = right
        let incoming = role == .incoming
        for i in 0..<count {
            let s = firstSample + i
            if s < 0 {
                if incoming {
                    l[i] = 0
                    r[i] = 0
                }
                continue
            }
            if s >= samples {
                if !incoming {
                    l[i] = 0
                    r[i] = 0
                }
                continue
            }
            let x = Double(s) / Double(samples)
            let gain = incoming ? MixCurve.incomingGain(x, synced: synced) : MixCurve.outgoingGain(x)
            var a = Double(l[i]), b = Double(r[i])
            if synced {
                /* What the high-pass lets through, plus this song's share of the rest (the bass). */
                let share = MixCurve.bassShare(x, overlap: overlap, incoming: incoming)
                let ha = hl.step(a), hb = hr.step(b)
                a = ha + share * (a - ha)
                b = hb + share * (b - hb)
            }
            l[i] = Float(a * gain)
            r[i] = Float(b * gain)
        }
        left = hl
        right = hr
    }
}
