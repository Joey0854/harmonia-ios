import CryptoKit
import XCTest
import SoundCore

/// Remote car presets (App/Sound/CarPreset.swift), signed with a key pair made for the test.
final class CarPresetTests: XCTestCase {
    private let device = "11111111-2222-3333-4444-555555555555"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func envelope(_ payload: [String: Any], key: Curve25519.Signing.PrivateKey, tamper: Bool = false) throws -> Data {
        var bytes = try JSONSerialization.data(withJSONObject: payload)
        let sig = try key.signature(for: bytes)
        if tamper { bytes.append(contentsOf: Array(" ".utf8)) }
        return try JSONSerialization.data(withJSONObject: ["payload": bytes.base64EncodedString(), "sig": sig.base64EncodedString()])
    }

    private func payload(version: Int = 3, device: String? = nil, issued: Any? = nil, car: [String: Any]? = nil) -> [String: Any] {
        return [
            "version": version, "name": "C43 試聽", "note": "後窗多一點", "device": device ?? self.device,
            "issued": issued ?? now.timeIntervalSince1970,
            "car": car ?? [
                "tracks": ["vocals": ["pan": 50, "send": -6, "rear": true, "solo": true, "mute": true, "evil": "x"],
                           "other": ["width": 1.5, "gain": -40]],
                "amb": ["db": -12, "style": "half", "rt60": 9],
                "xover": 120,
                "unknown": ["anything": 1]
            ]
        ]
    }

    private func publicKey(_ key: Curve25519.Signing.PrivateKey) -> String {
        return key.publicKey.rawRepresentation.base64EncodedString()
    }

    func testPlaceholderKeyRefusesEverything() throws {
        let key = Curve25519.Signing.PrivateKey()
        let data = try envelope(payload(), key: key)
        guard case .failure(let e) = CarPresetVerifier.verify(data, publicKey: "PLACEHOLDER_KEY", device: device, knownVersion: 0, now: now) else {
            return XCTFail("accepted with a placeholder key")
        }
        XCTAssertEqual(e, .noKey)
    }

    /// The key built into the app is a usable Ed25519 key, and refuses what someone else signed.
    func testBuiltInKey() throws {
        let raw = try XCTUnwrap(Data(base64Encoded: CarProbe.presetPublicKey))
        XCTAssertEqual(raw.count, 32)
        XCTAssertNoThrow(try Curve25519.Signing.PublicKey(rawRepresentation: raw))
        let data = try envelope(payload(), key: Curve25519.Signing.PrivateKey())
        guard case .failure(let e) = CarPresetVerifier.verify(data, device: device, knownVersion: 0, now: now) else {
            return XCTFail("accepted a foreign signature")
        }
        XCTAssertEqual(e, .badSignature)
    }

    func testIsoIssuedAndPageFormat() throws {
        let key = Curve25519.Signing.PrivateKey()
        let iso = Date(timeIntervalSince1970: 1_794_365_238)   // 2026-11-11T02:47:18Z
        let car: [String: Any] = ["tracks": ["vocals": ["pan": 0, "send": -6, "rear": true, "width": 0]],
                                  "amb": ["on": true, "db": -14, "style": "anti"], "early": ["on": true], "xover": 150]
        let data = try envelope(payload(issued: "2026-11-11T02:47:18Z", car: car), key: key)
        let result = CarPresetVerifier.verify(data, publicKey: publicKey(key), device: device, knownVersion: 0, now: iso)
        guard case .success(let p) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(p.issued, iso)
        XCTAssertEqual((p.car["amb"] as? [String: Any])?["style"] as? String, "anti")
        XCTAssertEqual((p.car["early"] as? [String: Any])?["on"] as? Bool, true)
    }

    /// The whitelist clamps to exactly the ranges of CarBandParams.clamped() (kept apart so that
    /// a build without the band code still has it) and fills in v2b.
    func testRangesMatchCarBandParams() {
        func sanitized(_ v: Double) -> [String: Any] {
            let t: [String: Any] = ["pan": v, "send": v, "width": v]
            let car: [String: Any] = [
                "tracks": ["drums": t, "bass": t, "other": t, "vocals": t],
                "amb": ["db": v, "rt60": v, "pre": v, "lo": v, "hi": v, "hf": v, "split": v, "gate": v],
                "early": ["db": v, "min": v, "max": v], "xover": v
            ]
            guard case .success(let out) = CarPresetVerifier.sanitize(car) else { XCTFail("refused"); return [:] }
            return out
        }
        for v in [-1e5, 1e5] {
            let f = Float(v)
            let ref = CarBandParams(tracks: Array(repeating: CarBandTrack(panDb: f, sendDb: f, rear: true, width: f), count: 4),
                                    ambienceDb: f, rt60: f, predelayMs: f, lowHz: f, highHz: f, crossoverHz: f,
                                    earlyDb: f, earlyMinMs: f, earlyMaxMs: f, hfDamping: f, lowSplitHz: f, sendGate: f).clamped()
            let out = sanitized(v)
            let tr = (out["tracks"] as? [String: Any])?["vocals"] as? [String: Any] ?? [:]
            let amb = out["amb"] as? [String: Any] ?? [:]
            let early = out["early"] as? [String: Any] ?? [:]
            let pairs: [(Any?, Float, String)] = [
                (tr["pan"], ref.tracks[3].panDb, "pan"), (tr["send"], ref.tracks[3].sendDb, "send"), (tr["width"], ref.tracks[3].width, "width"),
                (amb["db"], ref.ambienceDb, "amb.db"), (amb["rt60"], ref.rt60, "rt60"), (amb["pre"], ref.predelayMs, "pre"),
                (amb["lo"], ref.lowHz, "lo"), (amb["hi"], ref.highHz, "hi"), (amb["hf"], ref.hfDamping, "hf"),
                (amb["split"], ref.lowSplitHz, "split"), (amb["gate"], ref.sendGate, "gate"),
                (early["db"], ref.earlyDb, "early.db"), (early["min"], ref.earlyMinMs, "early.min"), (early["max"], ref.earlyMaxMs, "early.max"),
                (out["xover"], ref.crossoverHz, "xover")
            ]
            for (got, want, name) in pairs {
                XCTAssertEqual(got as? Double ?? .nan, Double(want), accuracy: 1e-3, "\(name) at \(v)")
            }
        }
        guard case .success(let empty) = CarPresetVerifier.sanitize([:]) else { return XCTFail("empty refused") }
        let v2b = CarBandParams.v2b
        for (i, name) in Demucs.sources.enumerated() {
            let t = (empty["tracks"] as? [String: Any])?[name] as? [String: Any] ?? [:]
            XCTAssertEqual(t["pan"] as? Double, Double(v2b.tracks[i].panDb), name)
            XCTAssertEqual(t["send"] as? Double, Double(v2b.tracks[i].sendDb), name)
            XCTAssertEqual(t["width"] as? Double, Double(v2b.tracks[i].width), name)
            XCTAssertEqual(t["rear"] as? Bool, v2b.tracks[i].rear, name)
        }
        let amb = empty["amb"] as? [String: Any] ?? [:]
        XCTAssertEqual(amb["db"] as? Double ?? .nan, Double(v2b.ambienceDb), accuracy: 1e-3)
        XCTAssertEqual(amb["rt60"] as? Double ?? .nan, Double(v2b.rt60), accuracy: 1e-3)
        XCTAssertEqual(amb["style"] as? String, v2b.reverbStyle.rawValue)
        XCTAssertEqual(empty["xover"] as? Double ?? .nan, Double(v2b.crossoverHz), accuracy: 1e-3)
    }

    func testSignedPresetIsCheckedAndClamped() throws {
        let key = Curve25519.Signing.PrivateKey()
        let data = try envelope(payload(), key: key)
        let result = CarPresetVerifier.verify(data, publicKey: publicKey(key), device: device, knownVersion: 2, now: now)
        guard case .success(let p) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(p.version, 3)
        XCTAssertEqual(p.name, "C43 試聽")
        XCTAssertEqual(p.note, "後窗多一點")
        XCTAssertNil(p.car["unknown"])
        let tracks = p.car["tracks"] as? [String: Any] ?? [:]
        let vocals = tracks["vocals"] as? [String: Any] ?? [:]
        XCTAssertEqual(vocals["pan"] as? Double, 12)
        XCTAssertEqual(vocals["send"] as? Double, -6)
        XCTAssertEqual(vocals["solo"] as? Bool, false)
        XCTAssertEqual(vocals["mute"] as? Bool, false)
        XCTAssertNil(vocals["evil"])
        let other = tracks["other"] as? [String: Any] ?? [:]
        XCTAssertEqual(other["width"] as? Double, 1.5)
        XCTAssertEqual(other["gain"] as? Double, -30)
        let amb = p.car["amb"] as? [String: Any] ?? [:]
        XCTAssertEqual(amb["db"] as? Double, -12)
        XCTAssertEqual(amb["rt60"] as? Double, 3)
        XCTAssertEqual(amb["style"] as? String, "half")
        XCTAssertEqual(p.car["xover"] as? Double, 120)
        XCTAssertEqual(tracks.count, 4)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(p.car))
    }

    func testRefusals() throws {
        let key = Curve25519.Signing.PrivateKey()
        let pk = publicKey(key)
        func check(_ data: Data, known: Int = 0, _ want: CarPresetError, line: UInt = #line) {
            guard case .failure(let e) = CarPresetVerifier.verify(data, publicKey: pk, device: device, knownVersion: known, now: now) else {
                return XCTFail("accepted", line: line)
            }
            XCTAssertEqual(e, want, line: line)
        }
        try check(envelope(payload(), key: key, tamper: true), .badSignature)
        try check(envelope(payload(), key: Curve25519.Signing.PrivateKey()), .badSignature)
        try check(envelope(payload(device: "someone-else"), key: key), .wrongDevice)
        try check(envelope(payload(version: 3), key: key), known: 3, .notNewer(3))
        try check(envelope(payload(issued: now.timeIntervalSince1970 + 2 * 86400), key: key), .fromTheFuture)
        try check(envelope(payload(car: ["xover": "120"]), key: key), .badSettings("car.xover"))
        try check(envelope(payload(car: ["amb": ["on": 1]]), key: key), .badSettings("amb.on"))
        check(Data("not json".utf8), .badEnvelope)
        /* half a day ahead (clocks differ) and milliseconds are fine */
        let soon = try envelope(payload(issued: (now.timeIntervalSince1970 + 43200) * 1000), key: key)
        if case .failure(let e) = CarPresetVerifier.verify(soon, publicKey: pk, device: device, knownVersion: 0, now: now) {
            XCTFail("\(e)")
        }
    }

    func testNonFiniteNumbersAreRefused() {
        guard case .failure(let e) = CarPresetVerifier.sanitize(["amb": ["db": Double.infinity]]) else {
            return XCTFail("accepted infinity")
        }
        XCTAssertEqual(e, .badSettings("amb.db"))
        guard case .failure = CarPresetVerifier.sanitize(["tracks": ["bass": ["pan": Double.nan]]]) else {
            return XCTFail("accepted NaN")
        }
        guard case .success(let empty) = CarPresetVerifier.sanitize([:]) else { return XCTFail("empty refused") }
        XCTAssertEqual((empty["tracks"] as? [String: Any])?.count, 4)
    }
}
