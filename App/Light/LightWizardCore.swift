import Foundation

/* The guided light test ("完整測試"): what the controller was like before it, how to put it back,
   and which commands it must never send. No Bluetooth in here (package target LightCore). */

/// The controller's state before the guided test, from its settings frame (26) and its state
/// frame (4E). Anything not read is nil and is left alone when restoring.
public struct LightWizardOriginal: Equatable {
    /// Settings frame [8]: 00 = zones as "1400" (upper / lower), 01 = "1401".
    public var layout: UInt8?
    /// State frame [10] and [11]: brightness of zone 1 and zone 2.
    public var zone1Brightness: UInt8?
    public var zone2Brightness: UInt8?
    /// State frame [15]: overall brightness.
    public var globalBrightness: UInt8?
    /// State frame [4...6]: the colour.
    public var colour: (r: UInt8, g: UInt8, b: UInt8)?
    /// State frame [2]: the strip effect; [13]: its speed.
    public var symphonyMode: UInt8?
    public var symphonySpeed: UInt8?

    public init() {}

    /// From the frames as received (either may be missing).
    public init(settingsFrame: String?, stateFrame: String?) {
        if let text = settingsFrame, let b = lightFrameBytes(text), b.count > 8, b[0] == 0x26 {
            layout = b[8]
        }
        if let text = stateFrame, let b = lightFrameBytes(text), b.count >= 16, b[0] == 0x4E {
            colour = (b[4], b[5], b[6])
            zone1Brightness = b[10]
            zone2Brightness = b[11]
            symphonySpeed = b[13]
            globalBrightness = b[15]
            symphonyMode = b[2]
        }
    }

    public static func == (a: LightWizardOriginal, b: LightWizardOriginal) -> Bool {
        return a.layout == b.layout && a.zone1Brightness == b.zone1Brightness && a.zone2Brightness == b.zone2Brightness
            && a.globalBrightness == b.globalBrightness && a.symphonyMode == b.symphonyMode
            && a.symphonySpeed == b.symphonySpeed
            && a.colour.map { [$0.r, $0.g, $0.b] } == b.colour.map { [$0.r, $0.g, $0.b] }
    }
}

public enum LightWizard {
    static func hex(_ v: UInt8) -> String {
        return String(format: "%02X", UInt32(v))
    }

    /// Puts the controller back, in this order: zone layout, strip effect, its speed (only
    /// 01 ... 05), zone 1 and zone 2 brightness, overall brightness (all three never above 09),
    /// and the colour last. Values that were not read are skipped, except the zone layout and
    /// the strip effect, which fall back to the user's normal ones (1400, Sync RGB 18).
    public static func restoreCommands(_ o: LightWizardOriginal) -> [String] {
        var list: [String] = []
        list.append("<14" + hex(o.layout.map { min($0, 1) } ?? 0) + ">")
        list.append("<1E" + hex(o.symphonyMode ?? LightSession.syncSymphony) + ">")
        if let s = o.symphonySpeed, (1...5).contains(s) { list.append("<0B" + hex(s) + ">") }
        if let z = o.zone1Brightness { list.append("<0101" + hex(min(9, z)) + ">") }
        if let z = o.zone2Brightness { list.append("<0102" + hex(min(9, z)) + ">") }
        if let g = o.globalBrightness { list.append(LightCommand.brightness(min(9, Int(g)))) }
        if let c = o.colour { list.append(LightCommand.color(r: Int(c.r), g: Int(c.g), b: Int(c.b))) }
        return list
    }

    /// False for commands the guided test must never send: reset (42), factory display (4C),
    /// the welcome and settings commands (30 ... 3D, 59 ... 5D), and any brightness above 09
    /// (overall "0200xx", zones "0101xx" / "0102xx"). Malformed commands are refused too.
    public static func allowed(_ command: String) -> Bool {
        guard command.hasPrefix("<"), command.hasSuffix(">"), let b = lightFrameBytes(command), !b.isEmpty else { return false }
        let first = b[0]
        if first == 0x42 || first == 0x4C { return false }
        if (0x30...0x3D).contains(first) || (0x59...0x5D).contains(first) { return false }
        if first == 0x02 || first == 0x01 {
            guard b.count >= 3 else { return false }
            if b[2] > 9 { return false }
        }
        return true
    }
}
