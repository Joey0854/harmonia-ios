import CryptoKit
import Foundation

/*
 Remote car presets (App/CarProbe.swift fetches them): the server answers
   { "payload": "<base64 of UTF-8 JSON {version, name, note, car, device, issued}>",
     "sig": "<base64 Ed25519 signature over the payload bytes>" }
 A preset is only used when the signature checks out against `CarProbe.presetPublicKey`, it is
 meant for this device, its version is newer than the one already taken, it was not issued more
 than a day in the future, and its car settings pass the whitelist below (unknown fields are
 dropped, every number must be finite, then everything is clamped to the ranges of
 CarBandParams.clamped()). The payload's issued is ISO 8601 ("2026-11-11T02:47:18Z"; Unix seconds
 or milliseconds are taken too). `car` is the page's carMixSetting().car format
 { tracks, amb, early, xover } (gain and piano are also accepted, as carNormalize keeps them):
   tracks { vocals|drums|bass|other: { gain, pan, send, rear, width } }, piano { pan, send, rear, width },
   amb { on, db, rt60, pre, lo, hi, hf, lowFront, split, style, gate, dryGate },
   early { on, db, min, max }, xover
 */
extension CarProbe {
    /// Raw 32-byte Ed25519 public key, base64 (only the public half; the server signs). A key
    /// that starts with "PLACEHOLDER" refuses every preset.
    public static let presetPublicKey = "fMB5LG+2ic8MWes0r8LymRon3Hsa/wh0BR4A7dlYoAE="
}

public struct CarRemotePreset {
    public let version: Int
    public let name: String
    public let note: String
    public let device: String
    public let issued: Date
    /// whitelisted and clamped, in the page's format
    public let car: [String: Any]
}

public enum CarPresetError: Error, Equatable, CustomStringConvertible {
    case noKey
    case badEnvelope
    case badSignature
    case badPayload(String)
    case wrongDevice
    case notNewer(Int)
    case fromTheFuture
    case badSettings(String)

    public var description: String {
        switch self {
        case .noKey: return "no public key configured (placeholder)"
        case .badEnvelope: return "not {payload, sig} in base64"
        case .badSignature: return "signature does not verify"
        case .badPayload(let why): return "payload: \(why)"
        case .wrongDevice: return "preset is for another device"
        case .notNewer(let v): return "version \(v) is not newer"
        case .fromTheFuture: return "issued more than a day in the future"
        case .badSettings(let field): return "car settings: \(field)"
        }
    }
}

public enum CarPresetVerifier {
    /// Checks a server answer; see the top of this file.
    public static func verify(_ data: Data, publicKey: String = CarProbe.presetPublicKey, device: String,
                              knownVersion: Int, now: Date = Date()) -> Result<CarRemotePreset, CarPresetError> {
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
        guard let vn = obj["version"] as? NSNumber, !isBool(vn), vn.doubleValue.isFinite,
              vn.doubleValue == vn.doubleValue.rounded(), vn.doubleValue >= 1, vn.doubleValue < 1e12 else {
            return .failure(.badPayload("version"))
        }
        let version = vn.intValue
        guard let dev = obj["device"] as? String, !dev.isEmpty else { return .failure(.badPayload("device")) }
        guard dev == device else { return .failure(.wrongDevice) }
        guard version > knownVersion else { return .failure(.notNewer(version)) }
        guard let issued = date(obj["issued"]) else { return .failure(.badPayload("issued")) }
        guard issued.timeIntervalSince(now) <= 86400 else { return .failure(.fromTheFuture) }
        if obj["name"] != nil && !(obj["name"] is String) { return .failure(.badPayload("name")) }
        if obj["note"] != nil && !(obj["note"] is String) { return .failure(.badPayload("note")) }
        let name = String((obj["name"] as? String ?? "").prefix(40))
        let note = String((obj["note"] as? String ?? "").prefix(400))
        guard let car = obj["car"] as? [String: Any] else { return .failure(.badPayload("car")) }
        switch sanitize(car) {
        case .failure(let e): return .failure(e)
        case .success(let clean):
            return .success(CarRemotePreset(version: version, name: name, note: note, device: dev, issued: issued, car: clean))
        }
    }

    /// Unix seconds (or milliseconds), or an ISO 8601 text.
    static func date(_ v: Any?) -> Date? {
        if let n = v as? NSNumber, !isBool(n), n.doubleValue.isFinite, n.doubleValue > 0 {
            let s = n.doubleValue > 1e11 ? n.doubleValue / 1000 : n.doubleValue
            return Date(timeIntervalSince1970: s)
        }
        if let t = v as? String {
            let f = ISO8601DateFormatter()
            if let d = f.date(from: t) { return d }
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: t)
        }
        return nil
    }

    static func isBool(_ n: NSNumber) -> Bool {
        return CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID()
    }

    /// v2b's values (CarBandParams.v2b and the page's CAR_PRESETS.v2b) for what a preset leaves out.
    static let trackDefaults: [String: (pan: Double, send: Double, rear: Bool, width: Double)] = [
        "drums": (-2, -40, true, 0), "bass": (0, -40, true, 0), "other": (6, 0, true, 1), "vocals": (0, -10, true, 0)
    ]

    /// Whitelists, checks and clamps car settings in the page's format. Kept free of the band
    /// code (CarBand.swift may be left out of a build); the ranges are those of
    /// CarBandParams.clamped(), which CarPresetTests compares.
    public static func sanitize(_ car: [String: Any]) -> Result<[String: Any], CarPresetError> {
        var bad: String?
        func number(_ dict: [String: Any], _ key: String, _ path: String) -> Double? {
            guard let v = dict[key] else { return nil }
            guard let n = v as? NSNumber, !isBool(n), n.doubleValue.isFinite, abs(n.doubleValue) < 1e6 else {
                if bad == nil { bad = path + "." + key }
                return nil
            }
            return n.doubleValue
        }
        func flag(_ dict: [String: Any], _ key: String, _ path: String) -> Bool? {
            guard let v = dict[key] else { return nil }
            guard let n = v as? NSNumber, isBool(n) else {
                if bad == nil { bad = path + "." + key }
                return nil
            }
            return n.boolValue
        }
        func object(_ dict: [String: Any], _ key: String) -> [String: Any] {
            guard let v = dict[key] else { return [:] }
            guard let o = v as? [String: Any] else {
                if bad == nil { bad = key }
                return [:]
            }
            return o
        }
        /* rounded to 1/1000 after clamping; a NaN cannot get here (number() refuses it) */
        func c(_ v: Double, _ lo: Double, _ hi: Double) -> Double { return (min(hi, max(lo, v)) * 1000).rounded() / 1000 }

        let trackIn = object(car, "tracks")
        var outTracks: [String: Any] = [:]
        for name in ["drums", "bass", "other", "vocals"] {
            let d = trackDefaults[name]!
            var t: [String: Any] = [:]
            if let v = trackIn[name] {
                if let o = v as? [String: Any] { t = o } else if bad == nil { bad = "tracks." + name }
            }
            let path = "tracks." + name
            /* solo and mute are never taken from a remote preset */
            outTracks[name] = [
                "gain": c(number(t, "gain", path) ?? 0, -30, 3),
                "pan": c(number(t, "pan", path) ?? d.pan, -12, 12),
                "send": c(number(t, "send", path) ?? d.send, -40, 6),
                "rear": flag(t, "rear", path) ?? d.rear,
                "width": c(number(t, "width", path) ?? d.width, 0, 2),
                "solo": false, "mute": false
            ] as [String: Any]
        }
        let pianoIn = object(car, "piano")
        let piano: [String: Any] = [
            "pan": c(number(pianoIn, "pan", "piano") ?? -6, -12, 12),
            "send": c(number(pianoIn, "send", "piano") ?? 0, -40, 6),
            "rear": flag(pianoIn, "rear", "piano") ?? true,
            "width": c(number(pianoIn, "width", "piano") ?? 0, 0, 2)
        ]
        let a = object(car, "amb")
        var style = "decorrelated"
        if let s = a["style"] {
            if let text = s as? String, ["decorrelated", "half", "anti"].contains(text) { style = text } else if bad == nil { bad = "amb.style" }
        }
        let lo = c(number(a, "lo", "amb") ?? 250, 120, 1000)
        let amb: [String: Any] = [
            "on": flag(a, "on", "amb") ?? true,
            "db": c(number(a, "db", "amb") ?? -15, -30, -3),
            "rt60": c(number(a, "rt60", "amb") ?? 1.4, 0.3, 3),
            "pre": c(number(a, "pre", "amb") ?? 12, 12, 80),
            "lo": lo,
            "hi": c(number(a, "hi", "amb") ?? 4000, max(1500, lo * 2), 10000),
            "hf": c(number(a, "hf", "amb") ?? 1, 0.25, 2),
            "lowFront": flag(a, "lowFront", "amb") ?? false,
            "split": c(number(a, "split", "amb") ?? 250, 80, 500),
            "style": style,
            "gate": c(number(a, "gate", "amb") ?? 1, 0, 1),
            "dryGate": flag(a, "dryGate", "amb") ?? false
        ]
        let e = object(car, "early")
        let e0 = c(number(e, "min", "early") ?? 15, 5, 60)
        let early: [String: Any] = [
            "on": flag(e, "on", "early") ?? false,
            "db": c(number(e, "db", "early") ?? -10, -30, -3),
            "min": e0,
            "max": c(number(e, "max", "early") ?? 30, e0, 80)
        ]
        let xover = c(number(car, "xover", "car") ?? 150, 60, 300)
        if let field = bad { return .failure(.badSettings(field)) }
        return .success(["tracks": outTracks, "piano": piano, "amb": amb, "early": early, "xover": xover])
    }
}
