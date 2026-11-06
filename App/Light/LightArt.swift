import Foundation
import UIKit

/// Each song's light colours (LightPalette), main queue only.
///
/// From the cover art the page names (`{cmd:'lightArt', id, url}`): downloaded once, kept in
/// `Caches/lightart/<id>` (the last 50), made small (48 × 48) and read for its colours. Covers
/// without colour, covers that cannot be had, and songs without a cover get a colour from their
/// sound instead (the light envelope's reference levels), as soon as that envelope exists.
/// Only used while the music light is on.
final class LightArt {
    static let shared = LightArt()

    /// A song's palette is known (id, palette); once per song.
    var onPalette: ((String, LightPalette) -> Void)?

    private static let keep = 50
    private let folder: URL
    private let work = DispatchQueue(label: "light-art", qos: .utility)
    private var palettes: [String: LightPalette] = [:]
    private var order: [String] = []
    private var requested = Set<String>()
    private var busy = Set<String>()
    /// Songs waiting for their light envelope to get a colour from their sound.
    private var waitingForSound = Set<String>()

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        folder = caches.appendingPathComponent("lightart", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func palette(_ id: String) -> LightPalette? {
        return palettes[id]
    }

    func wasRequested(_ id: String) -> Bool {
        return requested.contains(id) || palettes[id] != nil
    }

    /// The page names a song's cover.
    func request(id: String, url text: String) {
        guard StreamCache.isSafe(id: id) else { return }
        if palettes[id] != nil || busy.contains(id) { return }
        requested.insert(id)
        if requested.count > 500 { requested.removeAll() }
        let file = folder.appendingPathComponent(id)
        busy.insert(id)
        if FileManager.default.fileExists(atPath: file.path) {
            work.async {
                let data = try? Data(contentsOf: file)
                self.read(id: id, data: data, origin: "cache")
            }
            return
        }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            busy.remove(id)
            Diag.shared.log("light art: not a web address (\(text.prefix(40))), using the sound", song: id)
            fromSound(id)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data = data, error == nil, status == 200, !data.isEmpty else {
                let why = error.map { "\($0.localizedDescription)" } ?? "HTTP \(status)"
                DispatchQueue.main.async {
                    self.busy.remove(id)
                    Diag.shared.log("light art download failed: \(why), using the sound", error: true, song: id)
                    self.fromSound(id)
                }
                return
            }
            try? data.write(to: file, options: .atomic)
            self.trimCache()
            self.read(id: id, data: data, origin: "download")
        }.resume()
    }

    /// Work queue: the cover's colours.
    private func read(id: String, data: Data?, origin: String) {
        var palette: LightPalette?
        var vividNote = "unreadable image"
        if let data = data, let pixels = LightArt.smallPixels(data, side: 48) {
            palette = LightPalette.fromCover(rgba: pixels, width: 48, height: 48)
            if palette == nil { vividNote = "too little colour" }
        }
        DispatchQueue.main.async {
            self.busy.remove(id)
            if let p = palette {
                self.store(id, p)
            } else {
                Diag.shared.log("light art (\(origin)): \(vividNote), using the sound", song: id)
                self.fromSound(id)
            }
        }
    }

    /// A colour from the song's sound; waits for its light envelope when there is none yet.
    func fromSound(_ id: String) {
        if palettes[id] != nil { return }
        guard let url = SongAnalyzer.lightURL(id), let data = try? Data(contentsOf: url),
              let envelope = LightEnvelope(data: data) else {
            waitingForSound.insert(id)
            return
        }
        waitingForSound.remove(id)
        store(id, LightPalette.fromAudio(bassRef: Double(envelope.bassRef), midRef: Double(envelope.midRef)))
    }

    /// A light envelope has just been written.
    func envelopeReady(_ id: String) {
        if waitingForSound.contains(id) { fromSound(id) }
    }

    private func store(_ id: String, _ p: LightPalette) {
        if palettes[id] != nil { return }
        palettes[id] = p
        order.append(id)
        if order.count > LightArt.keep { palettes[order.removeFirst()] = nil }
        Diag.shared.log(p.describe(id), song: id)
        onPalette?(id, p)
    }

    /// Keeps the newest files of the cover cache.
    private func trimCache() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > LightArt.keep else { return }
        let dated = files.map { url -> (URL, Date) in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return (url, date)
        }.sorted { $0.1 > $1.1 }
        for (url, _) in dated.dropFirst(LightArt.keep) { try? fm.removeItem(at: url) }
    }

    /// The image drawn into a small square, as RGBA bytes; nil when it cannot be decoded.
    static func smallPixels(_ data: Data, side: Int) -> [UInt8]? {
        guard let image = UIImage(data: data)?.cgImage,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? pixels : nil
    }
}
