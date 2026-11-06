import Foundation

/* Each song's own light colour: from its cover art, or (covers without colour) from its sound.
   Pure functions, no images and no audio in here (package target LightCore). */

/// A light colour without brightness: hue in degrees, saturation 0 ... 1.
public struct LightColour: Equatable {
    public var hue: Double
    public var saturation: Double

    public init(hue: Double, saturation: Double) {
        self.hue = LightColour.wrap(hue)
        self.saturation = min(1, max(0, saturation))
    }

    static func wrap(_ h: Double) -> Double {
        let x = h.truncatingRemainder(dividingBy: 360)
        return x < 0 ? x + 360 : x
    }

    /// Hue difference b − a the short way round, -180 ... 180.
    public static func hueDelta(_ a: Double, _ b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    /// Part way from `a` to `b` (t 0 ... 1), the hue the short way round.
    public static func mix(_ a: LightColour, _ b: LightColour, _ t: Double) -> LightColour {
        let x = min(1, max(0, t))
        return LightColour(hue: a.hue + hueDelta(a.hue, b.hue) * x,
                           saturation: a.saturation + (b.saturation - a.saturation) * x)
    }

    /// "#rrggbb" at full value, for the log.
    public var hex: String {
        let c = LightMapper.hsv(hue: hue, saturation: saturation)
        return String(format: "#%02x%02x%02x", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded()))
    }
}

/// A song's two colours: the base, and the one choruses lean toward.
public struct LightPalette: Equatable {
    public enum Source: String { case cover, audio }

    /// LEDs show pale colours as white: the light never uses less saturation than this.
    public static let minSaturation = 0.75
    /// Below this share of vivid pixels a cover counts as colourless.
    public static let minVivid = 0.08

    public var primary: LightColour
    public var secondary: LightColour
    public var source: Source
    /// Share of vivid pixels in the cover (0 for the audio colour).
    public var vivid: Double

    public init(primary: LightColour, secondary: LightColour, source: Source, vivid: Double) {
        self.primary = primary
        self.secondary = secondary
        self.source = source
        self.vivid = vivid
    }

    /// The colour at a chorus amount (0 = verse, 1 = chorus): half way to the secondary colour
    /// and full saturation.
    public func colour(chorus c: Double) -> LightColour {
        let x = min(1, max(0, c))
        var mixed = LightColour.mix(primary, secondary, 0.5 * x)
        mixed.saturation = primary.saturation + (1 - primary.saturation) * x
        return mixed
    }

    /// The footwell's colour at a chorus amount: the secondary colour (the primary turned 15
    /// degrees when the two are the same), with the same saturation lift as the primary.
    public func footColour(chorus c: Double) -> LightColour {
        let x = min(1, max(0, c))
        var base = secondary
        if abs(LightColour.hueDelta(primary.hue, secondary.hue)) < 1 {
            base = LightColour(hue: primary.hue + 15, saturation: primary.saturation)
        }
        base.saturation = base.saturation + (1 - base.saturation) * x
        return base
    }

    /// One line for the log.
    public func describe(_ id: String) -> String {
        return "light palette \(id): primary \(primary.hex) secondary \(secondary.hex) from \(source.rawValue) (vivid \(Int((vivid * 100).rounded())) %)"
    }

    /// Hue (degrees), saturation and value of an RGB colour (channels 0 ... 1).
    public static func hsv(r: Double, g: Double, b: Double) -> (h: Double, s: Double, v: Double) {
        let mx = max(r, g, b), mn = min(r, g, b)
        let d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r { h = 60 * ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = 60 * ((b - r) / d + 2) }
            else { h = 60 * ((r - g) / d + 4) }
        }
        if h < 0 { h += 360 }
        return (h, mx > 0 ? d / mx : 0, mx)
    }

    /// The palette of a cover, from its pixels (RGBA, 8 bits each, row after row; already made
    /// small, about 48 × 48). nil when too little of it is colourful (black-and-white or grey
    /// covers); use `fromAudio` then.
    ///
    /// Near-black (V < 0.15), near-white (V > 0.92 and S < 0.12) and grey (S < 0.18) pixels are
    /// left out. The rest are counted in 24 hue bins weighted by S × V; the primary colour is the
    /// strongest group of three neighbouring bins. The secondary: a real second colour (a group
    /// 40 degrees or more away with at least 35 % of the primary's weight, best weight x
    /// saturation); otherwise the cover's neighbouring colour (`neighbour`); for a single flat
    /// colour the primary + 15 degrees (`fallbackSecondaryHue`).
    public static func fromCover(rgba: [UInt8], width: Int, height: Int) -> LightPalette? {
        let n = width * height
        guard n > 0, rgba.count >= n * 4 else { return nil }
        let bins = 24
        var weight = [Double](repeating: 0, count: bins)
        var sx = [Double](repeating: 0, count: bins)
        var sy = [Double](repeating: 0, count: bins)
        var ss = [Double](repeating: 0, count: bins)
        var vivid = 0
        var colourful: [(h: Double, s: Double, w: Double)] = []
        for k in 0..<n {
            let o = k * 4
            if rgba[o + 3] < 128 { continue }   // transparent
            let c = hsv(r: Double(rgba[o]) / 255, g: Double(rgba[o + 1]) / 255, b: Double(rgba[o + 2]) / 255)
            if c.v < 0.15 || (c.v > 0.92 && c.s < 0.12) || c.s < 0.18 { continue }
            vivid += 1
            let w = c.s * c.v
            let i = min(bins - 1, Int(c.h / (360.0 / Double(bins))))
            weight[i] += w
            sx[i] += w * cos(c.h * Double.pi / 180)
            sy[i] += w * sin(c.h * Double.pi / 180)
            ss[i] += w * c.s
            colourful.append((c.h, c.s, w))
        }
        let share = Double(vivid) / Double(n)
        if share < minVivid { return nil }

        func group(_ i: Int) -> (w: Double, hue: Double, s: Double) {
            var w = 0.0, x = 0.0, y = 0.0, s = 0.0
            for j in [i - 1, i, i + 1] {
                let b = (j + bins) % bins
                w += weight[b]; x += sx[b]; y += sy[b]; s += ss[b]
            }
            let hue = atan2(y, x) * 180 / Double.pi
            return (w, hue, w > 0 ? s / w : 0)
        }
        let groups = (0..<bins).map { group($0) }
        guard let first = groups.indices.max(by: { groups[$0].w < groups[$1].w }), groups[first].w > 0 else { return nil }
        let p = groups[first]
        let primary = LightColour(hue: p.hue, saturation: max(minSaturation, p.s))
        var secondary = LightColour(hue: fallbackSecondaryHue(p.hue), saturation: primary.saturation)
        /* 1. a real second colour: 40 degrees or more away, at least 35 % of the primary's weight */
        let far = groups.indices.filter { abs(LightColour.hueDelta(p.hue, groups[$0].hue)) >= 40 && groups[$0].w >= 0.35 * p.w }
        if let second = far.max(by: { groups[$0].w * groups[$0].s < groups[$1].w * groups[$1].s }) {
            let q = groups[second]
            secondary = LightColour(hue: q.hue, saturation: max(minSaturation, q.s))
        } else if let side = neighbour(of: p.hue, in: colourful) {
            /* 2. a neighbouring colour from the cover itself */
            secondary = LightColour(hue: p.hue + side.offset, saturation: max(minSaturation, side.s))
        }
        return LightPalette(primary: primary, secondary: secondary, source: .cover, vivid: share)
    }

    /// The cover's own neighbouring colour: of the colourful pixels within 60 degrees of the
    /// primary (and at least 1 degree from it), the side - above or below - with more weight; its
    /// weighted mean hue offset, pushed out to at least 12 degrees (at most 40), and its mean
    /// saturation. nil when neither side has anything.
    static func neighbour(of hue: Double, in pixels: [(h: Double, s: Double, w: Double)]) -> (offset: Double, s: Double)? {
        var upW = 0.0, upD = 0.0, upS = 0.0, downW = 0.0, downD = 0.0, downS = 0.0
        for px in pixels {
            let d = LightColour.hueDelta(hue, px.h)
            if abs(d) < 1 || abs(d) > 60 { continue }
            if d > 0 {
                upW += px.w; upD += px.w * d; upS += px.w * px.s
            } else {
                downW += px.w; downD += px.w * d; downS += px.w * px.s
            }
        }
        let up = upW >= downW
        let w = up ? upW : downW
        guard w > 0 else { return nil }
        let mean = (up ? upD : downD) / w
        let offset = (up ? 1.0 : -1.0) * min(40, max(12, abs(mean)))
        return (offset, (up ? upS : downS) / w)
    }

    /// The secondary hue of a single flat colour: the primary + 15 degrees, or - 15 when that
    /// lands in yellow-green (65 ... 150, which rarely belongs to a cover).
    public static func fallbackSecondaryHue(_ primary: Double) -> Double {
        let plus = LightColour.wrap(primary + 15)
        return plus >= 65 && plus <= 150 ? LightColour.wrap(primary - 15) : plus
    }

    /// A colour from the sound, for covers without colour: from the ratio of the upper range to
    /// the bass (the reference levels of the song's light envelope). Dark, bass-heavy songs get
    /// warm colours (purple through red to orange), bright songs cool ones (cyan to blue).
    public static func fromAudio(bassRef: Double, midRef: Double) -> LightPalette {
        let ratio = max(1e-4, midRef) / max(1e-4, bassRef)
        /* ratio 1/4 or less = fully dark, 2 or more = fully bright */
        let t = min(1, max(0, (log2(ratio) + 2) / 3))
        let hue: Double
        if t < 0.5 {
            hue = 280 + 110 * (t / 0.5)          // purple 280 -> red 360 -> orange 30
        } else {
            hue = 175 + 50 * ((t - 0.5) / 0.5)   // cyan 175 -> blue 225
        }
        let primary = LightColour(hue: hue, saturation: 1)
        return LightPalette(primary: primary, secondary: LightColour(hue: hue + 35, saturation: 1),
                            source: .audio, vivid: 0)
    }
}

/// The base colour while songs play in "song" mode, frame by frame.
///
/// - Each playing song contributes its palette colour at its own chorus amount, which glides
///   (2 s from verse to chorus and back) toward 1 inside a loud section and 0 outside.
/// - During a mix the songs' colours are blended by their levels, so the colour changes with
///   the music.
/// - The colour shown follows that target with a time constant of 1 s (a change of song is
///   about complete after 3 s). Songs without a palette yet leave the colour where it is; at
///   the very start the given fallback (the drifting hue) is used.
public final class LightSongColour {
    public struct Part {
        public let id: String
        public let palette: LightPalette?
        public let inSection: Bool
        public let weight: Double

        public init(id: String, palette: LightPalette?, inSection: Bool, weight: Double) {
            self.id = id
            self.palette = palette
            self.inSection = inSection
            self.weight = weight
        }
    }

    public static let sectionGlide = 2.0
    public static let followSeconds = 1.0

    public private(set) var shown: LightColour?
    private var chorus: [String: Double] = [:]
    private var hadPalette = false
    /// Follows the songs' footwell colours (`LightPalette.footColour`) instead of the primary.
    public let footwell: Bool

    public init(footwell: Bool = false) {
        self.footwell = footwell
    }

    public func chorusAmount(_ id: String) -> Double {
        return chorus[id] ?? 0
    }

    /// `intensity` scales the loud-section shift (0 = always the plain primary colour).
    public func step(_ parts: [Part], dt: Double, fallback: LightColour, intensity: Double = 1) -> LightColour {
        var target: LightColour?
        var total = 0.0
        var kept: [String: Double] = [:]
        for p in parts {
            var c = chorus[p.id] ?? 0
            let goal = p.inSection ? 1.0 : 0.0
            let step = dt / LightSongColour.sectionGlide
            c += min(step, max(-step, goal - c))
            kept[p.id] = c
            guard let palette = p.palette, p.weight > 0 else { continue }
            let amount = c * min(1, max(0, intensity))
            let colour = footwell ? palette.footColour(chorus: amount) : palette.colour(chorus: amount)
            if let t = target {
                target = LightColour.mix(t, colour, p.weight / (total + p.weight))
            } else {
                target = colour
            }
            total += p.weight
        }
        chorus = kept
        if target != nil { hadPalette = true }
        let start = shown ?? fallback
        /* nothing known: the drifting hue until the first palette, then stay */
        let goal = target ?? (hadPalette ? start : fallback)
        let next = LightColour.mix(start, goal, 1 - exp(-max(0, dt) / LightSongColour.followSeconds))
        shown = next
        return next
    }

    public func reset() {
        shown = nil
        chorus = [:]
        hadPalette = false
    }
}
