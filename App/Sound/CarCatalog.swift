import CryptoKit
import Foundation

/*
 The list of cars the user can pick from (App/CarProbe.swift loads it; the page shows it).
 Same envelope and Ed25519 key as the remote presets (CarPreset.swift):
   { "payload": "<base64 of UTF-8 JSON>", "sig": "<base64 Ed25519 signature over the payload bytes>" }
 payload:
   { "version": 1, "issued": "2026-11-11T00:00:00Z",
     "cars": [ { "id": "mazda3-bp-bose", "make": "Mazda", "model": "3 (BP)", "system": "Bose",
                 "kind": "plain" | "bose" | "rearSplit" | "manual", "calibrated": false,
                 "preset": { car settings in the page's format } | null }, ... ] }
 Where it comes from: Web/car_catalog.json in the app bundle, and GET <server>/carprobe/catalog
 (the newest verified one is cached). A catalog is used only when its signature verifies; each
 car's preset then goes through CarPresetVerifier.sanitize (whitelist and clamps). A car whose
 preset is refused is kept without a preset; an entry that is not understood is dropped.
 */
public struct CarCatalogEntry {
    public let id: String
    public let make: String
    public let model: String
    public let system: String
    public let kind: String
    public let calibrated: Bool
    /// whitelisted and clamped; nil: not calibrated yet ("尚未校正，請測量")
    public let preset: [String: Any]?

    /// for the page
    public var json: [String: Any] {
        var o: [String: Any] = ["id": id, "make": make, "model": model, "system": system, "kind": kind, "calibrated": calibrated]
        o["preset"] = preset.map { $0 as Any } ?? NSNull()
        return o
    }
}

public struct CarCatalog {
    public let version: Int
    public let issued: Date
    public let cars: [CarCatalogEntry]
}

public enum CarCatalogVerifier {
    public static let maxBytes = 512 * 1024
    public static let maxCars = 500
    static let kinds: Set<String> = ["plain", "bose", "rearSplit", "manual"]

    /// Checks a signed catalog (bundled, cached or from the server).
    public static func verify(_ data: Data, publicKey: String = CarProbe.presetPublicKey, now: Date = Date()) -> Result<CarCatalog, CarPresetError> {
        guard data.count <= maxBytes else { return .failure(.badEnvelope) }
        guard !publicKey.hasPrefix("PLACEHOLDER"),
              let raw = Data(base64Encoded: publicKey), raw.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return .failure(.noKey) }
        guard let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let p64 = envelope["payload"] as? String, let s64 = envelope["sig"] as? String,
              let payload = Data(base64Encoded: p64), let sig = Data(base64Encoded: s64) else { return .failure(.badEnvelope) }
        guard key.isValidSignature(sig, for: payload) else { return .failure(.badSignature) }
        guard let obj = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else {
            return .failure(.badPayload("not a JSON object"))
        }
        guard let vn = obj["version"] as? NSNumber, !CarPresetVerifier.isBool(vn), vn.doubleValue.isFinite,
              vn.doubleValue == vn.doubleValue.rounded(), vn.doubleValue >= 1, vn.doubleValue < 1e12 else {
            return .failure(.badPayload("version"))
        }
        guard let issued = CarPresetVerifier.date(obj["issued"]) else { return .failure(.badPayload("issued")) }
        guard issued.timeIntervalSince(now) <= 86400 else { return .failure(.fromTheFuture) }
        guard let list = obj["cars"] as? [Any] else { return .failure(.badPayload("cars")) }
        var cars: [CarCatalogEntry] = []
        var seen = Set<String>()
        for item in list.prefix(maxCars) {
            guard let c = item as? [String: Any] else { continue }
            func text(_ key: String, _ limit: Int) -> String? {
                guard let s = c[key] as? String else { return nil }
                return String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
            }
            guard let id = text("id", 64), !id.isEmpty, !seen.contains(id),
                  let kind = c["kind"] as? String, kinds.contains(kind) else { continue }
            var preset: [String: Any]? = nil
            if let p = c["preset"] as? [String: Any], case .success(let clean) = CarPresetVerifier.sanitize(p) {
                preset = clean
            }
            let calibrated = (c["calibrated"] as? NSNumber).map { CarPresetVerifier.isBool($0) && $0.boolValue } ?? false
            seen.insert(id)
            cars.append(CarCatalogEntry(id: id, make: text("make", 40) ?? "", model: text("model", 60) ?? "",
                                        system: text("system", 40) ?? "", kind: kind, calibrated: calibrated, preset: preset))
        }
        return .success(CarCatalog(version: vn.intValue, issued: issued, cars: cars))
    }

    /// The newest of the catalogs that verify (nil: none does).
    public static func newest(_ candidates: [Data], publicKey: String = CarProbe.presetPublicKey, now: Date = Date()) -> (catalog: CarCatalog, index: Int)? {
        var best: (catalog: CarCatalog, index: Int)?
        for (i, d) in candidates.enumerated() {
            guard case .success(let c) = verify(d, publicKey: publicKey, now: now) else { continue }
            if best == nil || c.version > best!.catalog.version { best = (c, i) }
        }
        return best
    }
}
