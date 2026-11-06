import XCTest
import LightCore

final class LightProtocolTests: XCTestCase {
    private func ascii(_ text: String) -> Data {
        return Data(text.utf8)
    }

    // MARK: commands

    func testColourCommandIsLowercaseHexInBrackets() {
        XCTAssertEqual(LightCommand.color(r: 255, g: 0, b: 0), "<06ff0000>")
        XCTAssertEqual(LightCommand.color(r: 0x1A, g: 0xB2, b: 0x0C), "<061ab20c>")
        XCTAssertEqual(LightCommand.color(r: 0, g: 0, b: 0), "<06000000>")
        /* out of range is brought into range instead of making a longer frame */
        XCTAssertEqual(LightCommand.color(r: 300, g: -5, b: 128), "<06ff0080>")
        XCTAssertEqual(LightCommand.zoneColor(1, r: 255, g: 255, b: 255), "<10ffffff>")
        XCTAssertEqual(LightCommand.zoneColor(2, r: 1, g: 2, b: 3), "<09010203>")
    }

    func testBrightnessCommand() {
        XCTAssertEqual(LightCommand.brightness(0), "<020000>")
        XCTAssertEqual(LightCommand.brightness(9), "<020009>")
        XCTAssertEqual(LightCommand.brightness(10), "<02000a>")
        XCTAssertEqual(LightCommand.brightness(255), "<0200ff>")
    }

    func testTypedTextGetsItsBracketsAndNothingElseChanges() {
        XCTAssertEqual(LightCommand.frame("0A01"), "<0A01>")
        XCTAssertEqual(LightCommand.frame("<0A01>"), "<0A01>")
        XCTAssertEqual(LightCommand.frame("  <0701>\n"), "<0701>")
        XCTAssertEqual(LightCommand.frame("<06ff0000"), "<06ff0000>")
        XCTAssertEqual(LightCommand.frame("040F>"), "<040F>")
        XCTAssertEqual(LightCommand.frame("06FfAa00"), "<06FfAa00>", "the case is left as typed")
        XCTAssertEqual(LightCommand.frame("zz not hex"), "<zz not hex>", "anything may be tried")
    }

    func testBytesAreTheAsciiText() {
        XCTAssertEqual([UInt8](LightCommand.bytes("<06ff0000>")),
                       [0x3C, 0x30, 0x36, 0x66, 0x66, 0x30, 0x30, 0x30, 0x30, 0x3E])
        XCTAssertEqual(lightHex(LightCommand.bytes("<0A01>")), "3c304130313e")
    }

    // MARK: what the rate tests send

    func testPulseIsATwoHertzRaisedSine() {
        XCTAssertEqual(LightPattern.pulse(0), 0, accuracy: 1e-12)
        XCTAssertEqual(LightPattern.pulse(0.125), 0.5, accuracy: 1e-12)
        XCTAssertEqual(LightPattern.pulse(0.25), 1, accuracy: 1e-12)
        XCTAssertEqual(LightPattern.pulse(0.5), 0, accuracy: 1e-12)
        XCTAssertEqual(LightPattern.colorPulse(0), "<06000000>")
        XCTAssertEqual(LightPattern.colorPulse(0.25), "<06ff0000>")
        XCTAssertEqual(LightPattern.brightnessPulse(0), "<020000>")
        XCTAssertEqual(LightPattern.brightnessPulse(0.25), "<020009>")
        /* every value stays inside what the vendor's own screen sends */
        for i in 0..<600 {
            let command = LightPattern.brightnessPulse(Double(i) / 100)
            XCTAssertTrue(command.hasPrefix("<02000") && command.count == 8, command)
        }
    }

    func testHueSweepGoesOnceRoundTheColourCircle() {
        XCTAssertEqual(LightPattern.hueSweep(0), "<06ff0000>")
        XCTAssertEqual(LightPattern.hueSweep(1), "<06ffff00>")
        XCTAssertEqual(LightPattern.hueSweep(2), "<0600ff00>")
        XCTAssertEqual(LightPattern.hueSweep(3), "<0600ffff>")
        XCTAssertEqual(LightPattern.hueSweep(4), "<060000ff>")
        XCTAssertEqual(LightPattern.hueSweep(5), "<06ff00ff>")
        /* always one channel full and one off: full strength, full colour */
        for i in 0..<120 {
            let c = LightPattern.rgb(hue: Double(i) / 120)
            XCTAssertEqual(max(c.r, c.g, c.b), 255)
            XCTAssertEqual(min(c.r, c.g, c.b), 0)
        }
    }

    // MARK: replies

    func testFrameTypesAreNamed() {
        XCTAssertEqual(LightFrame(text: "<1201ff0000>").name, "state")
        XCTAssertEqual(LightFrame(text: "<1f00>").name, "state")
        XCTAssertEqual(LightFrame(text: "<4E00>").name, "state")
        XCTAssertEqual(LightFrame(text: "<5a>").name, "state")
        XCTAssertEqual(LightFrame(text: "<2601>").name, "settings state")
        XCTAssertEqual(LightFrame(text: "<130203>").name, "version")
        XCTAssertEqual(LightFrame(text: "<1908>").name, "not supported")
        XCTAssertEqual(LightFrame(text: "<2E01>").name, "warning")
        XCTAssertNil(LightFrame(text: "<7701>").name)
        XCTAssertEqual(LightFrame(text: "<7701>").type, "77")
        XCTAssertEqual(LightFrame(text: "<1>").type, "", "too short to have a type")
        XCTAssertNil(LightFrame(text: "<>").name)
    }

    private func frames(_ pieces: [LightReplySplitter.Piece]) -> [String] {
        return pieces.map { piece -> String in
            switch piece {
            case .frame(let f): return f.text
            case .other(let text): return "?" + text
            }
        }
    }

    func testSeveralFramesInOneNotification() {
        let s = LightReplySplitter()
        XCTAssertEqual(frames(s.feed(ascii("<1201ff>"))), ["<1201ff>"])
        XCTAssertEqual(frames(s.feed(ascii("<1201ff><2600><130102>"))), ["<1201ff>", "<2600>", "<130102>"])
    }

    func testAFrameSplitAcrossNotifications() {
        let s = LightReplySplitter()
        XCTAssertEqual(frames(s.feed(ascii("<1201"))), [])
        XCTAssertEqual(frames(s.feed(ascii("ff00"))), [])
        XCTAssertEqual(frames(s.feed(ascii("00><19"))), ["<1201ff0000>"])
        XCTAssertEqual(frames(s.feed(ascii("08>"))), ["<1908>"])
    }

    func testGarbageBetweenFramesIsKeptAndShown() {
        let s = LightReplySplitter()
        XCTAssertEqual(frames(s.feed(ascii("ab<1201>cd<2600>\r\n"))), ["?ab", "<1201>", "?cd", "<2600>", "?\\x0D\\x0A"])
        /* bytes that are not text at all */
        XCTAssertEqual(frames(s.feed(Data([0x00, 0xFF, 0x3C, 0x31, 0x39, 0x3E]))), ["?\\x00\\xFF", "<19>"])
        /* a frame that begins twice: the first beginning was no frame */
        XCTAssertEqual(frames(s.feed(ascii("<12<1301>"))), ["?<12", "<1301>"])
        /* a ">" with nothing open */
        XCTAssertEqual(frames(s.feed(ascii("><1201>"))), ["?>", "<1201>"])
    }

    func testAnEndlessFrameIsGivenUpAndResetForgetsAnOpenOne() {
        let s = LightReplySplitter()
        let long = "<" + String(repeating: "a", count: 400)
        let pieces = s.feed(ascii(long))
        XCTAssertFalse(pieces.isEmpty, "300 characters without an end are handed back, not kept for ever")
        XCTAssertEqual(frames(s.feed(ascii("<0A>"))).last, "<0A>")

        XCTAssertEqual(frames(s.feed(ascii("<12"))), [])
        s.reset()
        XCTAssertEqual(frames(s.feed(ascii("01><1301>"))), ["?01>", "<1301>"])
    }
}
