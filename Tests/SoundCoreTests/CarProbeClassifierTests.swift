import Foundation
import XCTest
@testable import SoundCore

/// The phone's car classification against the PC's carprobe_analyze.py
/// (Tests/Fixtures/carprobe_classify.json, made by tools/carprobe_fixtures.py).
final class CarProbeClassifierTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Fixtures.data("carprobe_classify.json"))
        return try XCTUnwrap(object as? [String: Any])
    }

    private static func isBool(_ v: Any) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID()
    }

    /// JSON-like equality: true / false only equal true / false, numbers by value.
    private static func same(_ a: Any?, _ b: Any?, _ path: String, _ problems: inout [String]) {
        switch (a, b) {
        case (nil, nil):
            return
        case (let x as [String: Any], let y as [String: Any]):
            if Set(x.keys) != Set(y.keys) { problems.append("\(path): keys \(x.keys.sorted()) != \(y.keys.sorted())"); return }
            for k in x.keys.sorted() { same(x[k], y[k], path + "." + k, &problems) }
        case (let x as String, let y as String):
            if x != y { problems.append("\(path): \(x) != \(y)") }
        case (let x?, let y?) where isBool(x) || isBool(y):
            if !(isBool(x) && isBool(y)) || (x as! NSNumber).boolValue != (y as! NSNumber).boolValue {
                problems.append("\(path): \(x) != \(y)")
            }
        case (let x as NSNumber, let y as NSNumber):
            if x.doubleValue != y.doubleValue { problems.append("\(path): \(x) != \(y)") }
        default:
            problems.append("\(path): \(String(describing: a)) != \(String(describing: b))")
        }
    }

    func testFixtureCoversEveryKind() throws {
        let cases = try XCTUnwrap(fixture()["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 12)
        let kinds = Set(cases.compactMap { $0["kind"] as? String })
        XCTAssertEqual(kinds, ["plain", "bose", "rearSplit", "manual"])
    }

    func testThresholdsAndNamesMatchPython() throws {
        let f = try fixture()
        let t = try XCTUnwrap(f["thresholds"] as? [String: Double])
        XCTAssertEqual(t["SNR_MIN"], CarProbeClassifier.snrMin)
        XCTAssertEqual(t["NO_UPMIX_MAX"], CarProbeClassifier.noUpmixMax)
        XCTAssertEqual(t["PAN_MIN"], CarProbeClassifier.panMin)
        XCTAssertEqual(t["CENTER_DROP"], CarProbeClassifier.centerDrop)
        XCTAssertEqual(t["REAR_RISE"], CarProbeClassifier.rearRise)
        XCTAssertEqual(t["REAR_SAME"], CarProbeClassifier.rearSame)
        XCTAssertEqual(t["REAR_SPLIT"], CarProbeClassifier.rearSplit)
        XCTAssertEqual(f["types"] as? [String: String], CarProbeClassifier.typeNames)
    }

    func testEveryCaseMatchesPython() throws {
        let cases = try XCTUnwrap(fixture()["cases"] as? [[String: Any]])
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let meta = c["meta"] as? [String: Any] ?? [:]
            let positions = (meta["positions"] as? [[String: Any]] ?? []).map { CarProbePosition(json: $0) }
            let r = CarProbeClassifier.classify(positions)
            XCTAssertEqual(r.kind.rawValue, c["kind"] as? String, "kind: \(name)")
            XCTAssertEqual(r.typeName, c["typeName"] as? String, "type name: \(name)")
            XCTAssertEqual(r.reasons, c["reasons"] as? [String] ?? [], "reasons: \(name)")
            var problems: [String] = []
            let expected = c["preset"] is NSNull ? nil : c["preset"]
            CarProbeClassifierTests.same(r.preset, expected, "preset", &problems)
            XCTAssertEqual(problems, [], "preset: \(name)")
        }
    }

    /// The presets pass the app's whitelist unchanged in what they set.
    func testPresetsPassTheWhitelist() throws {
        for (key, p) in CarProbeClassifier.presets {
            guard case .success(let clean) = CarPresetVerifier.sanitize(p) else { return XCTFail("\(key) refused") }
            let amb = try XCTUnwrap(clean["amb"] as? [String: Any])
            XCTAssertEqual(amb["db"] as? Double, (p["amb"] as? [String: Any])?["db"] as? Double, key)
            XCTAssertEqual(amb["rt60"] as? Double, 1.8, key)
            XCTAssertEqual(amb["lowFront"] as? Bool, true, key)
            let early = try XCTUnwrap(clean["early"] as? [String: Any])
            XCTAssertEqual(early["on"] as? Bool, true, key)
        }
    }

    /// A position in the app's own result format (CarProbeResult -> upload quality) reads the same.
    func testUploadFormatReading() {
        let p = CarProbePosition(json: ["name": "center", "skipped": false,
                                        "levels": ["B1/inphase/0": 0, "B1/anti/0": -7.5, "bad": "x"],
                                        "quality": ["snr": 22.5, "snrByCell": ["B1/anti/0": 9.5, "flag": true]]])
        XCTAssertEqual(p.levels, ["B1/inphase/0": 0, "B1/anti/0": -7.5])
        XCTAssertEqual(p.snr, 22.5)
        XCTAssertEqual(p.snrByCell, ["B1/anti/0": 9.5])
        let t = CarProbeClassifier.table([p])
        XCTAssertNil(CarProbeClassifier.val(t, "center", "B1/anti/0"))
        XCTAssertEqual(CarProbeClassifier.val(t, "center", "B1/inphase/0"), 0)
    }

    func testUploadField() {
        XCTAssertEqual(CarProbeClassifier.uploadField("  Mazda  "), "Mazda")
        XCTAssertEqual(CarProbeClassifier.uploadField("C43\r\n2019\tW205\u{2028}x"), "C43  2019 W205 x")
        XCTAssertEqual(CarProbeClassifier.uploadField(nil), "")
        XCTAssertEqual(CarProbeClassifier.uploadField(42), "")
        XCTAssertEqual(CarProbeClassifier.uploadField(["Bose"]), "")
        let long = String(repeating: "賓", count: 80)
        XCTAssertEqual(CarProbeClassifier.uploadField(long).count, 60)
        XCTAssertEqual(CarProbeClassifier.uploadField(String(repeating: "a", count: 59) + "   b"), String(repeating: "a", count: 59))
        XCTAssertFalse(CarProbeClassifier.uploadField("a\nb\rc").contains(where: { $0.isNewline }))
    }
}
