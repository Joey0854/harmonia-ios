import XCTest
import LightCore

/// The guided light test: putting the controller back, and what it never sends.
final class LightWizardTests: XCTestCase {
    let settingsFrame = "<2601FFFFFFFFFF00000009FF0000>"
    let stateFrame = "<4E001801FFFFFFFFFFFF03030505000305>"

    func testOriginalFromTheRealFrames() {
        let o = LightWizardOriginal(settingsFrame: settingsFrame, stateFrame: stateFrame)
        XCTAssertEqual(o.layout, 0x00)            // 26 [8]
        XCTAssertEqual(o.symphonyMode, 0x18)      // 4E [2]
        XCTAssertEqual(o.symphonySpeed, 0x05)     // 4E [13]
        XCTAssertEqual(o.zone1Brightness, 0x03)   // 4E [10]
        XCTAssertEqual(o.zone2Brightness, 0x03)   // 4E [11]
        XCTAssertEqual(o.globalBrightness, 0x03)  // 4E [15]
        XCTAssertEqual(o.colour.map { [$0.r, $0.g, $0.b] }, [0xFF, 0xFF, 0xFF])  // 4E [4...6]
    }

    func testRestoreFromTheRealFrames() {
        let o = LightWizardOriginal(settingsFrame: settingsFrame, stateFrame: stateFrame)
        XCTAssertEqual(LightWizard.restoreCommands(o),
                       ["<1400>", "<1E18>", "<0B05>", "<010103>", "<010203>", "<020003>", "<06ffffff>"])
    }

    func testRestoreClampsAndSkips() {
        let o = LightWizardOriginal(settingsFrame: "<2601FFFFFFFFFF00010009FF0000>",
                                    stateFrame: "<4E000901102030FFFFFF0C0F0509000F05>")
        XCTAssertEqual(o.layout, 0x01)
        XCTAssertEqual(LightWizard.restoreCommands(o),
                       ["<1401>", "<1E09>", "<010109>", "<010209>", "<020009>", "<06102030>"],
                       "speed 09 is not one to send; brightness never above 09")
        XCTAssertEqual(LightWizard.restoreCommands(LightWizardOriginal()), ["<1400>", "<1E18>"], "nothing read: the normal layout and effect only")
        XCTAssertEqual(LightWizard.restoreCommands(LightWizardOriginal(settingsFrame: nil, stateFrame: "<4E00>")), ["<1400>", "<1E18>"])
        for c in LightWizard.restoreCommands(o) { XCTAssertTrue(LightWizard.allowed(c), c) }
    }

    func testNeverSend() {
        for c in ["<4200>", "<4C01>", "<3001>", "<3800>", "<3900>", "<3D00>", "<5900>", "<5B01>", "<5D00>",
                  "<020010>", "<02000A>", "<0200ff>", "<010110>", "<01020a>", "06ffffff", "<06ff>x", "<0>", "<>"] {
            XCTAssertFalse(LightWizard.allowed(c), c)
        }
        for c in ["<020009>", "<020000>", "<010109>", "<010200>", "<1E18>", "<1E09>", "<0B05>", "<0C01>", "<06ffffff>",
                  "<10ff0000>", "<0900ff00>", "<1400>", "<1401>", "<0400>", "<0A01>", "<0701>"] {
            XCTAssertTrue(LightWizard.allowed(c), c)
        }
    }
}
