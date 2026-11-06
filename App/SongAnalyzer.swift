import Foundation

/// Listens through a song file once, in the background, and keeps two things about it:
/// its loudness (for loudness balancing; remembered per song id) and its envelope file
/// `Caches/env/<id>.bin` (served to the page as `ytm-app://local/env/<id>.bin`).
///
/// Use from the main queue; `onLoudness` is called there.
final class SongAnalyzer {
    static let shared = SongAnalyzer()

    /// A song has just been measured (id, LUFS).
    var onLoudness: ((String, Double) -> Void)?
    /// A song's real length in seconds has just been counted (id, seconds).
    var onLength: ((String, Double) -> Void)?
    /// A song's light envelope has just been written (id). Only when `wantLight` is on.
    var onLight: ((String) -> Void)?
    /// A song's parts (where its main part starts and ends ...) have been found, for mixing.
    var onStructure: ((String, MixAnalysis) -> Void)?
    private var structured = Set<String>()
    /// The music light is on: also make each song's light envelope (`Caches/lightenv/<id>.bin`).
    /// Off = nothing about the analysis changes.
    var wantLight = false

    private static let storeKey = "lufsBySong"
    private static let maxRemembered = 3000

    private let queue = DispatchQueue(label: "song-analyzer", qos: .utility)
    private var known: [String: Double]
    /// Real lengths in seconds, counted while listening through. Not kept over restarts.
    private var lengths: [String: Double] = [:]
    private var busy = Set<String>()
    /// Songs whose analysis failed and has been tried a second time.
    private var triedAgain = Set<String>()
    private let envFolder: URL

    private init() {
        known = UserDefaults.standard.dictionary(forKey: SongAnalyzer.storeKey) as? [String: Double] ?? [:]
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        envFolder = caches.appendingPathComponent("env", isDirectory: true)
        try? FileManager.default.createDirectory(at: envFolder, withIntermediateDirectories: true)
    }

    /// The envelope file of a song, whether it exists or not; nil for an id that cannot be a
    /// file name.
    static func envelopeURL(_ id: String) -> URL? {
        guard StreamCache.isSafe(id: id) else { return nil }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("env", isDirectory: true).appendingPathComponent(id + ".bin")
    }

    /// The light envelope file of a song, whether it exists or not.
    static func lightURL(_ id: String) -> URL? {
        guard StreamCache.isSafe(id: id) else { return nil }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("lightenv", isDirectory: true).appendingPathComponent(id + ".bin")
    }

    func loudness(_ id: String) -> Double? {
        return known[id]
    }

    /// The song's real length, when it has been listened through since the app started.
    func length(_ id: String) -> Double? {
        return lengths[id]
    }

    /// Measures the song unless that has been done (or is being done) already.
    func analyze(id: String, file: URL) {
        guard StreamCache.isSafe(id: id), !busy.contains(id) else { return }
        let envelope = envFolder.appendingPathComponent(id + ".bin")
        let needEnvelope = !FileManager.default.fileExists(atPath: envelope.path)
        let lightFile: URL? = wantLight ? SongAnalyzer.lightURL(id).flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? nil : $0
        } : nil
        if known[id] != nil && !needEnvelope && lengths[id] != nil && lightFile == nil && structured.contains(id) { return }
        busy.insert(id)
        queue.async {
            let started = Date()
            var lufs: Double?
            var seconds = 0.0
            var problem: String?
            var lightNote: String?
            var structure: MixAnalysis?
            do {
                let decoder = try SongDecoder(url: file)
                decoder.onReopen = { message in Diag.shared.log("analysis: " + message, song: id) }
                var meter: LoudnessMeter?
                var maker: EnvelopeMaker?
                var lightMaker: LightEnvelopeMaker?
                var track: LevelTrack?
                while let piece = try decoder.next() {
                    if meter == nil {
                        meter = LoudnessMeter(sampleRate: decoder.sampleRate)
                        if needEnvelope { maker = EnvelopeMaker(sampleRate: Int(decoder.sampleRate.rounded())) }
                        if lightFile != nil { lightMaker = LightEnvelopeMaker(sampleRate: decoder.sampleRate) }
                        track = LevelTrack(sampleRate: decoder.sampleRate)
                    }
                    meter?.add(left: piece.left, right: piece.right)
                    lightMaker?.add(left: piece.left, right: piece.right)
                    track?.add(left: piece.left, right: piece.right)
                    if let m = maker {
                        var mono = [Float](repeating: 0, count: piece.left.count)
                        for i in 0..<mono.count { mono[i] = (piece.left[i] + piece.right[i]) / 2 }
                        m.add(mono: mono)
                    }
                }
                lufs = meter?.integrated()
                if let t = track { structure = MixStructure.analyze(levels: t.finish()) }
                if decoder.sampleRate > 0 { seconds = Double(decoder.framesRead) / decoder.sampleRate }
                if let m = maker {
                    let bytes = m.finish()
                    if !bytes.isEmpty { try bytes.write(to: envelope, options: .atomic) }
                }
                if let m = lightMaker, let url = lightFile {
                    let light = m.finish()
                    if !light.bass.isEmpty {
                        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try light.data().write(to: url, options: .atomic)
                        lightNote = String(format: "light envelope: %d frames, bass ref %.4f, mid ref %.4f, onset ref %.3f",
                                           light.bass.count, Double(light.bassRef), Double(light.midRef), Double(light.onsetRef))
                    }
                }
            } catch {
                problem = "\(error)"
            }
            let took = Date().timeIntervalSince(started)
            DispatchQueue.main.async {
                self.busy.remove(id)
                if let problem = problem {
                    Diag.shared.log("analysis failed: \(problem)", error: true, song: id)
                    /* One interrupted read must not leave the song without its loudness for
                       good: once more, a little later. */
                    if !self.triedAgain.contains(id) {
                        self.triedAgain.insert(id)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.analyze(id: id, file: file) }
                    }
                    return
                }
                self.triedAgain.remove(id)
                let result = lufs.map { String(format: "%.1f LUFS", $0) } ?? "no loudness"
                let tookText = String(format: "%.2f", took)
                Diag.shared.log("analysed in \(tookText) s, \(Int(seconds)) s of sound: \(result)", song: id)
                if let note = lightNote {
                    Diag.shared.log("light " + note, song: id)
                    self.onLight?(id)
                }
                if let s = structure {
                    self.structured.insert(id)
                    self.onStructure?(id, s)
                }
                if seconds > 1 {
                    if self.lengths.count >= SongAnalyzer.maxRemembered { self.lengths.removeAll() }
                    self.lengths[id] = seconds
                    self.onLength?(id, seconds)
                }
                /* Same sanity limits as the PC server. */
                guard let value = lufs, value > -60, value < 5 else { return }
                if self.known.count >= SongAnalyzer.maxRemembered { self.known.removeAll() }
                self.known[id] = value
                UserDefaults.standard.set(self.known, forKey: SongAnalyzer.storeKey)
                self.onLoudness?(id, value)
            }
        }
    }
}
