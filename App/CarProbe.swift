import AVFoundation
import UIKit

/*
 "Measure this car" (測量這台車) and the remote car presets.

 The page's wizard (Web/index.html, carProbe*) drives this through the `carProbe` command;
 everything here runs on the main queue except the analysis and the AAC encoding.

 Page -> app:  { cmd: "carProbe", action, ... }
   status                              answered with a status event
   pair      { text }                  "https://<host>#<code>": the server is what comes before
                                       the #, without a trailing slash; kept in UserDefaults
   unpair
   ping                                GET <server>/carprobe/ping, to test the pairing
   begin     { carName }               a new measuring session (drops the unsent one)
   measure   { name, label? }          play the probe, record, analyse (about 15 s); name is one
                                       of positionCodes (center, front-left, ... other), label only
                                       for "other" (the user's own name for it)
   skip      { name, label? }
   cancel                              stops a measurement under way
   upload    { consent: true }         saves the session as a file in Documents/CarProbe/pending,
                                       then sends it; without consent nothing is done
   retry                               sends every saved file again
   presetCheck                         asks the server for a preset now
   presetPending                       sends the preset still waiting for the page, if any
   presetAck { version }               the page has stored this preset version

 App -> page:
   { type: "carProbe", action: "status", paired, server, carName, pending, positions: [{ name, skipped, done }] }
   { type: "carProbe", action: "pair" | "ping", ok, message }
   { type: "carProbe", action: "measure", name, state: "preparing" | "playing" | "analyzing" | "done" |
     "failed" | "cancelled", seconds?, warning?, message?, result? }
       result: { levels: { cellId: dB }, snr?, snrByCell, clipped, input, problems: [..], needsRetake, lowCells }
   { type: "carProbe", action: "upload", state: "sending" | "done" | "failed" | "retrying", message, pending }
   { type: "carPreset", version, name, note, car }   a newer preset from the server (signature, device,
                                                    version and settings checked by CarPresetVerifier);
                                                    the page stores it and answers presetAck

 Server (the coordinator's limits): POST <server>/carprobe/upload, JSON with Content-Length,
 1-16 positions, finite numbers only, strings up to 200 characters, each recording up to 1.5 MB,
 the whole body up to 10 MB; 429 / 503 are retried later. GET <server>/carprobe/preset?device=
 answers 200 with the preset or 404. Every request carries X-Harmonia-Code.
 */
final class CarMeasure {
    static let shared = CarMeasure()

    /// Main queue; set by PlayerViewController.
    var onEvent: (([String: Any]) -> Void)?
    /// Pauses the music before the probe plays.
    var pauseMusic: (() -> Void)?

    private static let serverKey = "carProbeServer"
    private static let codeKey = "carProbeCode"
    private static let presetVersionKey = "carProbePresetVersion"
    private static let presetPendingKey = "carProbePresetPending"
    private static let deviceKey = "carProbeDevice"
    private static let maxPositions = 16
    private static let maxAudioBytes = 1_500_000
    private static let maxBodyBytes = 10_000_000

    /// the position codes the server knows; "other" carries the user's own label
    static let positionCodes: Set<String> = ["center", "front-left", "front-right", "front-left-tweeter",
                                             "front-right-tweeter", "rear-left", "rear-right", "rear-window-left",
                                             "rear-window-right", "rear-center", "other"]

    private struct Position {
        var name: String
        var label: String
        var skipped: Bool
        var levels: [String: Double]
        var quality: [String: Any]
        var audio: URL?
    }

    private var carName = ""
    private var positions: [Position] = []
    private var route: [[String: Any]] = []
    private var run: Recorder?
    private var runToken = 0
    private var wasCar = false
    private var lastPresetCheck = Date.distantPast
    private var uploading = false
    private let work = DispatchQueue(label: "carprobe.work", qos: .userInitiated)

    // MARK: pairing

    static func parsePairing(_ text: String) -> (server: URL, code: String)? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let hash = t.firstIndex(of: "#") else { return nil }
        var base = String(t[..<hash])
        let code = String(t[t.index(after: hash)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !code.isEmpty, code.count <= 200,
              let parts = URLComponents(string: base),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parts.host, !host.isEmpty,
              parts.query == nil, parts.user == nil, parts.password == nil,
              let url = URL(string: base) else { return nil }
        return (url, code)
    }

    private var pairing: (server: URL, code: String)? {
        let d = UserDefaults.standard
        guard let s = d.string(forKey: CarMeasure.serverKey), let url = URL(string: s),
              let code = d.string(forKey: CarMeasure.codeKey), !code.isEmpty else { return nil }
        return (url, code)
    }

    private var deviceId: String {
        if let id = UIDevice.current.identifierForVendor?.uuidString { return id }
        let d = UserDefaults.standard
        if let id = d.string(forKey: CarMeasure.deviceKey) { return id }
        let id = UUID().uuidString
        d.set(id, forKey: CarMeasure.deviceKey)
        return id
    }

    private func request(_ path: String, query: [URLQueryItem] = [], method: String = "GET") -> URLRequest? {
        guard let p = pairing,
              var parts = URLComponents(url: p.server.appendingPathComponent(path), resolvingAgainstBaseURL: false) else { return nil }
        if !query.isEmpty { parts.queryItems = query }
        guard let url = parts.url else { return nil }
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        r.httpMethod = method
        r.setValue(p.code, forHTTPHeaderField: "X-Harmonia-Code")
        return r
    }

    // MARK: start

    /// Once, from PlayerViewController: watches the audio route and asks for a preset at launch.
    func start() {
        wasCar = CarMeasure.isCarAudio()
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.routeChanged()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.checkPreset(why: "launch") }
    }

    private static func isCarAudio() -> Bool {
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .carAudio }
    }

    private func routeChanged() {
        let car = CarMeasure.isCarAudio()
        defer { wasCar = car }
        if run != nil { return }    // our own category change
        if car && !wasCar { checkPreset(why: "route became car audio") }
    }

    // MARK: commands

    func handle(_ body: [String: Any]) {
        let action = body["action"] as? String ?? "status"
        switch action {
        case "status":
            sendStatus()
        case "pair":
            if let p = CarMeasure.parsePairing(body["text"] as? String ?? "") {
                UserDefaults.standard.set(p.server.absoluteString, forKey: CarMeasure.serverKey)
                UserDefaults.standard.set(p.code, forKey: CarMeasure.codeKey)
                Diag.shared.log("carprobe: paired with \(p.server.host ?? "?")")
                emit(["action": "pair", "ok": true, "message": ""])
                sendStatus()
                checkPreset(why: "paired")
            } else {
                Diag.shared.log("carprobe: pairing text not understood", error: true)
                emit(["action": "pair", "ok": false, "message": "看不懂這段字串，格式是 https://主機#配對碼"])
            }
        case "unpair":
            UserDefaults.standard.removeObject(forKey: CarMeasure.serverKey)
            UserDefaults.standard.removeObject(forKey: CarMeasure.codeKey)
            Diag.shared.log("carprobe: pairing removed")
            sendStatus()
        case "ping":
            ping()
        case "begin":
            carName = String((body["carName"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            clearSession()
            Diag.shared.log("carprobe: new session for \"\(carName)\"")
            sendStatus()
        case "measure":
            guard let (name, label) = position(body) else { return }
            measure(name: name, label: label)
        case "skip":
            guard let (name, label) = position(body) else { return }
            store(Position(name: name, label: label, skipped: true, levels: [:], quality: [:], audio: nil))
            Diag.shared.log("carprobe: \(name) \(label) skipped")
            sendStatus()
        case "cancel":
            cancel()
        case "upload":
            guard body["consent"] as? Bool == true else {
                emit(["action": "upload", "state": "failed", "message": "需要先同意上傳", "pending": pendingFiles().count])
                return
            }
            upload()
        case "retry":
            sendPending(attempt: 0)
        case "presetCheck":
            checkPreset(why: "asked", force: true)
        case "presetPending":
            if let data = UserDefaults.standard.data(forKey: CarMeasure.presetPendingKey),
               var e = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                e["type"] = "carPreset"
                onEvent?(e)
            }
        case "presetAck":
            let v = (body["version"] as? NSNumber)?.intValue ?? 0
            let d = UserDefaults.standard
            if v > d.integer(forKey: CarMeasure.presetVersionKey) { d.set(v, forKey: CarMeasure.presetVersionKey) }
            if let data = d.data(forKey: CarMeasure.presetPendingKey),
               let e = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               ((e["version"] as? NSNumber)?.intValue ?? 0) <= v {
                d.removeObject(forKey: CarMeasure.presetPendingKey)
            }
            Diag.shared.log("carprobe: preset version \(v) stored by the page")
        default:
            break
        }
    }

    /// A known position code; "other" needs a label.
    private func position(_ body: [String: Any]) -> (String, String)? {
        let name = body["name"] as? String ?? ""
        let label = String((body["label"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard CarMeasure.positionCodes.contains(name), name != "other" || !label.isEmpty else {
            Diag.shared.log("carprobe: unknown position \(name.prefix(20))", error: true)
            return nil
        }
        return (name, name == "other" ? label : "")
    }

    private func emit(_ e: [String: Any]) {
        var event = e
        event["type"] = "carProbe"
        onEvent?(event)
    }

    private func sendStatus() {
        emit(["action": "status", "paired": pairing != nil, "server": pairing?.server.host ?? "",
              "carName": carName, "pending": pendingFiles().count, "measuring": run != nil,
              "positions": positions.map { ["name": $0.name, "label": $0.label, "skipped": $0.skipped, "done": !$0.skipped] as [String: Any] }])
    }

    private func store(_ p: Position) {
        if let i = positions.firstIndex(where: { $0.name == p.name && $0.label == p.label }) {
            if let old = positions[i].audio, old != p.audio { try? FileManager.default.removeItem(at: old) }
            positions[i] = p
        } else {
            positions.append(p)
        }
    }

    private func clearSession() {
        for p in positions { if let a = p.audio { try? FileManager.default.removeItem(at: a) } }
        positions = []
        route = []
    }

    // MARK: folders

    private static var folder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("CarProbe", isDirectory: true)
    }
    private static var pendingFolder: URL { return folder.appendingPathComponent("pending", isDirectory: true) }
    private static var audioFolder: URL { return folder.appendingPathComponent("audio", isDirectory: true) }

    private func pendingFiles() -> [URL] {
        let list = (try? FileManager.default.contentsOfDirectory(at: CarMeasure.pendingFolder, includingPropertiesForKeys: nil)) ?? []
        return list.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: measuring

    private func describeRoute() -> [[String: Any]] {
        return AVAudioSession.sharedInstance().currentRoute.outputs.map {
            ["portType": $0.portType.rawValue, "portName": String($0.portName.prefix(200)), "channels": $0.channels?.count ?? 0]
        }
    }

    private func measure(name: String, label: String) {
        if run != nil {
            emit(["action": "measure", "name": name, "state": "failed", "message": "已經在量測了"])
            return
        }
        guard positions.count < CarMeasure.maxPositions || positions.contains(where: { $0.name == name && $0.label == label }) else {
            emit(["action": "measure", "name": name, "state": "failed", "message": "最多 \(CarMeasure.maxPositions) 個位置"])
            return
        }
        emit(["action": "measure", "name": name, "state": "preparing"])
        CarMeasure.askMicrophone { [weak self] granted in
            guard let self = self else { return }
            if !granted {
                Diag.shared.log("carprobe: microphone permission refused", error: true)
                self.emit(["action": "measure", "name": name, "state": "failed", "message": "沒有麥克風權限：請到「設定 > Harmonia」打開麥克風"])
                return
            }
            self.startRecording(name: name, label: label)
        }
    }

    private static func askMicrophone(_ done: @escaping (Bool) -> Void) {
        let main: (Bool) -> Void = { ok in DispatchQueue.main.async { done(ok) } }
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: main(true)
            case .denied: main(false)
            default: AVAudioApplication.requestRecordPermission { main($0) }
            }
        } else {
            let s = AVAudioSession.sharedInstance()
            switch s.recordPermission {
            case .granted: main(true)
            case .denied: main(false)
            default: s.requestRecordPermission { main($0) }
            }
        }
    }

    private func startRecording(name: String, label: String) {
        pauseMusic?()
        let playbackRoute = describeRoute()
        Diag.shared.log("carprobe: \(name): output before measuring \(playbackRoute)")
        let s = AVAudioSession.sharedInstance()
        var warning = ""
        do {
            /* A2DP keeps a Bluetooth car's output as it is (and its microphone out of it);
               measurement mode turns the voice processing and automatic gain off. */
            try s.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetoothA2DP, .defaultToSpeaker])
            try s.setActive(true)
        } catch {
            Diag.shared.log("carprobe: audio session for recording: \(error.localizedDescription)", error: true)
            restoreSession()
            emit(["action": "measure", "name": name, "state": "failed", "message": "無法開始錄音：\(error.localizedDescription)"])
            return
        }
        if let mic = s.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            do { try s.setPreferredInput(mic) } catch {
                Diag.shared.log("carprobe: setPreferredInput built-in mic failed: \(error.localizedDescription)", error: true)
                warning = "這台車連線時無法用手機麥克風錄音（無法選擇內建麥克風），仍會嘗試"
            }
        } else {
            Diag.shared.log("carprobe: no built-in microphone among the inputs", error: true)
            warning = "這台車連線時無法用手機麥克風錄音（找不到內建麥克風），仍會嘗試"
        }
        let input = s.currentRoute.inputs.first
        let inputText = input.map { "\($0.portType.rawValue) \"\($0.portName)\"" } ?? "none"
        if input?.portType != .builtInMic && warning.isEmpty {
            warning = "這台車連線時無法用手機麥克風錄音（目前輸入：\(input?.portName ?? "無")），仍會嘗試"
        }
        let during = describeRoute()
        Diag.shared.log("carprobe: \(name): input \(inputText), output while recording \(during), rate \(s.sampleRate)")
        if route.isEmpty { route = during.isEmpty ? playbackRoute : during }

        let recorder = Recorder()
        do {
            try recorder.start()
        } catch {
            Diag.shared.log("carprobe: \(name): could not start: \(error.localizedDescription)", error: true)
            restoreSession()
            emit(["action": "measure", "name": name, "state": "failed", "message": "無法開始錄音：\(error.localizedDescription)"])
            return
        }
        run = recorder
        runToken += 1
        let token = runToken
        var playing: [String: Any] = ["action": "measure", "name": name, "state": "playing", "seconds": (CarProbe.duration * 10).rounded() / 10]
        if !warning.isEmpty { playing["warning"] = warning }
        emit(playing)
        DispatchQueue.main.asyncAfter(deadline: .now() + CarProbe.duration + Recorder.extra) { [weak self] in
            guard let self = self, self.runToken == token, let rec = self.run else { return }
            self.finish(name: name, label: label, recorder: rec, input: inputText, inputWarning: warning)
        }
    }

    private func restoreSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setPreferredInput(nil)
        do {
            try s.setCategory(.playback, mode: .default, options: [])
            try s.setActive(true)
        } catch {
            Diag.shared.log("carprobe: restoring the playback session: \(error.localizedDescription)", error: true)
        }
    }

    private func cancel() {
        guard let rec = run else { return }
        _ = rec.stop()
        run = nil
        runToken += 1
        restoreSession()
        Diag.shared.log("carprobe: measurement cancelled")
        emit(["action": "measure", "state": "cancelled", "name": ""])
    }

    private func finish(name: String, label: String, recorder: Recorder, input: String, inputWarning: String) {
        let samples = recorder.stop()
        let rate = recorder.rate
        run = nil
        restoreSession()
        emit(["action": "measure", "name": name, "state": "analyzing"])
        let fileName = "\(UUID().uuidString.prefix(8))-\(Int(Date().timeIntervalSince1970)).m4a"
        let audioURL = CarMeasure.audioFolder.appendingPathComponent(fileName)
        work.async { [weak self] in
            let result = CarProbeAnalyzer.analyze(samples, sampleRate: rate)
            var audio: URL? = nil
            do {
                try FileManager.default.createDirectory(at: CarMeasure.audioFolder, withIntermediateDirectories: true)
                try CarMeasure.writeM4A(samples, rate: rate, to: audioURL)
                let size = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int) ?? 0
                if size > 0 && size <= CarMeasure.maxAudioBytes {
                    audio = audioURL
                } else {
                    Diag.shared.log("carprobe: \(name): recording is \(size) bytes, not uploaded", error: true)
                    try? FileManager.default.removeItem(at: audioURL)
                }
            } catch {
                Diag.shared.log("carprobe: \(name): AAC encoding failed: \(error.localizedDescription)", error: true)
            }
            DispatchQueue.main.async {
                self?.analysed(name: name, label: label, result: result, samples: samples.count, rate: rate, input: input, inputWarning: inputWarning, audio: audio)
            }
        }
    }

    private func analysed(name: String, label: String, result r: CarProbeResult, samples: Int, rate: Double, input: String,
                          inputWarning: String, audio: URL?) {
        var quality: [String: Any] = [
            "clipped": r.clipped,
            "input": String(input.prefix(200)),
            "sampleRate": rate,
            "seconds": (Double(samples) / max(rate, 1) * 100).rounded() / 100,
            "lowCells": r.lowCells,
            "problems": r.problems.map { String($0.prefix(200)) }
        ]
        func put(_ key: String, _ v: Double?) {
            if let v = v, v.isFinite { quality[key] = (v * 100).rounded() / 100 }
        }
        /* snr: the whole position (the reference cell against the noise in its band) */
        put("snr", r.snrDb)
        quality["snrByCell"] = r.snrByCell.filter { $0.value.isFinite }
        put("peak", r.peak)
        put("latency_s", r.sync == nil ? nil : r.latency)
        put("beep_ncc", r.sync?.ncc)
        put("beep_ratio", r.sync.map { min($0.ratio, 1e6) })
        for (band, db) in r.noise where db.isFinite { quality["noise_\(band)_dbfs"] = (db * 100).rounded() / 100 }
        if !inputWarning.isEmpty { quality["inputWarning"] = String(inputWarning.prefix(200)) }
        let levels = r.levels.filter { $0.value.isFinite }
        store(Position(name: name, label: label, skipped: false, levels: levels, quality: quality, audio: audio))
        let snrText = r.snrDb.map { String(format: "%.1f", $0) } ?? "n/a"
        Diag.shared.log("carprobe: \(name): SNR \(snrText) dB, clipped \(r.clipped), latency \(String(format: "%.3f", r.latency)) s, cells \(levels.count), problems \(r.problems.count)\(r.problems.isEmpty ? "" : ": " + r.problems.joined(separator: " / "))",
                        error: r.needsRetake)
        var shown: [String: Any] = ["levels": levels, "clipped": r.clipped, "input": input, "problems": r.problems,
                                    "needsRetake": r.needsRetake, "lowCells": r.lowCells]
        if let snr = r.snrDb, snr.isFinite { shown["snr"] = (snr * 10).rounded() / 10 }
        shown["snrByCell"] = r.snrByCell.filter { $0.value.isFinite }
        emit(["action": "measure", "name": name, "label": label, "state": "done", "result": shown])
        sendStatus()
    }

    static func writeM4A(_ x: [Float], rate: Double, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 80000
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        var i = 0
        while i < x.count {
            let n = min(8192, x.count - i)
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
                  let ch = buf.floatChannelData else { break }
            buf.frameLength = AVAudioFrameCount(n)
            for k in 0..<n { ch[0][k] = x[i + k] }
            try file.write(from: buf)
            i += n
        }
        /* the file is finished when `file` goes away at the end of this function */
    }

    // MARK: uploading

    private func payload() -> Data? {
        let list = positions.prefix(CarMeasure.maxPositions)
        guard list.contains(where: { !$0.skipped }) else { return nil }
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
        var items: [[String: Any]] = []
        for p in list {
            var item: [String: Any] = ["name": p.name, "skipped": p.skipped,
                                       "levels": p.levels.filter { $0.value.isFinite }, "quality": p.quality]
            if p.name == "other" { item["label"] = String(p.label.prefix(200)) }
            if let a = p.audio, let data = try? Data(contentsOf: a), data.count <= CarMeasure.maxAudioBytes {
                item["audio_b64"] = data.base64EncodedString()
            }
            items.append(item)
        }
        let body: [String: Any] = [
            "device": deviceId,
            "deviceName": String("\(UIDevice.current.name) (\(UIDevice.current.model) iOS \(UIDevice.current.systemVersion))".prefix(200)),
            "carName": String(carName.prefix(200)),
            "appVersion": version,
            "probeVersion": CarProbe.version,
            "probe": CarProbe.definition,
            /* the server takes one string (≤ 200 characters) */
            "route": String(route.map { r -> String in
                "\(r["portType"] ?? "") \"\(r["portName"] ?? "")\" ch \(r["channels"] ?? 0)"
            }.joined(separator: "; ").prefix(200)),
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "positions": items
        ]
        guard JSONSerialization.isValidJSONObject(body) else { return nil }
        return try? JSONSerialization.data(withJSONObject: body)
    }

    private func upload() {
        guard pairing != nil else {
            emit(["action": "upload", "state": "failed", "message": "還沒有配對伺服器", "pending": pendingFiles().count])
            return
        }
        guard let data = payload() else {
            emit(["action": "upload", "state": "failed", "message": "還沒有量到任何位置", "pending": pendingFiles().count])
            return
        }
        guard data.count <= CarMeasure.maxBodyBytes else {
            Diag.shared.log("carprobe: upload is \(data.count) bytes, over the limit", error: true)
            emit(["action": "upload", "state": "failed", "message": "資料太大（\(data.count / 1_000_000) MB）", "pending": pendingFiles().count])
            return
        }
        let stamp = Int(Date().timeIntervalSince1970)
        let file = CarMeasure.pendingFolder.appendingPathComponent("\(stamp)-\(UUID().uuidString.prefix(8)).json")
        do {
            try FileManager.default.createDirectory(at: CarMeasure.pendingFolder, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            Diag.shared.log("carprobe: saving the upload failed: \(error.localizedDescription)", error: true)
            emit(["action": "upload", "state": "failed", "message": "無法存到手機：\(error.localizedDescription)", "pending": pendingFiles().count])
            return
        }
        Diag.shared.log("carprobe: session saved (\(data.count) bytes, \(positions.count) positions)")
        clearSession()
        sendPending(attempt: 0)
    }

    /// Sends the saved files one after the other; 429 / 503 are tried again later (3 times).
    private func sendPending(attempt: Int) {
        if uploading { return }
        let files = pendingFiles()
        guard let file = files.first else {
            emit(["action": "upload", "state": "done", "message": "沒有待上傳的資料", "pending": 0])
            return
        }
        guard var req = request("carprobe/upload", method: "POST"), let data = try? Data(contentsOf: file) else {
            emit(["action": "upload", "state": "failed", "message": "還沒有配對伺服器", "pending": files.count])
            return
        }
        uploading = true
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        emit(["action": "upload", "state": "sending", "message": "上傳中…（\(data.count / 1000) KB）", "pending": files.count])
        /* a body of known length: URLSession sends Content-Length, not chunked */
        URLSession.shared.uploadTask(with: req, from: data) { [weak self] body, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = body.flatMap { String(data: $0.prefix(300), encoding: .utf8) } ?? ""
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.uploading = false
                Diag.shared.log("carprobe: upload \(file.lastPathComponent): \(error.map { $0.localizedDescription } ?? "http \(status)") \(text.prefix(160))",
                                error: !(200..<300).contains(status))
                if (200..<300).contains(status) {
                    try? FileManager.default.removeItem(at: file)
                    let left = self.pendingFiles().count
                    self.emit(["action": "upload", "state": "done", "message": "上傳完成", "pending": left])
                    if left > 0 { self.sendPending(attempt: 0) }
                    return
                }
                if (status == 429 || status == 503) && attempt < 3 {
                    let wait = [10.0, 30.0, 60.0][attempt]
                    self.emit(["action": "upload", "state": "retrying", "message": "伺服器忙碌，\(Int(wait)) 秒後重試", "pending": self.pendingFiles().count])
                    DispatchQueue.main.asyncAfter(deadline: .now() + wait) { self.sendPending(attempt: attempt + 1) }
                    return
                }
                let why: String
                switch status {
                case 0: why = "連不到伺服器" + (error.map { "：\($0.localizedDescription)" } ?? "")
                case 401: why = "配對碼不對（401），請更改配對"
                case 413: why = "資料太大（413）"
                case 429, 503: why = "伺服器忙碌（\(status)），請稍後再傳"
                default: why = "伺服器回應 \(status)"
                }
                self.emit(["action": "upload", "state": "failed", "message": why + "；資料已存在手機，可稍後再傳", "pending": self.pendingFiles().count])
            }
        }.resume()
    }

    private func ping() {
        guard let req = request("carprobe/ping") else {
            emit(["action": "ping", "ok": false, "message": "還沒有配對伺服器"])
            return
        }
        URLSession.shared.dataTask(with: req) { [weak self] _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                Diag.shared.log("carprobe: ping: \(error.map { $0.localizedDescription } ?? "http \(status)")")
                let ok = (200..<300).contains(status)
                let message = ok ? "連線成功" : (status == 401 ? "配對碼不對" : (status == 0 ? "連不到伺服器" : "伺服器回應 \(status)"))
                self?.emit(["action": "ping", "ok": ok, "message": message])
            }
        }.resume()
    }

    // MARK: remote presets

    private func checkPreset(why: String, force: Bool = false) {
        guard pairing != nil, run == nil else { return }
        if !force && Date().timeIntervalSince(lastPresetCheck) < 30 { return }
        lastPresetCheck = Date()
        guard let req = request("carprobe/preset", query: [URLQueryItem(name: "device", value: deviceId)]) else { return }
        URLSession.shared.dataTask(with: req) { [weak self] body, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                guard let self = self else { return }
                if status == 404 {
                    Diag.shared.log("carprobe: preset (\(why)): none for this device")
                    return
                }
                guard status == 200, let body = body else {
                    Diag.shared.log("carprobe: preset (\(why)): \(error.map { $0.localizedDescription } ?? "http \(status)")", error: status != 0)
                    return
                }
                /* signed, for this device, newer, not from the future, settings whitelisted and
                   clamped (App/Sound/CarPreset.swift) */
                let known = UserDefaults.standard.integer(forKey: CarMeasure.presetVersionKey)
                let preset: CarRemotePreset
                switch CarPresetVerifier.verify(body, device: self.deviceId, knownVersion: known) {
                case .failure(let problem):
                    Diag.shared.log("carprobe: preset (\(why)) refused: \(problem)", error: true)
                    return
                case .success(let p):
                    preset = p
                }
                let version = preset.version
                let name = preset.name.isEmpty ? "車用預設" : preset.name
                let event: [String: Any] = ["version": version, "name": name, "note": preset.note, "car": preset.car]
                if let data = try? JSONSerialization.data(withJSONObject: event) {
                    UserDefaults.standard.set(data, forKey: CarMeasure.presetPendingKey)
                }
                Diag.shared.log("carprobe: preset (\(why)): new version \(version) \"\(name)\"")
                var e = event
                e["type"] = "carPreset"
                self.onEvent?(e)
            }
        }.resume()
    }
}

/// Plays the probe through the current output and records the microphone at the same time.
private final class Recorder {
    /// seconds recorded after the probe ends (output latency of a car's Bluetooth or CarPlay)
    static let extra = 1.5

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var limit = 0
    private(set) var rate: Double = 0

    struct Failure: LocalizedError {
        let text: String
        var errorDescription: String? { return text }
    }

    func start() throws {
        let input = engine.inputNode
        try? input.setVoiceProcessingEnabled(false)
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw Failure(text: "沒有可用的麥克風輸入") }
        rate = inFormat.sampleRate
        limit = Int((CarProbe.duration + Recorder.extra + 1) * rate)
        samples.reserveCapacity(limit)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            guard let self = self, let ch = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            self.lock.lock()
            let room = max(0, self.limit - self.samples.count)
            if room > 0 { self.samples.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: min(n, room))) }
            self.lock.unlock()
        }
        var outRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        if outRate <= 0 { outRate = 48000 }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: outRate, channels: 2) else { throw Failure(text: "無法建立播放格式") }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        let probe = CarProbe.generate(sampleRate: outRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(probe.left.count)),
              let out = buffer.floatChannelData else { throw Failure(text: "無法建立測試音") }
        buffer.frameLength = AVAudioFrameCount(probe.left.count)
        for i in 0..<probe.left.count {
            out[0][i] = probe.left[i]
            out[1][i] = probe.right[i]
        }
        engine.prepare()
        try engine.start()
        node.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        node.play()
        Diag.shared.log("carprobe: recording at \(Int(rate)) Hz (\(inFormat.channelCount) ch), playing at \(Int(outRate)) Hz")
    }

    func stop() -> [Float] {
        node.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        let out = samples
        lock.unlock()
        return out
    }
}
