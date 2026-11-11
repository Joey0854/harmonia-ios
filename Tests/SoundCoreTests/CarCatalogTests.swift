import CryptoKit
import XCTest
import SoundCore

/// The signed car list (App/Sound/CarCatalog.swift), signed with a key pair made for the test.
final class CarCatalogTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func envelope(_ payload: [String: Any], key: Curve25519.Signing.PrivateKey, tamper: Bool = false) throws -> Data {
        var bytes = try JSONSerialization.data(withJSONObject: payload)
        let sig = try key.signature(for: bytes)
        if tamper { bytes.append(contentsOf: Array(" ".utf8)) }
        return try JSONSerialization.data(withJSONObject: ["payload": bytes.base64EncodedString(), "sig": sig.base64EncodedString()])
    }

    private func payload(version: Int = 1, cars: [Any]? = nil) -> [String: Any] {
        return [
            "version": version, "issued": "2026-11-11T00:00:00Z",
            "cars": cars ?? [
                ["id": "mazda3-bp-bose", "make": "Mazda", "model": "3 (BP)", "system": "Bose", "kind": "bose",
                 "calibrated": false, "preset": CarProbeClassifier.presets["concertHall"]!],
                ["id": "c43-s205-burmester", "make": "Mercedes-AMG", "model": "C43 (S205)", "system": "Burmester",
                 "kind": "manual", "calibrated": false, "preset": NSNull()],
                ["id": "generic-plain", "make": "", "model": "一般原廠音響", "system": "", "kind": "plain",
                 "calibrated": true, "preset": CarProbeClassifier.presets["plainStereo"]!]
            ]
        ]
    }

    private func pub(_ key: Curve25519.Signing.PrivateKey) -> String { return key.publicKey.rawRepresentation.base64EncodedString() }

    func testValidCatalog() throws {
        let key = Curve25519.Signing.PrivateKey()
        let result = CarCatalogVerifier.verify(try envelope(payload(), key: key), publicKey: pub(key), now: now)
        guard case .success(let c) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(c.version, 1)
        XCTAssertEqual(c.cars.map { $0.id }, ["mazda3-bp-bose", "c43-s205-burmester", "generic-plain"])
        XCTAssertNotNil(c.cars[0].preset)
        XCTAssertNil(c.cars[1].preset)
        XCTAssertEqual(c.cars[2].calibrated, true)
        XCTAssertEqual(((c.cars[0].preset?["amb"]) as? [String: Any])?["db"] as? Double, -12)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(c.cars.map { $0.json }))
    }

    func testRefusesForeignOrTamperedOrPlaceholder() throws {
        let key = Curve25519.Signing.PrivateKey()
        let other = Curve25519.Signing.PrivateKey()
        guard case .failure(let e1) = CarCatalogVerifier.verify(try envelope(payload(), key: other), publicKey: pub(key), now: now) else {
            return XCTFail("foreign signature accepted")
        }
        XCTAssertEqual(e1, .badSignature)
        guard case .failure(let e2) = CarCatalogVerifier.verify(try envelope(payload(), key: key, tamper: true), publicKey: pub(key), now: now) else {
            return XCTFail("tampered payload accepted")
        }
        XCTAssertEqual(e2, .badSignature)
        guard case .failure(let e3) = CarCatalogVerifier.verify(try envelope(payload(), key: key), publicKey: "PLACEHOLDER", now: now) else {
            return XCTFail("placeholder key accepted")
        }
        XCTAssertEqual(e3, .noKey)
        guard case .failure(let e4) = CarCatalogVerifier.verify(Data("{}".utf8), publicKey: pub(key), now: now) else {
            return XCTFail("unsigned accepted")
        }
        XCTAssertEqual(e4, .badEnvelope)
        /* the built-in key refuses what a test key signed */
        guard case .failure = CarCatalogVerifier.verify(try envelope(payload(), key: key), now: now) else {
            return XCTFail("built-in key accepted a test signature")
        }
    }

    func testBadEntriesDroppedAndPresetsClamped() throws {
        let key = Curve25519.Signing.PrivateKey()
        let cars: [Any] = [
            "not an object",
            ["id": "", "kind": "plain"],
            ["id": "x", "kind": "weird"],
            ["id": "a", "kind": "bose", "preset": ["xover": 9999, "amb": ["db": 50, "style": "half"]]],
            ["id": "a", "kind": "plain"],
            ["id": "b", "kind": "plain", "calibrated": 1, "preset": ["xover": "high"]]
        ]
        guard case .success(let c) = CarCatalogVerifier.verify(try envelope(payload(cars: cars), key: key), publicKey: pub(key), now: now) else {
            return XCTFail("refused")
        }
        XCTAssertEqual(c.cars.map { $0.id }, ["a", "b"])
        XCTAssertEqual(c.cars[0].preset?["xover"] as? Double, 300)
        XCTAssertEqual((c.cars[0].preset?["amb"] as? [String: Any])?["db"] as? Double, -3)
        XCTAssertNil(c.cars[1].preset, "a preset that does not pass the whitelist is dropped")
        XCTAssertEqual(c.cars[1].calibrated, false, "calibrated must be true / false")
    }

    func testNewestWins() throws {
        let key = Curve25519.Signing.PrivateKey()
        let v1 = try envelope(payload(version: 1), key: key)
        let v3 = try envelope(payload(version: 3), key: key)
        let bad = try envelope(payload(version: 9), key: Curve25519.Signing.PrivateKey())
        let best = try XCTUnwrap(CarCatalogVerifier.newest([v1, bad, v3], publicKey: pub(key), now: now))
        XCTAssertEqual(best.catalog.version, 3)
        XCTAssertEqual(best.index, 2)
        XCTAssertNil(CarCatalogVerifier.newest([bad, Data()], publicKey: pub(key), now: now))
    }

    func testFutureRefused() throws {
        let key = Curve25519.Signing.PrivateKey()
        var p = payload()
        p["issued"] = now.timeIntervalSince1970 + 3 * 86400
        guard case .failure(let e) = CarCatalogVerifier.verify(try envelope(p, key: key), publicKey: pub(key), now: now) else {
            return XCTFail("accepted")
        }
        XCTAssertEqual(e, .fromTheFuture)
    }
}
