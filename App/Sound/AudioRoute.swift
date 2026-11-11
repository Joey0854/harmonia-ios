import Foundation

/// What kind of output the sound goes to, for the page's automatic sound profile (1.3.23):
/// headphones (wired, Bluetooth, AirPods, USB), the car (CarPlay) or a speaker (everything else:
/// the phone's own speaker, AirPlay, HDMI, line out).
public enum AudioRouteKind: String {
    case headphones, car, speaker
}

/// The output route as the page is told about it. Kept free of AVAudioSession (which the
/// package cannot use on a Mac): the app passes each output's port type raw value and name.
public struct AudioRouteInfo: Equatable {
    public var kind: AudioRouteKind
    /// The car's name as CarPlay reports it (the port name), trimmed; empty for other kinds.
    public var name: String
    /// The port type of the output the kind was read from ("" without any output).
    public var port: String

    public init(kind: AudioRouteKind, name: String, port: String) {
        self.kind = kind
        self.name = name
        self.port = port
    }

    /// For the page: {"type": "route", "kind": ..., "name": ..., "port": ...}.
    public var event: [String: Any] {
        return ["type": "route", "kind": kind.rawValue, "name": name, "port": port]
    }
}

public enum AudioRoute {
    /// AVAudioSession.Port raw values. The app passes the constants' own raw values, so these
    /// defaults only matter to the tests.
    public static let carTypes: Set<String> = ["CarAudio"]
    public static let headphoneTypes: Set<String> = ["Headphones", "BluetoothA2DPOutput", "BluetoothLE", "BluetoothHFP", "USBAudio"]

    /// The kind of the current route. The car wins over everything (CarPlay can come with other
    /// outputs listed), then headphones; anything else is a speaker.
    public static func classify(_ outputs: [(type: String, name: String)],
                                carTypes: Set<String> = AudioRoute.carTypes,
                                headphoneTypes: Set<String> = AudioRoute.headphoneTypes) -> AudioRouteInfo {
        if let car = outputs.first(where: { carTypes.contains($0.type) }) {
            return AudioRouteInfo(kind: .car, name: cleanName(car.name), port: car.type)
        }
        if let head = outputs.first(where: { headphoneTypes.contains($0.type) }) {
            return AudioRouteInfo(kind: .headphones, name: "", port: head.type)
        }
        return AudioRouteInfo(kind: .speaker, name: "", port: outputs.first?.type ?? "")
    }

    /// A car's name as a key the page can keep: whitespace collapsed, at most 80 characters,
    /// control characters dropped.
    public static func cleanName(_ s: String) -> String {
        let kept = s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let text = String(String.UnicodeScalarView(kept))
        let words = text.split(whereSeparator: { $0.isWhitespace })
        return String(words.joined(separator: " ").prefix(80))
    }
}
