import Foundation

/* Turning music into the car's ambient light: what the controller reports about itself, the
   user's settings, and the pure mapping from the music's values to a colour. No Bluetooth and
   no audio in here, so it can be tested on its own (package target LightCore). */

// MARK: - what the controller reports

/// A frame's bytes: the hex digits between the brackets, two per byte. nil when they are not
/// all hex digits in pairs.
public func lightFrameBytes(_ frame: String) -> [UInt8]? {
    var inner = frame
    if inner.hasPrefix("<") { inner.removeFirst() }
    if inner.hasSuffix(">") { inner.removeLast() }
    let digits = Array(inner)
    if digits.isEmpty || digits.count % 2 != 0 { return nil }
    var out: [UInt8] = []
    var at = 0
    while at < digits.count {
        guard let byte = UInt8(String(digits[at...at + 1]), radix: 16) else { return nil }
        out.append(byte)
        at += 2
    }
    return out
}

/// The controller's state, from its state frame (type 4E on the car's controller). Byte
/// meanings come from the vendor's app and were checked against one real frame:
/// [1] rgb mode, [2] symphony mode, [3] power, [4...6] colour, [15] overall brightness.
public struct LightState: Equatable {
    public let type: UInt8
    public let rgbMode: UInt8
    public let symphonyMode: UInt8
    public let powerOn: Bool
    public let r: UInt8
    public let g: UInt8
    public let b: UInt8
    public let globalBrightness: UInt8
    /// [13] the strip effect's speed (the vendor app's "symphony speed").
    public let symphonySpeed: UInt8
    /// [16] a second speed byte; its meaning is not known.
    public let speed: UInt8?

    /// Reads a state frame; nil for any other frame or one that is too short.
    public init?(frame: String) {
        guard let bytes = lightFrameBytes(frame), bytes.count >= 16,
              [0x12, 0x1F, 0x4E, 0x5A].contains(bytes[0]) else { return nil }
        type = bytes[0]
        rgbMode = bytes[1]
        symphonyMode = bytes[2]
        powerOn = bytes[3] != 0
        r = bytes[4]
        g = bytes[5]
        b = bytes[6]
        globalBrightness = bytes[15]
        symphonySpeed = bytes[13]
        speed = bytes.count > 16 ? bytes[16] : nil
    }

    /// The command for plain single-colour mode: newer firmware (state frames 4E and 5A) knows
    /// "<0400>", older (12, 1F) "<0800>".
    public var singleColourCommand: String {
        return type == 0x4E || type == 0x5A ? "<0400>" : "<0800>"
    }
}

/// The controller's settings frame (type 26). Byte 11 tells whether it has a sound input of
/// its own; FF = none.
public struct LightSettingsFrame: Equatable {
    public let soundInput: UInt8

    public init?(frame: String) {
        guard let bytes = lightFrameBytes(frame), bytes.count >= 12, bytes[0] == 0x26 else { return nil }
        soundInput = bytes[11]
    }

    public var hasSoundInput: Bool { return soundInput != 0xFF }
}

/// What is sent when the music light takes over the controller and when it gives it back.
public enum LightSession {
    /// The highest overall brightness ever sent. The controller only accepts 00 ... 09.
    public static let maxGlobalBrightness = 9
    /// The strip effect "Sync RGB": the strip shows the plain colour. The user's normal state.
    public static let syncSymphony: UInt8 = 0x18

    /// "<1Exx>": select a strip effect.
    public static func symphonyCommand(_ mode: UInt8) -> String {
        return "<1E" + String(format: "%02X", UInt32(mode)) + ">"
    }

    /// After testing strip effects: the effect and its speed as they were. Unknown state:
    /// Sync RGB, the user's normal. Speed only when it is one the controller takes (01 ... 05);
    /// the direction is not in the state frame and is left as it is.
    public static func symphonyRestoreCommands(_ state: LightState?) -> [String] {
        guard let s = state else { return [symphonyCommand(syncSymphony)] }
        var list = [symphonyCommand(s.symphonyMode)]
        if (1...5).contains(s.symphonySpeed) { list.append("<0B" + String(format: "%02X", UInt32(s.symphonySpeed)) + ">") }
        return list
    }

    /// Taking over: power on if it was off, plain single-colour mode unless it is in it
    /// already (mode byte 00), overall brightness to its top, so the colour values alone decide
    /// how bright the light is.
    public static func startCommands(_ state: LightState?) -> [String] {
        var list: [String] = []
        if let s = state, !s.powerOn { list.append("<0701>") }
        /* A strip effect left running (anything but 18 = Sync RGB) would fight the colours. */
        if let s = state, s.symphonyMode != syncSymphony { list.append(symphonyCommand(syncSymphony)) }
        if state == nil || state?.rgbMode != 0 { list.append(state?.singleColourCommand ?? "<0400>") }
        list.append(LightCommand.brightness(maxGlobalBrightness))
        return list
    }

    /// Giving back: the original overall brightness (never above 09), then the original colour
    /// - last, so the colour the controller keeps is the user's own - and power off again if
    /// it was off. Nothing when the original state was never read.
    public static func restoreCommands(_ state: LightState?) -> [String] {
        guard let s = state else { return [] }
        var list: [String] = []
        /* the strip effect it had, if taking over changed it */
        if s.symphonyMode != syncSymphony { list.append(symphonyCommand(s.symphonyMode)) }
        list += [LightCommand.brightness(min(maxGlobalBrightness, Int(s.globalBrightness))),
                 LightCommand.color(r: Int(s.r), g: Int(s.g), b: Int(s.b))]
        if !s.powerOn { list.append("<0700>") }
        return list
    }
}

// MARK: - settings

/// Where the light's colour comes from.
public enum LightColourMode: String {
    case song      // each song's own colour (cover art, otherwise its sound)
    case drift     // one turn round the colour circle every two minutes
    case fixed     // the user's hue
}

/// Which lights follow what: all zones together, or split - the upper lights (zone 1) follow
/// the melody, the footwell (zone 2) the bass.
public enum LightZones: String {
    case all
    case split
}

public enum LightStyle: String {
    case soft      // 柔和: slow and gentle, the light breathes with the bass
    case beat      // 節拍: punchy, driven by the bass, onsets give short lifts
    case colour    // 多彩: the colour itself moves with the upper range

    public struct Shape: Equatable {
        public let attack: Double        // seconds for the level to rise
        public let release: Double       // seconds for it to fall back
        public let contrast: Double      // >1 = more difference between quiet and loud
        public let hueMove: Double       // degrees the upper range turns the colour
        public let lift: Double          // how strongly an onset brightens and whitens

        public init(attack: Double, release: Double, contrast: Double, hueMove: Double, lift: Double) {
            self.attack = attack
            self.release = release
            self.contrast = contrast
            self.hueMove = hueMove
            self.lift = lift
        }
    }

    public var shape: Shape {
        switch self {
        case .soft: return Shape(attack: 0.12, release: 0.6, contrast: 0.8, hueMove: 10, lift: 0)
        case .beat: return Shape(attack: 0.03, release: 0.25, contrast: 1.4, hueMove: 20, lift: 0.25)
        case .colour: return Shape(attack: 0.05, release: 0.3, contrast: 1.0, hueMove: 90, lift: 0.15)
        }
    }
}

/// The user's settings for the music light (the page's `{cmd:'light'}`).
public struct LightMusicSettings: Equatable {
    public var on = false
    public var style = LightStyle.beat
    /// Highest output, 0.1 ... 1 of the controller's full value (see LightMapper).
    public var level = 1.0
    /// Share of the level the light keeps in silence while music plays, 0 ... 0.5 (visible terms).
    public var floor = 0.12
    /// A fixed hue in degrees, or -1 for one that turns slowly round the colour circle.
    public var hue = -1.0
    /// Moves the light later (positive) or earlier, in milliseconds, -300 ... 500.
    public var offsetMs = 0.0
    /// Where the colour comes from; nil = as `hue` says (-1 drift, otherwise fixed).
    public var colourMode: LightColourMode?
    /// The user's saturation factor, 0 ... 1, applied last in every colour mode (1 = the colour
    /// as it comes, 0 = white light at the same brightness).
    public var saturation = 1.0
    /// How much the light follows the music, 0 ... 1: 1 = fully, 0 = steady brightness at
    /// `level` and only the song colours (no section shift, no hue nudge, no onset lift).
    public var intensity = 1.0
    /// All zones together, or upper and footwell separately.
    public var zones = LightZones.all

    /// The colour mode in effect.
    public var mode: LightColourMode {
        if let m = colourMode { return m }
        return hue >= 0 ? .fixed : .drift
    }

    public init() {}

    /// From the page's message; anything missing gets its default, anything out of range its
    /// limit.
    public init(_ message: [String: Any]) {
        func number(_ key: String) -> Double? {
            guard let n = message[key] as? NSNumber, n.doubleValue.isFinite else { return nil }
            return n.doubleValue
        }
        on = (message["on"] as? NSNumber)?.boolValue ?? false
        style = LightStyle(rawValue: message["style"] as? String ?? "") ?? .beat
        level = min(1, max(0.1, number("level") ?? 1))
        floor = min(0.5, max(0, number("floor") ?? 0.12))
        floor = min(floor, level)
        if let h = number("hue"), h >= 0 { hue = h.truncatingRemainder(dividingBy: 360) } else { hue = -1 }
        offsetMs = min(500, max(-300, number("offsetMs") ?? 0))
        colourMode = LightColourMode(rawValue: message["colourMode"] as? String ?? "")
        saturation = min(1, max(0, number("saturation") ?? 1))
        intensity = min(1, max(0, number("intensity") ?? 1))
        zones = LightZones(rawValue: message["zones"] as? String ?? "") ?? .all
    }
}

// MARK: - mapping

/// Turns the music's values into a colour, once per frame (25 a second), in order: it keeps
/// its own state (the music curve, what is left of the last onset).
///
/// - The music curve `v` (0 ... 1) follows the bass: rises fast (attack), falls slowly
///   (release), and changes by at most `maxStep` per frame, so none to full takes at least four
///   frames (a full on/off cycle at least about a third of a second, never faster than ~3 Hz).
/// - What the light gives: `out = level × (floor + (1 − floor) × v^2.2)`. The floor and the level
///   are in visible terms (the controller puts the RGB value out literally): floor 0.12 at level
///   1 is 31/255 in silence, a dim but clearly coloured light. Gamma 2.2 only shapes the music.
/// - Colour: a base hue (fixed, or one turn every two minutes), turned a little by the upper
///   range, which also takes a little of the saturation; a strong onset adds a short lift
///   toward brighter and whiter that is gone within about 150 ms.
/// - `playing` false: the music counts as silent (the curve falls back with its release).
///   While nothing plays the music light does not drive the controller at all (LightIdle).
public final class LightMapper {
    public var settings: LightMusicSettings
    public static let frameSeconds = 0.04
    public static let maxStep = 0.25
    public static let gamma = 2.2
    /// Seconds for one turn of the drifting hue.
    public static let hueTurn = 120.0

    private var level = 0.0
    private var midLevel = 0.0
    private var lift = 0.0
    /// The music curve, 0 ... 1 (onset lifts included).
    public private(set) var curve = 0.0
    /// What the light gives, 0 ... 1 of the controller's full value.
    public private(set) var brightness = 0.0
    /// The base colour in "song" mode (LightSongColour); nil = the drifting or fixed hue.
    public var base: LightColour?
    /// A shape of its own instead of the style's (the upper zone in split mode).
    public var shapeOverride: LightStyle.Shape?

    public init(settings: LightMusicSettings) {
        self.settings = settings
    }

    /// Base hue in degrees at time `t` (seconds since the light started).
    public func baseHue(_ t: Double) -> Double {
        if settings.mode == .fixed && settings.hue >= 0 { return settings.hue }
        return (t / LightMapper.hueTurn * 360).truncatingRemainder(dividingBy: 360)
    }

    /// What the light gives for a music curve value.
    /// With `intensity` k below 1 the music's part is scaled down: level × lerp(1, music, k).
    public static func output(curve v: Double, level: Double, floor: Double, intensity: Double = 1) -> Double {
        let f = min(1, max(0, floor))
        let c = min(1, max(0, v))
        let music = f + (1 - f) * pow(c, gamma)
        let k = min(1, max(0, intensity))
        return min(1, max(0, level)) * (k >= 1 ? music : 1 + (music - 1) * k)
    }

    public func step(bass: Double, mid: Double, onset: Double, playing: Bool, time t: Double,
                     dt: Double = LightMapper.frameSeconds) -> (r: Int, g: Int, b: Int) {
        let shape = shapeOverride ?? settings.style.shape
        let input = playing ? min(1.5, max(0, bass.isFinite ? bass : 0)) : 0
        let tau = input > level ? shape.attack : shape.release
        level += (input - level) * (1 - exp(-dt / max(0.001, tau)))
        let m = playing ? min(1.5, max(0, mid.isFinite ? mid : 0)) : 0
        midLevel += (m - midLevel) * (1 - exp(-dt / 0.3))
        lift *= exp(-dt / 0.05)
        if playing && shape.lift > 0 && onset.isFinite && onset >= 0.6 {
            lift = max(lift, shape.lift * min(1, onset))
        }
        let k = min(1, max(0, settings.intensity))
        let target = min(1, pow(min(1, level), shape.contrast) + lift * 0.3 * k)
        curve += min(LightMapper.maxStep, max(-LightMapper.maxStep, target - curve))
        curve = min(1, max(0, curve))
        brightness = LightMapper.output(curve: curve, level: settings.level, floor: settings.floor, intensity: k)
        let hue = (base?.hue ?? baseHue(t)) + min(1, midLevel) * shape.hueMove * k
        let saturation = (base?.saturation ?? 1) * (1 - 0.3 * min(1, midLevel) * k) * min(1, max(0, settings.saturation))
        return LightMapper.rgb(hue: hue, saturation: saturation, white: lift * 0.6 * k, output: brightness)
    }

    /// The command values for a colour at an output level (0 ... 1, used as it is).
    public static func rgb(hue: Double, saturation: Double, white: Double, output: Double) -> (r: Int, g: Int, b: Int) {
        let c = hsv(hue: hue, saturation: saturation)
        let o = min(1, max(0, output))
        let w = min(1, max(0, white))
        func channel(_ v: Double) -> Int {
            let mixed = v + (1 - v) * w
            return min(255, max(0, Int((255 * o * mixed).rounded())))
        }
        return (channel(c.r), channel(c.g), channel(c.b))
    }

    /// Full-value colour of a hue (degrees) and saturation, channels 0 ... 1.
    public static func hsv(hue: Double, saturation: Double) -> (r: Double, g: Double, b: Double) {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
        var r = 0.0, g = 0.0, b = 0.0
        switch Int(h) {
        case 0: (r, g, b) = (1, x, 0)
        case 1: (r, g, b) = (x, 1, 0)
        case 2: (r, g, b) = (0, 1, x)
        case 3: (r, g, b) = (0, x, 1)
        case 4: (r, g, b) = (x, 0, 1)
        default: (r, g, b) = (1, 0, x)
        }
        let s = min(1, max(0, saturation))
        return (1 - s + s * r, 1 - s + s * g, 1 - s + s * b)
    }
}

/// When the music light drives the controller and when the controller shows its own state.
///
/// - Nothing playing (not yet started, paused, stopped, queue over): the controller keeps the
///   user's own state; nothing is sent.
/// - Playback starts: take over (LightSession.startCommands), then music.
/// - Playback stops: after `grace` seconds (short pauses, seeking, changes of song never flash
///   back and forth) the colour fades in `fadeSeconds` from the last one sent to the original,
///   at full overall brightness; then the original overall brightness and colour are sent (the
///   colour last, so the controller's saved colour stays the user's own) and nothing more.
/// - Playback within the grace time or during the fade just carries on with the music.
public final class LightIdle {
    public static let grace = 3.0
    public static let fadeSeconds = 1.0

    public enum Phase: Equatable { case idle, music, grace, fading }

    public enum Step: Equatable {
        case none
        case takeOver([String])
        case music
        case fade(String)
        case restore([String])
    }

    public var original: LightState?
    public private(set) var phase = Phase.idle
    private var since = 0.0
    private var fadeFrom = (r: 0, g: 0, b: 0)
    /// The last music colour, where a fade starts from.
    public var lastColour: (r: Int, g: Int, b: Int)?

    public init(original: LightState? = nil) {
        self.original = original
    }

    /// Back to "the controller shows its own state" without sending anything (link lost).
    public func reset() {
        phase = .idle
        lastColour = nil
    }

    /// True while the controller shows something of ours (it must be restored when the music
    /// light is switched off).
    public var holding: Bool { return phase != .idle }

    public func step(playing: Bool, now: Double) -> Step {
        switch phase {
        case .idle:
            if !playing { return .none }
            phase = .music
            return .takeOver(LightSession.startCommands(original))
        case .music:
            if playing { return .music }
            phase = .grace
            since = now
            return .none
        case .grace, .fading:
            if playing {
                phase = .music
                return .music
            }
            if phase == .grace {
                if now - since < LightIdle.grace { return .none }
                phase = .fading
                since = now
                fadeFrom = lastColour ?? (r: 0, g: 0, b: 0)
            }
            guard let o = original else {
                phase = .idle
                return .restore([])
            }
            let x = (now - since) / LightIdle.fadeSeconds
            if x >= 1 {
                phase = .idle
                lastColour = nil
                return .restore(LightSession.restoreCommands(o))
            }
            func mix(_ a: Int, _ b: UInt8) -> Int { return Int((Double(a) + (Double(b) - Double(a)) * max(0, x)).rounded()) }
            return .fade(LightCommand.color(r: mix(fadeFrom.r, o.r), g: mix(fadeFrom.g, o.g), b: mix(fadeFrom.b, o.b)))
        }
    }
}

/// Split zones: the upper lights (zone 1, "<10rrggbb>") and the footwell (zone 2, "<09rrggbb>")
/// each get a colour of their own.
///
/// - Upper: the base colour (the song's primary with its loud-section shift), brightness from the
///   upper range (melody, vocals) with a softer curve (attack 60 ms, release 400 ms) and no onset
///   lift; the bass does not move it.
/// - Footwell: its own base colour (the song's secondary), brightness from the bass with the
///   style's attack, release and onset lifts; the upper range does not move it.
/// - Both keep level, floor, intensity and saturation.
public final class LightSplitMapper {
    public let upper: LightMapper
    public let foot: LightMapper

    public var settings: LightMusicSettings {
        didSet {
            upper.settings = settings
            foot.settings = settings
            upper.shapeOverride = LightSplitMapper.upperShape(settings.style)
        }
    }

    public static func upperShape(_ style: LightStyle) -> LightStyle.Shape {
        let s = style.shape
        return LightStyle.Shape(attack: 0.06, release: 0.4, contrast: s.contrast, hueMove: s.hueMove, lift: 0)
    }

    public init(settings: LightMusicSettings) {
        self.settings = settings
        upper = LightMapper(settings: settings)
        foot = LightMapper(settings: settings)
        upper.shapeOverride = LightSplitMapper.upperShape(settings.style)
    }

    public func step(bass: Double, mid: Double, onset: Double, playing: Bool, time t: Double,
                     dt: Double = LightMapper.frameSeconds, upperBase: LightColour?, footBase: LightColour?)
        -> (upper: (r: Int, g: Int, b: Int), foot: (r: Int, g: Int, b: Int)) {
        upper.base = upperBase
        foot.base = footBase
        let u = upper.step(bass: mid, mid: mid, onset: 0, playing: playing, time: t, dt: dt)
        let f = foot.step(bass: bass, mid: 0, onset: onset, playing: playing, time: t, dt: dt)
        return (u, f)
    }
}

/// Which zone colours go first when the link cannot take them all: the one that changed most.
public enum LightZoneOrder {
    public static func order(_ items: [(command: String, change: Int)]) -> [String] {
        return items.enumerated().sorted { a, b in
            a.element.change != b.element.change ? a.element.change > b.element.change : a.offset < b.offset
        }.map { $0.element.command }
    }
}

/// Decides whether a colour is worth sending: only when some channel moved by at least
/// `threshold` (2/255 by default) from what was last sent. Nothing is sent while the light is
/// steady - the controller may write every colour it gets into its memory.
public final class LightChangeGate {
    public let threshold: Int
    public private(set) var last: (r: Int, g: Int, b: Int)?

    public init(threshold: Int = 2) {
        self.threshold = threshold
    }

    /// True = send it (and it counts as sent from now on).
    public func admit(_ c: (r: Int, g: Int, b: Int)) -> Bool {
        if let l = last, abs(c.r - l.r) < threshold, abs(c.g - l.g) < threshold, abs(c.b - l.b) < threshold {
            return false
        }
        last = c
        return true
    }

    /// How far a colour is from the last one sent: the largest channel difference (255 when
    /// nothing has been sent).
    public func change(_ c: (r: Int, g: Int, b: Int)) -> Int {
        guard let l = last else { return 255 }
        return max(abs(c.r - l.r), abs(c.g - l.g), abs(c.b - l.b))
    }

    /// Forget what was sent (after reconnecting, or when something else set the colour).
    public func reset() {
        last = nil
    }
}
