import XCTest
import LightCore
import SoundCore

/// The controller's frames, the commands sent around taking it over, and the user's settings.
final class LightStateTests: XCTestCase {
    /// A real state frame from the car (0.8 test).
    let stateFrame = "<4E001801FFFFFFFFFFFF03030505000305>"
    /// A real settings frame from the car (0.8 test).
    let settingsFrame = "<2601FFFFFFFFFF00000009FF0000>"

    func testStateFrameFromTheCar() {
        guard let s = LightState(frame: stateFrame) else { return XCTFail("not read") }
        XCTAssertEqual(s.type, 0x4E)
        XCTAssertEqual(s.rgbMode, 0x00)
        XCTAssertEqual(s.symphonyMode, 0x18)
        XCTAssertTrue(s.powerOn)
        XCTAssertEqual([s.r, s.g, s.b], [0xFF, 0xFF, 0xFF])
        XCTAssertEqual(s.globalBrightness, 0x03)
        XCTAssertEqual(s.singleColourCommand, "<0400>")
    }

    func testSettingsFrameFromTheCarHasNoSoundInput() {
        guard let s = LightSettingsFrame(frame: settingsFrame) else { return XCTFail("not read") }
        XCTAssertEqual(s.soundInput, 0xFF)
        XCTAssertFalse(s.hasSoundInput)
        XCTAssertNil(LightState(frame: settingsFrame))
        XCTAssertNil(LightSettingsFrame(frame: stateFrame))
    }

    func testOtherAndBrokenFramesAreNotStates() {
        XCTAssertNil(LightState(frame: "<1301020304>"))
        XCTAssertNil(LightState(frame: "<4E0018>"))
        XCTAssertNil(LightState(frame: "<4E0018zz>"))
        XCTAssertNil(lightFrameBytes("<4E0>"))
        XCTAssertEqual(lightFrameBytes("<0aFF>"), [0x0A, 0xFF])
        XCTAssertEqual(LightState(frame: "<12001801FFFFFFFFFFFF03030505000305>")?.singleColourCommand, "<0800>")
    }

    func testStartCommands() {
        /* the car's frame is already in single-colour mode (mode byte 00) */
        let on = LightState(frame: stateFrame)
        XCTAssertEqual(LightSession.startCommands(on), ["<020009>"])
        let off = LightState(frame: "<4E001800102030FFFFFF03030505000705>")
        XCTAssertEqual(LightSession.startCommands(off), ["<0701>", "<020009>"])
        let other = LightState(frame: "<4E021801102030FFFFFF03030505000705>")
        XCTAssertEqual(LightSession.startCommands(other), ["<0400>", "<020009>"])
        XCTAssertEqual(LightSession.startCommands(nil), ["<0400>", "<020009>"])
    }

    func testRestoreCommandsNeverAskForMoreThanNine() {
        /* brightness first, the colour last (the controller keeps the last colour) */
        XCTAssertEqual(LightSession.restoreCommands(LightState(frame: stateFrame)), ["<020003>", "<06ffffff>"])
        let bright = LightState(frame: "<4E001801102030FFFFFF0303050500FF05>")
        XCTAssertEqual(LightSession.restoreCommands(bright), ["<020009>", "<06102030>"])
        let off = LightState(frame: "<4E001800102030FFFFFF03030505000705>")
        XCTAssertEqual(LightSession.restoreCommands(off), ["<020007>", "<06102030>", "<0700>"])
        XCTAssertEqual(LightSession.restoreCommands(nil), [])
        for c in LightSession.startCommands(nil) + LightSession.restoreCommands(bright) where c.hasPrefix("<0200") {
            let value = Int(c.dropFirst(5).dropLast(), radix: 16) ?? 99
            XCTAssertLessThanOrEqual(value, 9)
        }
    }

    func testSettingsFromThePage() {
        let s = LightMusicSettings(["on": true, "style": "colour", "level": 0.5, "floor": 0.2, "hue": 200, "offsetMs": 120])
        XCTAssertTrue(s.on)
        XCTAssertEqual(s.style, .colour)
        XCTAssertEqual(s.level, 0.5)
        XCTAssertEqual(s.floor, 0.2)
        XCTAssertEqual(s.hue, 200)
        XCTAssertEqual(s.offsetMs, 120)

        let wild = LightMusicSettings(["on": true, "style": "disco", "level": 7, "floor": -1, "hue": -5, "offsetMs": 9000])
        XCTAssertEqual(wild.style, .beat)
        XCTAssertEqual(wild.level, 1)
        XCTAssertEqual(wild.floor, 0)
        XCTAssertEqual(wild.hue, -1)
        XCTAssertEqual(wild.offsetMs, 500)
        XCTAssertEqual(LightMusicSettings(["level": 0.01, "offsetMs": -900]).level, 0.1)
        XCTAssertEqual(LightMusicSettings(["offsetMs": -900]).offsetMs, -300)
        /* the floor never above the level */
        XCTAssertEqual(LightMusicSettings(["level": 0.2, "floor": 0.5]).floor, 0.2)

        let none = LightMusicSettings([:])
        XCTAssertEqual(none, LightMusicSettings())
        XCTAssertFalse(none.on)
        XCTAssertEqual(none.style, .beat)
        XCTAssertEqual(none.floor, 0.12)
    }
}

/// Music to colour.
final class LightMapperTests: XCTestCase {
    private func mapper(_ style: LightStyle = .beat, level: Double = 1, floor: Double = 0.12, hue: Double = 0) -> LightMapper {
        var s = LightMusicSettings()
        s.on = true
        s.style = style
        s.level = level
        s.floor = floor
        s.hue = hue
        return LightMapper(settings: s)
    }

    private func run(_ m: LightMapper, bass: Double, frames: Int, mid: Double = 0, onset: Double = 0,
                     playing: Bool = true, from t0: Double = 0) -> (r: Int, g: Int, b: Int) {
        var c = (r: 0, g: 0, b: 0)
        for k in 0..<frames {
            c = m.step(bass: bass, mid: mid, onset: onset, playing: playing, time: t0 + Double(k) * 0.04)
        }
        return c
    }

    func testOutputKeepsFloorAndLevelVisibleAndShapesOnlyTheMusic() {
        XCTAssertEqual(LightMapper.output(curve: 0, level: 1, floor: 0.12), 0.12, accuracy: 1e-12)
        XCTAssertEqual(LightMapper.output(curve: 1, level: 1, floor: 0.12), 1, accuracy: 1e-12)
        XCTAssertEqual(LightMapper.output(curve: 1, level: 0.5, floor: 0.12), 0.5, accuracy: 1e-12)
        /* gamma 2.2 on the music curve: half way is about a fifth of the way up */
        XCTAssertEqual(LightMapper.output(curve: 0.5, level: 1, floor: 0), pow(0.5, 2.2), accuracy: 1e-12)
        XCTAssertEqual(LightMapper.output(curve: 0.5, level: 0.8, floor: 0.2), 0.8 * (0.2 + 0.8 * pow(0.5, 2.2)), accuracy: 1e-12)
        XCTAssertEqual(LightMapper.rgb(hue: 0, saturation: 1, white: 0, output: 1).r, 255)
        XCTAssertEqual(LightMapper.rgb(hue: 0, saturation: 1, white: 0, output: 0.5).r, 128)
        XCTAssertEqual(LightMapper.rgb(hue: 120, saturation: 1, white: 0, output: 1).g, 255)
        let white = LightMapper.rgb(hue: 0, saturation: 1, white: 1, output: 1)
        XCTAssertEqual([white.r, white.g, white.b], [255, 255, 255])
    }

    func testSilenceAtTheDefaultFloorIsClearlyVisible() {
        let m = mapper(level: 1, floor: 0.12, hue: 200)
        let c = run(m, bass: 0, frames: 60)
        XCTAssertGreaterThanOrEqual(max(c.r, c.g, c.b), 28)
        XCTAssertEqual(m.brightness, 0.12, accuracy: 1e-9)
    }

    func testSilenceSitsOnTheFloor() {
        let m = mapper(floor: 0.3)
        let c = run(m, bass: 0, frames: 60)
        XCTAssertEqual(m.brightness, 0.3, accuracy: 1e-9)
        XCTAssertEqual(c.r, Int((255 * 0.3).rounded()))
        XCTAssertEqual(c.g, 0)
        XCTAssertEqual(c.b, 0)
    }

    func testLoudnessIsCappedAtTheUsersLevel() {
        let m = mapper(level: 0.6)
        let c = run(m, bass: 1.5, frames: 60)
        XCTAssertEqual(m.brightness, 0.6, accuracy: 1e-9)
        XCTAssertEqual(c.r, 153)
        /* and the floor scales with the level */
        let q = mapper(level: 0.5, floor: 0.2)
        _ = run(q, bass: 0, frames: 60)
        XCTAssertEqual(q.brightness, 0.1, accuracy: 1e-9)
    }

    func testFastAttackSlowRelease() {
        let m = mapper(.beat)
        _ = run(m, bass: 0, frames: 30)
        var attack = 0
        while m.curve < 0.9 && attack < 100 {
            _ = m.step(bass: 1, mid: 0, onset: 0, playing: true, time: 0)
            attack += 1
        }
        _ = run(m, bass: 1, frames: 30)
        var release = 0
        while m.curve > 0.1 && release < 100 {
            _ = m.step(bass: 0, mid: 0, onset: 0, playing: true, time: 0)
            release += 1
        }
        XCTAssertLessThanOrEqual(attack, 5, "rises within a fifth of a second")
        XCTAssertGreaterThanOrEqual(release, 8, "falls back over a third of a second or more")
        XCTAssertGreaterThan(release, attack * 2)

        /* The soft style is slower. */
        let soft = mapper(.soft)
        _ = run(soft, bass: 0, frames: 30)
        var softAttack = 0
        while soft.curve < 0.9 && softAttack < 100 {
            _ = soft.step(bass: 1, mid: 0, onset: 0, playing: true, time: 0)
            softAttack += 1
        }
        XCTAssertGreaterThan(softAttack, attack)
    }

    func testTheMusicCurveNeverJumpsMoreThanTheLimitPerFrame() {
        for style in [LightStyle.soft, .beat, .colour] {
            let m = mapper(style)
            var last = m.curve
            var biggest = 0.0
            for k in 0..<200 {
                _ = m.step(bass: k % 2 == 0 ? 1.5 : 0, mid: k % 3 == 0 ? 1 : 0, onset: k % 5 == 0 ? 1 : 0,
                           playing: k < 150, time: Double(k) * 0.04)
                biggest = max(biggest, abs(m.curve - last))
                last = m.curve
            }
            XCTAssertLessThanOrEqual(biggest, LightMapper.maxStep + 1e-9, "\(style)")
        }
        /* none to full takes at least four frames: no full on/off flicker faster than about 3 Hz */
        XCTAssertGreaterThanOrEqual(1 / LightMapper.maxStep, 4)
    }

    func testOnsetGivesAShortWhiterLift() {
        let m = mapper(.beat)
        _ = run(m, bass: 0.5, frames: 50)
        let before = run(m, bass: 0.5, frames: 1)
        XCTAssertEqual(before.g, 0)
        let hit = m.step(bass: 0.5, mid: 0, onset: 1, playing: true, time: 2)
        XCTAssertGreaterThanOrEqual(hit.g, 5, "toward white")
        XCTAssertGreaterThan(hit.r, before.r, "brighter")
        let later = run(m, bass: 0.5, frames: 4, from: 2.04)   // 160 ms on
        XCTAssertLessThanOrEqual(later.g, 1, "gone within about 150 ms")

        let soft = mapper(.soft)
        _ = run(soft, bass: 0.5, frames: 50)
        XCTAssertEqual(soft.step(bass: 0.5, mid: 0, onset: 1, playing: true, time: 2).g, 0, "no lifts in the soft style")
    }

    func testFixedAndDriftingHue() {
        let blue = mapper(hue: 240)
        let c = run(blue, bass: 1, frames: 30)
        XCTAssertEqual(c.r, 0)
        XCTAssertEqual(c.g, 0)
        XCTAssertEqual(c.b, 255)

        let drift = mapper(hue: -1)
        XCTAssertEqual(drift.baseHue(0), 0, accuracy: 1e-9)
        XCTAssertEqual(drift.baseHue(60), 180, accuracy: 1e-9)
        XCTAssertEqual(drift.baseHue(150), 90, accuracy: 1e-9)
    }

    func testUpperRangeMovesTheColourInTheColourStyle() {
        let calm = mapper(.colour, hue: 0)
        let busy = mapper(.colour, hue: 0)
        let a = run(calm, bass: 1, frames: 60, mid: 0)
        let b = run(busy, bass: 1, frames: 60, mid: 1)
        XCTAssertEqual(a.g, 0)
        XCTAssertGreaterThan(b.g, 100, "turned toward yellow-green and a little paler")
    }

    func testOnlyChangesOfTwoOrMoreAreSent() {
        let gate = LightChangeGate()
        XCTAssertTrue(gate.admit((10, 10, 10)))
        XCTAssertFalse(gate.admit((10, 10, 10)))
        XCTAssertFalse(gate.admit((11, 9, 11)))
        XCTAssertTrue(gate.admit((12, 10, 10)))
        XCTAssertFalse(gate.admit((13, 11, 11)), "measured against what was sent last")
        XCTAssertTrue(gate.admit((12, 10, 8)))
        gate.reset()
        XCTAssertTrue(gate.admit((12, 10, 8)))
    }

    func testColourCommandsFromTheMapper() {
        let m = mapper(level: 0.6, hue: 0)
        let c = run(m, bass: 1.5, frames: 60)
        XCTAssertEqual(LightCommand.color(r: c.r, g: c.g, b: c.b), "<06990000>")   // 255 * 0.6 = 153
        XCTAssertEqual(LightCommand.bytes("<06530000>").count, 10)
        XCTAssertLessThanOrEqual(LightCommand.bytes("<06ffffff>").count, 20, "fits one write without response")
    }
}

/// The music's values for the light: per song, looked up by position, mixed by level.
final class LightEnvelopeTests: XCTestCase {
    private func ramp(_ n: Int) -> LightEnvelope {
        let up = (0..<n).map { Float($0) }
        return LightEnvelope(bass: up, mid: up.map { $0 * 2 }, onset: up.map { _ in 0.5 },
                             bassRef: 1, midRef: 2, onsetRef: 0.25)
    }

    func testLookupIsNormalisedAndInterpolated() {
        let e = ramp(500)   // ten seconds
        XCTAssertEqual(e.duration, 10, accuracy: 1e-9)
        let a = e.sample(at: 1.0)
        XCTAssertEqual(a.bass, 50, accuracy: 1e-6)
        XCTAssertEqual(a.mid, 50, accuracy: 1e-6)
        XCTAssertEqual(a.onset, 2, accuracy: 1e-6)
        XCTAssertEqual(e.sample(at: 1.01).bass, 50.5, accuracy: 1e-4)
        XCTAssertEqual(e.sample(at: -0.1).bass, 0)
        XCTAssertEqual(e.sample(at: 20).bass, 0)
    }

    func testLookupGoesBackByLatencyAndOffset() {
        let e = ramp(1000)
        /* player said 10.0 s, 0.1 s ago; 50 ms to the speaker; the user wants the light 200 ms later */
        let heard = LightTiming.heardPosition(reported: 10, elapsed: 0.1, playing: true, latency: 0.05, offsetMs: 200)
        XCTAssertEqual(heard, 9.85, accuracy: 1e-9)
        XCTAssertEqual(e.sample(at: heard).bass, 492.5, accuracy: 1e-3)
        /* paused: the clock does not run on; a negative offset moves the light earlier */
        XCTAssertEqual(LightTiming.heardPosition(reported: 10, elapsed: 3, playing: false, latency: 0, offsetMs: -100), 10.1, accuracy: 1e-9)
    }

    func testOneSongAloneHasFullWeight() {
        let v = LightTiming.voices(current: "a", position: 30, plan: nil, incoming: nil)
        XCTAssertEqual(v, [LightTiming.Voice(id: "a", position: 30, weight: 1)])
        let plan = MixPlan(startA: 100, overlap: 10, end: 112, bOffset: 5, bDelay: 0, synced: false)
        XCTAssertEqual(LightTiming.voices(current: "a", position: 95, plan: plan, incoming: "b"),
                       [LightTiming.Voice(id: "a", position: 95, weight: 1)])
    }

    func testDuringAMixBothSongsCountByTheirLevels() {
        let plan = MixPlan(startA: 100, overlap: 10, end: 112, bOffset: 5, bDelay: 1, synced: false)
        let v = LightTiming.voices(current: "a", position: 105, plan: plan, incoming: "b")
        XCTAssertEqual(v.count, 2)
        XCTAssertEqual(v[0].id, "a")
        XCTAssertEqual(v[0].weight, MixCurve.outgoingGain(0.5), accuracy: 1e-9)
        XCTAssertEqual(v[1].id, "b")
        XCTAssertEqual(v[1].position, 9, accuracy: 1e-9)   // bOffset 5 + (105 - 100 - 1)
        XCTAssertEqual(v[1].weight, MixCurve.incomingGain(0.5, synced: false), accuracy: 1e-9)
        /* not started yet */
        XCTAssertEqual(LightTiming.voices(current: "a", position: 100.5, plan: plan, incoming: "b").count, 1)
        /* the outgoing song is gone after the overlap */
        let after = LightTiming.voices(current: "a", position: 111, plan: plan, incoming: "b")
        XCTAssertEqual(after.map { $0.id }, ["b"])

        let mixed = LightTiming.combine([(values: (bass: 1, mid: 0, onset: 0), weight: 1),
                                         (values: (bass: 0, mid: 1, onset: 0), weight: 3)])
        XCTAssertEqual(mixed.bass, 0.25, accuracy: 1e-9)
        XCTAssertEqual(mixed.mid, 0.75, accuracy: 1e-9)
        let silent = LightTiming.combine([])
        XCTAssertEqual(silent.bass, 0)
    }

    func testMakerSeparatesBassFromTheUpperRange() {
        let rate = 44100.0
        func tone(_ hz: Double, seconds: Double) -> LightEnvelope {
            let n = Int(rate * seconds)
            let x = (0..<n).map { Float(0.5 * sin(2 * Double.pi * hz * Double($0) / rate)) }
            let maker = LightEnvelopeMaker(sampleRate: rate)
            var at = 0
            while at < n {   // in pieces, as the decoder gives them
                let end = min(n, at + 4096)
                maker.add(left: Array(x[at..<end]), right: Array(x[at..<end]))
                at = end
            }
            return maker.finish()
        }
        let low = tone(80, seconds: 2)
        let high = tone(3000, seconds: 2)
        XCTAssertEqual(low.bass.count, 100)
        XCTAssertGreaterThan(low.bassRef, 0.2)
        XCTAssertLessThan(low.midRef, 0.01)
        XCTAssertGreaterThan(high.midRef, 0.2)
        XCTAssertLessThan(high.bassRef, 0.01)
        /* steady tone: normalised values about 1 */
        XCTAssertEqual(low.sample(at: 1).bass, 1, accuracy: 0.15)
    }

    func testOnsetMarksASuddenStart() {
        let rate = 44100.0
        let n = Int(rate * 2)
        let x = (0..<n).map { i -> Float in i < n / 2 ? 0.001 : Float(0.5 * sin(2 * Double.pi * 100 * Double(i) / rate)) }
        let maker = LightEnvelopeMaker(sampleRate: rate)
        maker.add(left: x, right: x)
        let e = maker.finish()
        let peak = e.onset.indices.max { e.onset[$0] < e.onset[$1] } ?? 0
        XCTAssertEqual(peak, 50)
    }

    func testFileRoundTrip() {
        let e = ramp(123)
        XCTAssertEqual(LightEnvelope(data: e.data()), e)
        XCTAssertNil(LightEnvelope(data: Data([1, 2, 3])))
        XCTAssertNil(LightEnvelope(data: e.data().prefix(40)))
    }
}

/// When the music light drives the controller and when it hands it back.
final class LightIdleTests: XCTestCase {
    let own = LightState(frame: "<4E001801FFFFFFFFFFFF03030505000305>")

    func testNothingIsSentUntilMusicPlays() {
        let idle = LightIdle(original: own)
        for k in 0..<100 { XCTAssertEqual(idle.step(playing: false, now: Double(k) * 0.04), .none) }
        XCTAssertFalse(idle.holding)
        XCTAssertEqual(idle.step(playing: true, now: 4), .takeOver(["<020009>"]))
        XCTAssertTrue(idle.holding)
        XCTAssertEqual(idle.step(playing: true, now: 4.04), .music)
    }

    func testShortPausesKeepTheMusicLight() {
        let idle = LightIdle(original: own)
        _ = idle.step(playing: true, now: 10)
        idle.lastColour = (r: 200, g: 0, b: 0)
        XCTAssertEqual(idle.step(playing: false, now: 11), .none)
        XCTAssertEqual(idle.step(playing: false, now: 13.9), .none)
        XCTAssertEqual(idle.step(playing: true, now: 13.95), .music, "no second take-over")
        XCTAssertEqual(idle.phase, .music)
    }

    func testStoppedMusicFadesBackToTheOwnStateThenRests() {
        let idle = LightIdle(original: own)
        _ = idle.step(playing: true, now: 10)
        idle.lastColour = (r: 200, g: 0, b: 0)
        XCTAssertEqual(idle.step(playing: false, now: 11), .none)
        XCTAssertEqual(idle.step(playing: false, now: 13.9), .none, "waits 3 s")
        XCTAssertEqual(idle.step(playing: false, now: 14.0), .fade("<06c80000>"))
        XCTAssertEqual(idle.step(playing: false, now: 14.5), .fade("<06e48080>"))
        /* brightness, then the user's colour last */
        XCTAssertEqual(idle.step(playing: false, now: 15.0), .restore(["<020003>", "<06ffffff>"]))
        XCTAssertFalse(idle.holding)
        XCTAssertEqual(idle.step(playing: false, now: 16), .none)
        XCTAssertEqual(idle.step(playing: true, now: 20), .takeOver(["<020009>"]), "takes over again")
    }

    func testMusicDuringTheFadeCarriesOn() {
        let idle = LightIdle(original: own)
        _ = idle.step(playing: true, now: 0)
        idle.lastColour = (r: 0, g: 0, b: 200)
        _ = idle.step(playing: false, now: 1)
        _ = idle.step(playing: false, now: 4.1)
        XCTAssertEqual(idle.phase, .fading)
        XCTAssertEqual(idle.step(playing: true, now: 4.3), .music)
    }

    func testWithoutTheOwnStateItJustStopsSending() {
        let idle = LightIdle(original: nil)
        XCTAssertEqual(idle.step(playing: true, now: 0), .takeOver(["<0400>", "<020009>"]))
        _ = idle.step(playing: false, now: 1)
        XCTAssertEqual(idle.step(playing: false, now: 4.5), .restore([]))
        XCTAssertEqual(idle.step(playing: false, now: 5), .none)
    }

    func testLinkLostForgetsTheTakeOver() {
        let idle = LightIdle(original: own)
        _ = idle.step(playing: true, now: 0)
        idle.reset()
        XCTAssertFalse(idle.holding)
        XCTAssertEqual(idle.step(playing: true, now: 1), .takeOver(["<020009>"]))
    }
}

/// A strip effect left running must not survive the music light or the test screen.
final class LightSymphonyTests: XCTestCase {
    let normal = LightState(frame: "<4E001801FFFFFFFFFFFF03030505000305>")
    let leftover = LightState(frame: "<4E000901FFFFFFFFFFFF03030505000305>")

    func testTheFrameCarriesTheEffectAndItsSpeed() {
        XCTAssertEqual(normal?.symphonyMode, 0x18)
        XCTAssertEqual(normal?.symphonySpeed, 0x05)
        XCTAssertEqual(normal?.speed, 0x05)
        XCTAssertEqual(leftover?.symphonyMode, 0x09)
    }

    func testTakeOverSwitchesALeftoverEffectBackToSync() {
        XCTAssertEqual(LightSession.startCommands(normal), ["<020009>"], "Sync RGB already: nothing extra")
        XCTAssertEqual(LightSession.startCommands(leftover), ["<1E18>", "<020009>"])
        XCTAssertEqual(LightSession.symphonyCommand(0x18), "<1E18>")
        XCTAssertEqual(LightSession.symphonyCommand(0x0B), "<1E0B>")
    }

    func testGivingBackRestoresTheEffectOnlyWhenItWasChanged() {
        XCTAssertEqual(LightSession.restoreCommands(normal), ["<020003>", "<06ffffff>"])
        XCTAssertEqual(LightSession.restoreCommands(leftover), ["<1E09>", "<020003>", "<06ffffff>"], "the colour still last")
    }

    func testClosingTheTestScreenPutsTheStripBack() {
        XCTAssertEqual(LightSession.symphonyRestoreCommands(normal), ["<1E18>", "<0B05>"])
        XCTAssertEqual(LightSession.symphonyRestoreCommands(leftover), ["<1E09>", "<0B05>"])
        XCTAssertEqual(LightSession.symphonyRestoreCommands(nil), ["<1E18>"], "unknown: Sync RGB")
        let oddSpeed = LightState(frame: "<4E000901FFFFFFFFFFFF0303050F000305>")
        XCTAssertEqual(LightSession.symphonyRestoreCommands(oddSpeed), ["<1E09>"], "speed outside 01...05 is not sent")
    }

    func testIdleRestoreAfterMusicIncludesTheEffect() {
        let idle = LightIdle(original: leftover)
        XCTAssertEqual(idle.step(playing: true, now: 0), .takeOver(["<1E18>", "<020009>"]))
        idle.lastColour = (r: 255, g: 255, b: 255)
        _ = idle.step(playing: false, now: 1)
        _ = idle.step(playing: false, now: 4.0)
        XCTAssertEqual(idle.step(playing: false, now: 5.0), .restore(["<1E09>", "<020003>", "<06ffffff>"]))
    }
}

