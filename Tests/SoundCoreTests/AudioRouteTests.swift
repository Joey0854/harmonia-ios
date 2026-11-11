import XCTest
import SoundCore

/// The output kind the page switches its sound profile by (1.3.23).
final class AudioRouteTests: XCTestCase {
    func testCarPlayIsTheCarWithItsName() {
        let r = AudioRoute.classify([(type: "CarAudio", name: "  My   Car\n")])
        XCTAssertEqual(r.kind, .car)
        XCTAssertEqual(r.name, "My Car")
        XCTAssertEqual(r.port, "CarAudio")
    }

    func testTheCarWinsOverOtherOutputsListedWithIt() {
        let r = AudioRoute.classify([(type: "BluetoothA2DPOutput", name: "Buds"), (type: "CarAudio", name: "GLC")])
        XCTAssertEqual(r.kind, .car)
        XCTAssertEqual(r.name, "GLC")
    }

    func testHeadphoneKinds() {
        for t in ["Headphones", "BluetoothA2DPOutput", "BluetoothLE", "BluetoothHFP", "USBAudio"] {
            let r = AudioRoute.classify([(type: t, name: "x")])
            XCTAssertEqual(r.kind, .headphones, t)
            XCTAssertEqual(r.name, "", "only a car keeps its name")
        }
    }

    func testEverythingElseIsASpeaker() {
        for t in ["Speaker", "Receiver", "AirPlay", "HDMIOutput", "LineOut"] {
            XCTAssertEqual(AudioRoute.classify([(type: t, name: "x")]).kind, .speaker, t)
        }
        let none = AudioRoute.classify([])
        XCTAssertEqual(none.kind, .speaker)
        XCTAssertEqual(none.port, "")
    }

    func testTheAppsOwnTypeSetsAreUsed() {
        let r = AudioRoute.classify([(type: "carX", name: "A")], carTypes: ["carX"], headphoneTypes: [])
        XCTAssertEqual(r.kind, .car)
        XCTAssertEqual(AudioRoute.classify([(type: "Headphones", name: "")], carTypes: [], headphoneTypes: []).kind, .speaker)
    }

    func testLongNamesAreCut() {
        let r = AudioRoute.classify([(type: "CarAudio", name: String(repeating: "a", count: 200))])
        XCTAssertEqual(r.name.count, 80)
    }

    func testEventShape() {
        let e = AudioRouteInfo(kind: .headphones, name: "", port: "Headphones").event
        XCTAssertEqual(e["type"] as? String, "route")
        XCTAssertEqual(e["kind"] as? String, "headphones")
        XCTAssertEqual(e["name"] as? String, "")
    }
}
