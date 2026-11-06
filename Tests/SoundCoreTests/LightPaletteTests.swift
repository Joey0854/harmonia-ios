import XCTest
import LightCore
import SoundCore

/// Each song's light colour: from its cover, otherwise from its sound.
final class LightPaletteTests: XCTestCase {
    /// A 48 × 48 picture: `fill` everywhere, then each part painted over the first `share` of
    /// the pixels after the previous part.
    private func image(_ fill: (UInt8, UInt8, UInt8), _ parts: [((UInt8, UInt8, UInt8), Double)] = []) -> [UInt8] {
        let n = 48 * 48
        var px = [UInt8](repeating: 255, count: n * 4)
        for k in 0..<n { px[k * 4] = fill.0; px[k * 4 + 1] = fill.1; px[k * 4 + 2] = fill.2 }
        var at = 0
        for (c, share) in parts {
            let count = Int(Double(n) * share)
            for k in at..<min(n, at + count) { px[k * 4] = c.0; px[k * 4 + 1] = c.1; px[k * 4 + 2] = c.2 }
            at += count
        }
        return px
    }

    private func near(_ a: Double, _ b: Double, _ tolerance: Double, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(abs(LightColour.hueDelta(a, b)), tolerance, "\(a) vs \(b)", file: file, line: line)
    }

    func testOneStrongColour() {
        guard let p = LightPalette.fromCover(rgba: image((220, 20, 20)), width: 48, height: 48) else { return XCTFail("none") }
        near(p.primary.hue, 0, 3)
        XCTAssertGreaterThanOrEqual(p.primary.saturation, 0.75)
        near(p.secondary.hue, 15, 3)   // a single flat colour: the primary + 15°
        XCTAssertEqual(p.source, .cover)
        XCTAssertEqual(p.vivid, 1, accuracy: 1e-9)
    }

    /// A fully saturated colour of a hue.
    private func pure(_ hue: Double) -> (UInt8, UInt8, UInt8) {
        let c = LightMapper.hsv(hue: hue, saturation: 1)
        return (UInt8((c.r * 255).rounded()), UInt8((c.g * 255).rounded()), UInt8((c.b * 255).rounded()))
    }

    /// A cover from a hue histogram (hue, percent of the pixels), the rest dark.
    private func cover(_ histogram: [(Double, Double)]) -> [UInt8] {
        return image((8, 8, 8), histogram.map { (pure($0.0), $0.1 / 100) })
    }

    func testOrangeCoverGetsYellowOrange() {
        let px = cover([(15, 4), (25, 14), (35, 28), (45, 51), (55, 3)])
        guard let p = LightPalette.fromCover(rgba: px, width: 48, height: 48) else { return XCTFail("none") }
        near(p.primary.hue, 39, 3)
        XCTAssertTrue(p.secondary.hue >= 46 && p.secondary.hue <= 56, "yellow-orange: \(p.secondary.hue)")
    }

    func testSkyBlueCoverGetsANeighbouringBlue() {
        let px = cover([(175, 4), (185, 12), (195, 33), (205, 28), (215, 18), (225, 3)])
        guard let p = LightPalette.fromCover(rgba: px, width: 48, height: 48) else { return XCTFail("none") }
        near(p.primary.hue, 201, 3)
        let d = abs(LightColour.hueDelta(p.primary.hue, p.secondary.hue))
        XCTAssertTrue(d >= 12 - 1e-9 && d <= 40 + 1e-9, "neighbour: \(p.secondary.hue)")
        XCTAssertFalse(p.secondary.hue >= 65 && p.secondary.hue <= 150)
    }

    func testRedAndBlueCoverKeepsItsBlue() {
        let px = image((8, 8, 8), [((230, 20, 20), 0.52), ((20, 20, 230), 0.48)])
        guard let p = LightPalette.fromCover(rgba: px, width: 48, height: 48) else { return XCTFail("none") }
        near(p.primary.hue, 0, 3)
        near(p.secondary.hue, 240, 3)
    }

    func testFlatOrangeCoverTurnsFifteen() {
        guard let p = LightPalette.fromCover(rgba: image((255, 166, 0)), width: 48, height: 48) else { return XCTFail("none") }
        near(p.primary.hue, 39, 2)
        near(p.secondary.hue, 54, 2)
    }

    func testFlatFallbackAvoidsYellowGreen() {
        XCTAssertEqual(LightPalette.fallbackSecondaryHue(200), 215, accuracy: 1e-9)
        XCTAssertEqual(LightPalette.fallbackSecondaryHue(39), 54, accuracy: 1e-9)
        XCTAssertEqual(LightPalette.fallbackSecondaryHue(55), 40, accuracy: 1e-9)
        XCTAssertEqual(LightPalette.fallbackSecondaryHue(350), 5, accuracy: 1e-9)
    }

    func testTwoColours() {
        let px = image((0, 0, 255), [((255, 255, 0), 0.3)])
        guard let p = LightPalette.fromCover(rgba: px, width: 48, height: 48) else { return XCTFail("none") }
        near(p.primary.hue, 240, 3)
        near(p.secondary.hue, 60, 3)
    }

    func testMostlyBlackWithASmallRedLogo() {
        let px = image((5, 5, 5), [((200, 10, 30), 0.12)])
        guard let p = LightPalette.fromCover(rgba: px, width: 48, height: 48) else { return XCTFail("none") }
        near(p.primary.hue, 354, 4)
        XCTAssertEqual(p.vivid, 0.12, accuracy: 0.01)
        XCTAssertTrue(p.describe("abc").hasPrefix("light palette abc: primary #"))
        XCTAssertTrue(p.describe("abc").hasSuffix("from cover (vivid 12 %)"))
    }

    func testGreyCoverFallsBackToTheSound() {
        let grey = image((128, 128, 128), [((250, 250, 250), 0.3), ((10, 10, 10), 0.3), ((200, 30, 30), 0.05)])
        XCTAssertNil(LightPalette.fromCover(rgba: grey, width: 48, height: 48), "5 % colour is not enough")

        let dark = LightPalette.fromAudio(bassRef: 0.4, midRef: 0.05)
        XCTAssertEqual(dark.source, .audio)
        XCTAssertTrue(dark.primary.hue >= 270 || dark.primary.hue <= 35, "warm: \(dark.primary.hue)")
        let bright = LightPalette.fromAudio(bassRef: 0.1, midRef: 0.4)
        XCTAssertTrue(bright.primary.hue >= 170 && bright.primary.hue <= 230, "cool: \(bright.primary.hue)")
        let middle = LightPalette.fromAudio(bassRef: 0.2, midRef: 0.1)
        XCTAssertTrue(middle.primary.hue <= 35 || middle.primary.hue >= 270, "a little dark: \(middle.primary.hue)")
        XCTAssertTrue(dark.describe("x").hasSuffix("from audio (vivid 0 %)"))
    }

    func testPastelCoversGetTheSaturationFloor() {
        guard let p = LightPalette.fromCover(rgba: image((255, 200, 200)), width: 48, height: 48) else { return XCTFail("none") }
        near(p.primary.hue, 0, 3)
        XCTAssertEqual(p.primary.saturation, LightPalette.minSaturation, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(p.secondary.saturation, LightPalette.minSaturation)
    }

    func testChorusColourIsHalfWayToTheSecondaryAtFullSaturation() {
        let p = LightPalette(primary: LightColour(hue: 0, saturation: 0.8), secondary: LightColour(hue: 100, saturation: 0.8),
                             source: .cover, vivid: 0.5)
        XCTAssertEqual(p.colour(chorus: 0), p.primary)
        let c = p.colour(chorus: 1)
        XCTAssertEqual(c.hue, 50, accuracy: 1e-9)
        XCTAssertEqual(c.saturation, 1, accuracy: 1e-9)
        /* the short way round */
        XCTAssertEqual(LightColour.mix(LightColour(hue: 350, saturation: 1), LightColour(hue: 10, saturation: 1), 0.5).hue, 0, accuracy: 1e-9)
    }

    func testColourModeFromThePage() {
        XCTAssertEqual(LightMusicSettings(["colourMode": "song"]).mode, .song)
        XCTAssertEqual(LightMusicSettings(["colourMode": "fixed", "hue": 120]).mode, .fixed)
        XCTAssertEqual(LightMusicSettings(["hue": 120]).mode, .fixed)
        XCTAssertEqual(LightMusicSettings(["hue": -1]).mode, .drift)
        XCTAssertEqual(LightMusicSettings([:]).mode, .drift)
        XCTAssertEqual(LightMusicSettings(["colourMode": "drift", "hue": 120]).mode, .drift)

        var s = LightMusicSettings()
        s.colourMode = .drift
        s.hue = 120
        XCTAssertEqual(LightMapper(settings: s).baseHue(0), 0, accuracy: 1e-9, "drift ignores the hue")
    }

    func testMapperUsesTheSongColour() {
        let m = LightMapper(settings: LightMusicSettings())
        m.base = LightColour(hue: 240, saturation: 1)
        var c = (r: 0, g: 0, b: 0)
        for k in 0..<30 { c = m.step(bass: 1, mid: 0, onset: 0, playing: true, time: Double(k) * 0.04) }
        XCTAssertEqual([c.r, c.g, c.b], [0, 0, 255])
        m.base = LightColour(hue: 0, saturation: 0.5)
        c = m.step(bass: 1, mid: 0, onset: 0, playing: true, time: 2)
        XCTAssertEqual(c.r, 255)
        XCTAssertLessThanOrEqual(abs(c.g - 128), 1)
    }
}

/// Loud sections and the colour shown from frame to frame.
final class LightSongColourTests: XCTestCase {
    let red = LightPalette(primary: LightColour(hue: 0, saturation: 1), secondary: LightColour(hue: 60, saturation: 1), source: .cover, vivid: 1)
    let green = LightPalette(primary: LightColour(hue: 120, saturation: 1), secondary: LightColour(hue: 180, saturation: 1), source: .cover, vivid: 1)
    let drift = LightColour(hue: 300, saturation: 1)

    func testLoudSectionsOfASyntheticSong() {
        /* a minute: quiet, except a loud part from 20 to 30 s */
        let n = 3000
        let bass = (0..<n).map { k -> Float in (k >= 1000 && k < 1500) ? 1.0 : 0.2 }
        let e = LightEnvelope(bass: bass, mid: bass, onset: [Float](repeating: 0, count: n), bassRef: 1, midRef: 1, onsetRef: 1)
        let flags = e.sections()
        XCTAssertEqual(flags.count, n)
        XCTAssertTrue(flags[1250], "inside the loud part")
        XCTAssertFalse(flags[250])
        XCTAssertFalse(flags[2500])
        let share = Double(flags.filter { $0 }.count) / Double(n)
        XCTAssertLessThanOrEqual(share, 0.26)
        XCTAssertEqual(LightEnvelope(bass: [], mid: [], onset: [], bassRef: 0, midRef: 0, onsetRef: 0).sections(), [])
    }

    func testSectionGlidesOverTwoSeconds() {
        let sc = LightSongColour()
        for _ in 0..<25 { _ = sc.step([.init(id: "a", palette: red, inSection: true, weight: 1)], dt: 0.04, fallback: drift) }
        XCTAssertEqual(sc.chorusAmount("a"), 0.5, accuracy: 1e-9)
        for _ in 0..<50 { _ = sc.step([.init(id: "a", palette: red, inSection: true, weight: 1)], dt: 0.04, fallback: drift) }
        XCTAssertEqual(sc.chorusAmount("a"), 1, accuracy: 1e-9)
        let shown = sc.step([.init(id: "a", palette: red, inSection: true, weight: 1)], dt: 100, fallback: drift)
        XCTAssertEqual(shown.hue, 30, accuracy: 1e-6, "half way to the secondary")
    }

    func testDuringAMixTheColoursBlendByLevel() {
        let sc = LightSongColour()
        let even = sc.step([.init(id: "a", palette: red, inSection: false, weight: 0.5),
                            .init(id: "b", palette: green, inSection: false, weight: 0.5)], dt: 100, fallback: drift)
        XCTAssertEqual(even.hue, 60, accuracy: 1e-6)
        let late = sc.step([.init(id: "a", palette: red, inSection: false, weight: 0.25),
                            .init(id: "b", palette: green, inSection: false, weight: 0.75)], dt: 100, fallback: drift)
        XCTAssertEqual(late.hue, 90, accuracy: 1e-6)
    }

    func testSongChangeGlidesInAboutThreeSeconds() {
        let sc = LightSongColour()
        _ = sc.step([.init(id: "a", palette: red, inSection: false, weight: 1)], dt: 100, fallback: drift)
        var shown = LightColour(hue: 0, saturation: 1)
        for _ in 0..<12 { shown = sc.step([.init(id: "b", palette: green, inSection: false, weight: 1)], dt: 0.04, fallback: drift) }
        XCTAssertGreaterThan(shown.hue, 10, "moving after half a second")
        XCTAssertLessThan(shown.hue, 60, "but far from there")
        for _ in 12..<75 { shown = sc.step([.init(id: "b", palette: green, inSection: false, weight: 1)], dt: 0.04, fallback: drift) }
        XCTAssertEqual(shown.hue, 120, accuracy: 7, "about there after 3 s")
    }

    func testWithoutAPaletteTheColourStaysOrDrifts() {
        let sc = LightSongColour()
        let first = sc.step([.init(id: "a", palette: nil, inSection: false, weight: 1)], dt: 0.04, fallback: drift)
        XCTAssertEqual(first.hue, 300, accuracy: 1e-9, "the drifting hue until a palette is known")
        let moved = sc.step([.init(id: "a", palette: nil, inSection: false, weight: 1)], dt: 0.04,
                            fallback: LightColour(hue: 310, saturation: 1))
        XCTAssertGreaterThan(moved.hue, 300)
        _ = sc.step([.init(id: "a", palette: red, inSection: false, weight: 1)], dt: 100, fallback: drift)
        let kept = sc.step([.init(id: "b", palette: nil, inSection: false, weight: 1)], dt: 1, fallback: drift)
        XCTAssertEqual(kept.hue, 0, accuracy: 1e-6, "the previous song's colour until the new one is known")
    }
}

/// The user's saturation factor, applied last.
final class LightSaturationTests: XCTestCase {
    private func frames(_ saturation: Double?, base: LightColour?, hue: Double = 0, level: Double = 1) -> [(r: Int, g: Int, b: Int)] {
        var s = LightMusicSettings()
        s.hue = hue
        s.level = level
        if let f = saturation { s.saturation = f }
        let m = LightMapper(settings: s)
        m.base = base
        var out: [(r: Int, g: Int, b: Int)] = []
        for k in 0..<120 {
            out.append(m.step(bass: k % 7 < 3 ? 1.2 : 0.1, mid: k % 5 == 0 ? 1 : 0.3, onset: k % 11 == 0 ? 1 : 0,
                              playing: true, time: Double(k) * 0.04))
        }
        return out
    }

    func testFactorOneChangesNothing() {
        XCTAssertEqual(LightMusicSettings().saturation, 1)
        XCTAssertEqual(LightMusicSettings(["saturation": 0.4]).saturation, 0.4)
        XCTAssertEqual(LightMusicSettings(["saturation": 3]).saturation, 1)
        for base in [nil, LightColour(hue: 200, saturation: 0.8)] {
            let before = frames(nil, base: base, hue: 30)
            let now = frames(1, base: base, hue: 30)
            XCTAssertEqual(before.map { [$0.r, $0.g, $0.b] }, now.map { [$0.r, $0.g, $0.b] })
        }
        /* outputs of the earlier tests */
        var s = LightMusicSettings()
        s.hue = 0
        s.level = 0.6
        s.saturation = 1
        let m = LightMapper(settings: s)
        var c = (r: 0, g: 0, b: 0)
        for k in 0..<60 { c = m.step(bass: 1.5, mid: 0, onset: 0, playing: true, time: Double(k) * 0.04) }
        XCTAssertEqual([c.r, c.g, c.b], [153, 0, 0])
    }

    func testFactorZeroIsWhiteAtTheSameBrightness() {
        let colour = frames(1, base: LightColour(hue: 120, saturation: 1))
        let white = frames(0, base: LightColour(hue: 120, saturation: 1))
        for (a, b) in zip(colour, white) {
            XCTAssertEqual(b.r, b.g)
            XCTAssertEqual(b.g, b.b)
            XCTAssertEqual(max(a.r, a.g, a.b), max(b.r, b.g, b.b), "brightness unchanged")
        }
    }

    func testHalfHalvesTheSaturationOfAPureHue() {
        var s = LightMusicSettings()
        s.hue = 0
        s.saturation = 0.5
        let m = LightMapper(settings: s)
        var c = (r: 0, g: 0, b: 0)
        for k in 0..<60 { c = m.step(bass: 1.5, mid: 0, onset: 0, playing: true, time: Double(k) * 0.04) }
        let hsv = LightPalette.hsv(r: Double(c.r) / 255, g: Double(c.g) / 255, b: Double(c.b) / 255)
        XCTAssertEqual(hsv.s, 0.5, accuracy: 0.01)
        XCTAssertEqual(c.r, 255)
        for f in [0.25, 0.5, 0.75] {
            let a = frames(1, base: nil, hue: 240)
            let b = frames(f, base: nil, hue: 240)
            for (x, y) in zip(a, b) { XCTAssertEqual(max(x.r, x.g, x.b), max(y.r, y.g, y.b)) }
        }
    }
}

/// How much the light follows the music.
final class LightIntensityTests: XCTestCase {
    private func run(_ k: Double?, base: LightColour? = nil, frames: Int = 250) -> [(r: Int, g: Int, b: Int)] {
        var s = LightMusicSettings()
        s.hue = 30
        if let k = k { s.intensity = k }
        let m = LightMapper(settings: s)
        m.base = base
        var out: [(r: Int, g: Int, b: Int)] = []
        for i in 0..<frames {
            /* a pulsing song: beats every 0.5 s, busy upper range, onsets on the beats */
            let beat = i % 12 < 3
            out.append(m.step(bass: beat ? 1.3 : 0.05, mid: i % 4 == 0 ? 1 : 0.2, onset: i % 12 == 0 ? 1 : 0,
                              playing: true, time: Double(i) * 0.04))
        }
        return out
    }

    func testIntensityOneChangesNothing() {
        XCTAssertEqual(LightMusicSettings().intensity, 1)
        XCTAssertEqual(LightMusicSettings(["intensity": 0.3]).intensity, 0.3)
        XCTAssertEqual(LightMusicSettings(["intensity": -2]).intensity, 0)
        for base in [nil, LightColour(hue: 200, saturation: 0.8)] {
            let before = run(nil, base: base)
            let now = run(1, base: base)
            XCTAssertEqual(before.map { [$0.r, $0.g, $0.b] }, now.map { [$0.r, $0.g, $0.b] })
        }
        XCTAssertEqual(LightMapper.output(curve: 0.37, level: 0.8, floor: 0.12, intensity: 1),
                       LightMapper.output(curve: 0.37, level: 0.8, floor: 0.12))
    }

    func testIntensityZeroIsSteady() {
        let out = run(0, base: LightColour(hue: 200, saturation: 1))
        let first = out[0]
        for c in out {
            XCTAssertEqual(max(c.r, c.g, c.b), 255, "steady at the level")
            XCTAssertEqual([c.r, c.g, c.b], [first.r, first.g, first.b], "no hue nudge, no lift")
        }
        /* nothing to send after the first frame: ten seconds of a pulsing song, a fixed palette */
        let palette = LightPalette(primary: LightColour(hue: 200, saturation: 0.9), secondary: LightColour(hue: 260, saturation: 0.9),
                                   source: .cover, vivid: 1)
        var s = LightMusicSettings()
        s.colourMode = .song
        s.intensity = 0
        let m = LightMapper(settings: s)
        let colour = LightSongColour()
        let gate = LightChangeGate()
        var sends = 0
        for i in 0..<250 {
            let loud = i >= 100 && i < 200   // a loud section in the middle
            m.base = colour.step([.init(id: "a", palette: palette, inSection: loud, weight: 1)], dt: 0.04,
                                 fallback: palette.primary, intensity: 0)
            let c = m.step(bass: i % 12 < 3 ? 1.3 : 0.05, mid: i % 4 == 0 ? 1 : 0.2, onset: i % 12 == 0 ? 1 : 0,
                           playing: true, time: Double(i) * 0.04)
            if gate.admit(c) && i > 0 { sends += 1 }
        }
        XCTAssertEqual(sends, 0)
    }

    func testIntensityHalfHalvesTheBrightnessSwing() {
        func swing(_ out: [(r: Int, g: Int, b: Int)]) -> Int {
            let peaks = out.dropFirst(50).map { max($0.r, $0.g, $0.b) }
            return (peaks.max() ?? 0) - (peaks.min() ?? 0)
        }
        let full = swing(run(1))
        let half = swing(run(0.5))
        XCTAssertGreaterThan(full, 100)
        XCTAssertEqual(Double(half), Double(full) / 2, accuracy: 3)
        XCTAssertEqual(LightMapper.output(curve: 0, level: 1, floor: 0.12, intensity: 0.5), 0.56, accuracy: 1e-12)
        XCTAssertEqual(LightMapper.output(curve: 0, level: 0.7, floor: 0.12, intensity: 0), 0.7, accuracy: 1e-12)
    }
}

/// Split zones: upper lights follow the melody, the footwell the bass.
final class LightSplitTests: XCTestCase {
    private func split(intensity: Double = 1) -> LightSplitMapper {
        var s = LightMusicSettings()
        s.zones = .split
        s.intensity = intensity
        return LightSplitMapper(settings: s)
    }
    let blue = LightColour(hue: 220, saturation: 1)
    let orange = LightColour(hue: 30, saturation: 1)

    func testZonesFromThePage() {
        XCTAssertEqual(LightMusicSettings([:]).zones, .all)
        XCTAssertEqual(LightMusicSettings(["zones": "split"]).zones, .split)
        XCTAssertEqual(LightMusicSettings(["zones": "both"]).zones, .all)
    }

    func testUpperIgnoresBassPulses() {
        let m = split()
        var uppers: [Int] = []
        for k in 0..<200 {
            let out = m.step(bass: k % 12 < 3 ? 1.3 : 0.05, mid: 0.6, onset: k % 12 == 0 ? 1 : 0, playing: true,
                             time: Double(k) * 0.04, upperBase: blue, footBase: orange)
            if k > 60 { uppers.append(max(out.upper.r, out.upper.g, out.upper.b)) }
        }
        XCTAssertEqual(uppers.max(), uppers.min(), "steady melody, steady upper lights")
    }

    func testFootwellIgnoresTheUpperRange() {
        let m = split()
        var feet: [[Int]] = []
        for k in 0..<200 {
            let out = m.step(bass: 0.7, mid: k % 4 == 0 ? 1.2 : 0.1, onset: 0, playing: true,
                             time: Double(k) * 0.04, upperBase: blue, footBase: orange)
            if k > 60 { feet.append([out.foot.r, out.foot.g, out.foot.b]) }
        }
        XCTAssertEqual(Set(feet.map { "\($0)" }).count, 1, "steady bass, steady footwell (brightness and colour)")
    }

    func testEachZoneHasItsOwnColourAndCurve() {
        let m = split()
        var out = m.step(bass: 0, mid: 0, onset: 0, playing: true, time: 0, upperBase: blue, footBase: orange)
        for k in 1..<40 { out = m.step(bass: 1, mid: 0, onset: 0, playing: true, time: Double(k) * 0.04, upperBase: blue, footBase: orange) }
        XCTAssertGreaterThan(out.foot.r, out.foot.b, "footwell orange")
        XCTAssertGreaterThan(out.upper.b, out.upper.r, "upper blue")
        XCTAssertEqual(m.upper.shapeOverride, LightSplitMapper.upperShape(.beat))
        XCTAssertEqual(LightSplitMapper.upperShape(.beat).attack, 0.06)
        XCTAssertEqual(LightSplitMapper.upperShape(.beat).release, 0.4)
        XCTAssertEqual(LightSplitMapper.upperShape(.beat).lift, 0)
        /* the bass pushed the footwell up, the upper lights sit at the floor */
        XCTAssertGreaterThan(max(out.foot.r, out.foot.g, out.foot.b), max(out.upper.r, out.upper.g, out.upper.b) * 3)
    }

    func testIntensityZeroKeepsBothSteadyAtTheLevel() {
        let m = split(intensity: 0)
        for k in 0..<150 {
            let out = m.step(bass: k % 12 < 3 ? 1.3 : 0.05, mid: k % 4 == 0 ? 1 : 0.2, onset: k % 12 == 0 ? 1 : 0,
                             playing: true, time: Double(k) * 0.04, upperBase: blue, footBase: orange)
            XCTAssertEqual(max(out.upper.r, out.upper.g, out.upper.b), 255)
            XCTAssertEqual(max(out.foot.r, out.foot.g, out.foot.b), 255)
        }
    }

    func testEachZoneHasItsOwnSendThreshold() {
        let upper = LightChangeGate(), foot = LightChangeGate()
        XCTAssertTrue(upper.admit((r: 10, g: 10, b: 10)))
        XCTAssertTrue(foot.admit((r: 10, g: 10, b: 10)), "the other zone has not sent anything yet")
        XCTAssertFalse(upper.admit((r: 11, g: 10, b: 10)))
        XCTAssertTrue(foot.admit((r: 12, g: 10, b: 10)))
        XCTAssertEqual(upper.change((r: 30, g: 10, b: 10)), 20)
        XCTAssertEqual(LightChangeGate().change((r: 0, g: 0, b: 0)), 255)
    }

    func testABusyLinkGetsTheLargerChangeFirst() {
        XCTAssertEqual(LightZoneOrder.order([(command: "<10010203>", change: 3), (command: "<09ff0000>", change: 90)]),
                       ["<09ff0000>", "<10010203>"])
        XCTAssertEqual(LightZoneOrder.order([(command: "a", change: 5), (command: "b", change: 5)]), ["a", "b"], "ties keep their order")
    }

    func testFootColourIsTheSecondaryOrTheTurnedPrimary() {
        let two = LightPalette(primary: LightColour(hue: 200, saturation: 0.8), secondary: LightColour(hue: 260, saturation: 0.9),
                               source: .cover, vivid: 1)
        XCTAssertEqual(two.footColour(chorus: 0).hue, 260, accuracy: 1e-9)
        XCTAssertEqual(two.footColour(chorus: 1).saturation, 1, accuracy: 1e-9)
        let same = LightPalette(primary: LightColour(hue: 200, saturation: 0.8), secondary: LightColour(hue: 200, saturation: 0.8),
                                source: .cover, vivid: 1)
        XCTAssertEqual(same.footColour(chorus: 0).hue, 215, accuracy: 1e-9)
        let sc = LightSongColour(footwell: true)
        let shown = sc.step([.init(id: "a", palette: two, inSection: false, weight: 1)], dt: 100, fallback: LightColour(hue: 0, saturation: 1))
        XCTAssertEqual(shown.hue, 260, accuracy: 1e-6)
    }
}

