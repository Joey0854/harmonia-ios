import Foundation

/* The text protocol of the car's ambient-light controller, as far as it is known from reading
   the vendor's Android app (nothing here has been confirmed on the real controller yet):

   A command is plain ASCII: "<" + hex digits + ">", for example the ten bytes of "<06ff0000>".
   Replies come back in the same form; one notification can hold several frames back to back,
   and a frame can be cut in two by the radio.

   This file has no Bluetooth in it, so that it can be tested on its own (package target
   LightCore). */

/// Builds commands.
public enum LightCommand {
    /// What the user typed, as a command: surrounding blanks removed, "<" and ">" added when
    /// missing. Nothing else is changed (not even the case), so anything can be tried.
    public static func frame(_ typed: String) -> String {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.hasPrefix("<") { text = "<" + text }
        if !text.hasSuffix(">") { text += ">" }
        return text
    }

    private static func hex(_ value: Int) -> String {
        let v = min(255, max(0, value))
        return String(format: "%02x", v)
    }

    /// One colour for all zones: "<06rrggbb>", lowercase as the vendor app sends it.
    public static func color(r: Int, g: Int, b: Int) -> String {
        return "<06" + hex(r) + hex(g) + hex(b) + ">"
    }

    /// Zone 1 ("<10rrggbb>") or zone 2 ("<09rrggbb>") alone.
    public static func zoneColor(_ zone: Int, r: Int, g: Int, b: Int) -> String {
        return "<" + (zone == 2 ? "09" : "10") + hex(r) + hex(g) + hex(b) + ">"
    }

    /// Overall brightness: "<0200xx>". The vendor's own screen only sends 00 to 09.
    public static func brightness(_ value: Int) -> String {
        return "<0200" + hex(value) + ">"
    }

    /// The bytes that go over the air: the text as ASCII.
    public static func bytes(_ command: String) -> Data {
        return Data(command.utf8)
    }
}

/// The values the rate tests send, as functions of the time since the test began.
public enum LightPattern {
    /// A 2 Hz pulse between 0 and 1 (a sine lifted to start at 0).
    public static func pulse(_ seconds: Double, hertz: Double = 2) -> Double {
        return 0.5 - 0.5 * cos(2 * Double.pi * hertz * seconds)
    }

    /// Red following the pulse: "<06xx0000>".
    public static func colorPulse(_ seconds: Double) -> String {
        return LightCommand.color(r: Int((pulse(seconds) * 255).rounded()), g: 0, b: 0)
    }

    /// Brightness following the pulse through 00 ... 09: "<0200xx>".
    public static func brightnessPulse(_ seconds: Double) -> String {
        return LightCommand.brightness(Int((pulse(seconds) * 9).rounded()))
    }

    /// Once round the colour circle in `duration` seconds, at full strength.
    public static func hueSweep(_ seconds: Double, duration: Double = 6) -> String {
        let c = rgb(hue: seconds / duration)
        return LightCommand.color(r: c.r, g: c.g, b: c.b)
    }

    /// A fully saturated, full-value colour; hue 0 ..< 1 (0 red, 1/3 green, 2/3 blue).
    public static func rgb(hue: Double) -> (r: Int, g: Int, b: Int) {
        let h = (hue - hue.rounded(.down)) * 6
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
        return (Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}

/// One reply frame.
public struct LightFrame: Equatable {
    /// The frame as received, brackets included, e.g. "<1901>".
    public let text: String
    /// Its first byte as two capital hex digits, e.g. "19"; empty when the frame is too short.
    public let type: String
    /// What that type means, when known.
    public let name: String?

    public init(text: String) {
        self.text = text
        let inner = text.dropFirst().dropLast()
        type = inner.count >= 2 ? String(inner.prefix(2)).uppercased() : ""
        name = LightFrame.names[type]
    }

    /// Frame types as the vendor app reads them. Four generations of firmware each have their
    /// own "state" frame.
    public static let names: [String: String] = [
        "12": "state", "1F": "state", "4E": "state", "5A": "state",
        "26": "settings state",
        "13": "version",
        "19": "not supported",
        "2E": "warning"
    ]
}

/// Cuts what arrives in notifications into frames. Bytes that belong to no frame are handed
/// back as they are, so nothing the controller says is lost.
public final class LightReplySplitter {
    public enum Piece: Equatable {
        case frame(LightFrame)
        /// Something between frames (shown as text; bytes that are not printable as \xNN).
        case other(String)
    }

    /// A frame that has begun ("<...") and not ended yet.
    private var open = ""
    /// Longer than this without a ">" is no frame.
    private static let limit = 256

    public init() {}

    public func feed(_ data: Data) -> [Piece] {
        var pieces: [Piece] = []
        var loose = ""
        func flushLoose() {
            if !loose.isEmpty {
                pieces.append(.other(loose))
                loose = ""
            }
        }
        for byte in data {
            let text: String
            if byte >= 0x20 && byte < 0x7F {
                text = String(UnicodeScalar(byte))
            } else {
                text = String(format: "\\x%02X", byte)
            }
            if byte == 0x3C {   // "<": a frame begins; one that was open and never closed is no frame
                if !open.isEmpty {
                    loose += open
                }
                flushLoose()
                open = "<"
            } else if open.isEmpty {
                loose += text
            } else if byte == 0x3E {   // ">"
                pieces.append(.frame(LightFrame(text: open + ">")))
                open = ""
            } else {
                open += text
                if open.count > LightReplySplitter.limit {
                    loose += open
                    open = ""
                }
            }
        }
        flushLoose()
        return pieces
    }

    /// Forgets a frame that was begun (after a disconnect).
    public func reset() {
        open = ""
    }
}

/// Bytes as lowercase hex without separators, for the log.
public func lightHex(_ data: Data) -> String {
    return data.map { String(format: "%02x", $0) }.joined()
}
