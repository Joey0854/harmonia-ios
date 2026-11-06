import CoreBluetooth
import Foundation
import QuartzCore

/// Where the music is, as the player last reported it (main queue, about four times a second
/// and on every change). The light's own loop runs on from there with the clock.
struct LightPlayback {
    var id: String?
    /// Position in the current song when `at` (CACurrentMediaTime) was taken.
    var position: Double = 0
    var at: CFTimeInterval = 0
    var playing = false
    /// The mix under way and the song coming in with it.
    var plan: MixPlan?
    var incoming: String?
    /// The song after the current one (its light envelope is made ahead of time).
    var next: String?
    /// Seconds from the player's position to the loudspeaker (AVAudioSession.outputLatency).
    var latency: Double = 0
}

/// The car's ambient light follows the music: a real feature of the player.
///
/// - Off (the default), nothing of this runs and Bluetooth is not even started.
/// - On: connects to the light (the device used last time, otherwise the first one that
///   advertises the vendor's services), keeps it connected and reads the controller's own
///   state, but sends nothing until music plays.
/// - Music playing: takes the controller over and 25 times a second looks up the music's
///   values for what is being heard (each playing song's light envelope at its position minus
///   the output latency and the user's offset; during a mix both songs, weighted by their
///   levels), turns them into a colour (LightMapper) and sends it if it differs enough from
///   the last one sent (LightChangeGate). The newest colour always wins; nothing is queued
///   while the link is busy.
/// - Music stopped for 3 s: fades back to the controller's own colour and brightness, then
///   sends nothing (LightIdle).
/// - Switched off (or the app ends) while holding the controller: its own colour and overall
///   brightness are sent back at once.
///
/// Settings and the link are handled on the main queue; the 25 Hz loop runs on a queue of its
/// own and hands what to send to the main queue (CoreBluetooth calls back there).
final class LightMusic {
    static let shared = LightMusic()

    /// `{type:'light', state, name, detail}` for the page.
    var onEvent: (([String: Any]) -> Void)?

    private static let settingsKey = "lightMusic"

    /* Main queue. */
    private(set) var settings = LightMusicSettings()
    private var running = false
    private var link: LightLink?
    private var lastState: [String: String] = [:]
    /// The controller's own state (first connection while running).
    private var original: LightState?
    private var waitingForState = false
    private var stateToken = 0
    /// Connected and the state read (or given up on): the loop may drive the controller.
    private var ready = false
    /// The test screen is sending its own commands: the loop stays quiet until it closes.
    private var pausedForTest = false
    /// What the loop would be doing without the test pause.
    private var wantLoop = false
    private var retryDelay = 1.0
    private var retryPending = false
    private var askedFor = Set<String>()
    private var lastPlaybackIDs: [String] = []

    /* Shared between the main queue and the loop (under `lock`). */
    private let lock = NSLock()
    private var playback = LightPlayback()
    private var loopSettings = LightMusicSettings()
    private var loopActive = false
    private var loopOriginal: LightState?
    private var newEnvelopes = Set<String>()
    /// Songs' colours (from LightArt).
    private var palettes: [String: LightPalette] = [:]
    private var gateStale = false
    private var latestColour: String?
    /// Split zones: the newest colour per zone (1 upper, 2 footwell) and how much it changed.
    private var latestZone: [Int: (command: String, change: Int)] = [:]
    private var zoneStale = Set<Int>()
    private var zoneSent: [Int: Int] = [:]
    private var zoneBusy: [Int: Int] = [:]
    private var pendingCommands: [String] = []
    private var sendScheduled = false
    private var sentCount = 0
    private var busyCount = 0

    /* Loop queue only. */
    private let queue = DispatchQueue(label: "light-music", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var mapper = LightMapper(settings: LightMusicSettings())
    private let idle = LightIdle()
    /// After a test: the next take-over includes the single-colour command.
    private var forceSingleColour = false
    private let gate = LightChangeGate()
    private var split = LightSplitMapper(settings: LightMusicSettings())
    private let upperGate = LightChangeGate()
    private let footGate = LightChangeGate()
    private let footColour = LightSongColour(footwell: true)
    private var zoneUnchanged: [Int: Int] = [:]
    private var lastZones = LightZones.all
    private let songColour = LightSongColour()
    private var sectionCache: [String: [Bool]] = [:]
    private var envelopes: [String: LightEnvelope] = [:]
    private var envelopeOrder: [String] = []
    private var missingSince: [String: CFTimeInterval] = [:]
    private var startedAt: CFTimeInterval = 0
    private var lastTick: CFTimeInterval = 0
    private var periodStart: CFTimeInterval = 0
    private var frames = 0
    private var playingFrames = 0
    private var admitted = 0
    private var unchanged = 0
    private var noData = 0
    private var maxGap = 0.0

    private init() {}

    // MARK: settings (main queue)

    /// At app start: when the user left it on, start it (connects to the light).
    func restoreAtLaunch() {
        if let saved = UserDefaults.standard.dictionary(forKey: LightMusic.settingsKey) {
            let restored = LightMusicSettings(saved)
            if restored.on {
                Diag.shared.log("light music on at launch")
                apply(restored)
            }
        }
    }

    /// The page's `{cmd:'light', ...}`.
    func apply(message: [String: Any]) {
        apply(LightMusicSettings(message))
        emitState(force: true)
    }

    private func apply(_ new: LightMusicSettings) {
        let old = settings
        settings = new
        var saved: [String: Any] = ["on": new.on, "style": new.style.rawValue, "level": new.level,
                                    "floor": new.floor, "hue": new.hue, "offsetMs": new.offsetMs,
                                    "saturation": new.saturation, "intensity": new.intensity,
                                    "zones": new.zones.rawValue]
        if let mode = new.colourMode { saved["colourMode"] = mode.rawValue }
        UserDefaults.standard.set(saved, forKey: LightMusic.settingsKey)
        lock.lock()
        loopSettings = new
        lock.unlock()
        if new != old {
            Diag.shared.log(String(format: "light settings: %@, style %@, colour %@, saturation %.2f, intensity %.2f, zones %@, level %.2f, floor %.2f, hue %.0f, offset %.0f ms",
                                   new.on ? "on" : "off", new.style.rawValue, new.mode.rawValue, new.saturation, new.intensity, new.zones.rawValue, new.level, new.floor, new.hue, new.offsetMs))
        }
        if new.on && !running { start() }
        if !new.on && running { stop() }
    }

    // MARK: playback (main queue)

    /// The player's latest position (called by NativePlayer).
    func update(_ now: LightPlayback) {
        guard running else { return }
        lock.lock()
        playback = now
        lock.unlock()
        let ids = [now.id, now.incoming, now.next].compactMap { $0 }
        if ids != lastPlaybackIDs {
            lastPlaybackIDs = ids
            for id in ids {
                prepare(id)
                /* A song the page names no cover for gets its colour from its sound. */
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self = self, self.running, !LightArt.shared.wasRequested(id) else { return }
                    LightArt.shared.fromSound(id)
                }
            }
        }
    }

    /// The page's `{cmd:'lightArt', id, url}`: the cover of a song (current or coming).
    func art(id: String, url: String) {
        guard running else { return }
        LightArt.shared.request(id: id, url: url)
    }

    /// Makes sure the song's light envelope exists or is being made.
    private func prepare(_ id: String) {
        guard let url = SongAnalyzer.lightURL(id), !FileManager.default.fileExists(atPath: url.path) else { return }
        guard let file = Downloads.shared.localURL(id) ?? StreamCache.shared.cachedURL(id) else { return }
        if !askedFor.contains(id) {
            askedFor.insert(id)
            if askedFor.count > 200 { askedFor.removeAll() }
            Diag.shared.log("light envelope missing, analysing", song: id)
        }
        SongAnalyzer.shared.analyze(id: id, file: file)
    }

    // MARK: running (main queue)

    private func start() {
        running = true
        pausedForTest = false
        retryDelay = 1
        SongAnalyzer.shared.wantLight = true
        SongAnalyzer.shared.onLight = { [weak self] id in
            guard let self = self else { return }
            self.lock.lock()
            self.newEnvelopes.insert(id)
            self.lock.unlock()
            LightArt.shared.envelopeReady(id)
        }
        LightArt.shared.onPalette = { [weak self] id, palette in
            guard let self = self else { return }
            self.lock.lock()
            if self.palettes.count > 80 { self.palettes.removeAll() }
            self.palettes[id] = palette
            self.lock.unlock()
        }
        let link = LightLink.shared
        self.link = link
        link.muted = true
        link.onStatus = { [weak self] in self?.linkChanged() }
        link.onFrame = { [weak self] frame in self?.received(frame) }
        Diag.shared.log("light music started")
        connectIfNeeded()
        startLoop()
        lastPlaybackIDs = []
        emitState(force: true)
    }

    private func stop() {
        running = false
        let holding = stopLoop()
        SongAnalyzer.shared.wantLight = false
        SongAnalyzer.shared.onLight = nil
        if holding { restore() }
        if let link = link {
            link.onStatus = nil
            link.onFrame = nil
            link.muted = false
            link.stopScan()
            /* A moment for the restoring writes to go out before the link is let go. */
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self, !self.running else { return }
                link.disconnect()
            }
        }
        original = nil
        ready = false
        waitingForState = false
        lock.lock()
        loopOriginal = nil
        lock.unlock()
        Diag.shared.log("light music stopped")
        emitState(force: true)
    }

    /// The app is about to end: give the controller its own state back (best effort).
    func appWillTerminate() {
        guard running else { return }
        if stopLoop() { restore() }
    }

    /// Sends the controller's own state back at once (switched off, app ending).
    private func restore() {
        guard let link = link, link.isReady else { return }
        let commands = LightSession.restoreCommands(original)
        if commands.isEmpty {
            Diag.shared.log("light restore: own state unknown, nothing restored")
            return
        }
        Diag.shared.log("light restore: " + commands.joined(separator: " "))
        for c in commands { link.send(c, queueIfBusy: true, silent: true) }
    }

    private func connectIfNeeded() {
        guard running, let link = link else { return }
        if link.isReady {
            if !ready && !waitingForState { readState() }
            return
        }
        if link.connected != nil || link.connecting != nil { return }
        guard link.poweredOn else { return }   // linkChanged() comes back when it is
        if link.connectSaved() {
            Diag.shared.log("light connecting to the saved device")
        } else if !link.scanning {
            link.scanForLight()
        }
    }

    private func linkChanged() {
        guard running, let link = link else { return }
        if link.isReady {
            retryDelay = 1
            if !ready && !waitingForState { readState() }
        } else {
            if ready || waitingForState {
                Diag.shared.log("light link lost, reconnecting")
                ready = false
                waitingForState = false
                setLoopActive(false)
                queue.async { self.idle.reset() }
            }
            if link.connected == nil && link.connecting == nil && !link.scanning { scheduleRetry() }
        }
        emitState(force: false)
    }

    /// Tries again after a growing pause (1, 2, 4 ... 30 s).
    private func scheduleRetry() {
        if retryPending { return }
        retryPending = true
        let delay = retryDelay
        retryDelay = min(30, retryDelay * 2)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            self.retryPending = false
            self.connectIfNeeded()
        }
    }

    /// Connected: read the controller's own state (sent back whenever no music plays). Nothing
    /// else is sent until music plays.
    private func readState() {
        guard let link = link else { return }
        Diag.shared.log("light connected to \(link.connected?.name ?? "(no name)"), reading its state")
        waitingForState = true
        stateToken += 1
        let token = stateToken
        link.send("<0A01>", queueIfBusy: true, silent: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self, self.stateToken == token, self.waitingForState else { return }
            Diag.shared.log("light: no state frame within 1.5 s, carrying on without it")
            self.stateRead()
        }
    }

    private func stateRead() {
        guard running, let link = link, link.isReady else { return }
        waitingForState = false
        ready = true
        lock.lock()
        loopOriginal = original
        gateStale = true
        lock.unlock()
        setLoopActive(true)
        emitState(force: false)
    }

    private func received(_ frame: LightFrame) {
        if let state = LightState(frame: frame.text) {
            /* The first state read while running is the user's own; later ones (after a
               reconnect) may show our colours. */
            if original == nil {
                original = state
                Diag.shared.log(String(format: "light own state: power %@, colour %02x%02x%02x, brightness %02x, mode %02x/%02x",
                                       state.powerOn ? "on" : "off", state.r, state.g, state.b,
                                       state.globalBrightness, state.rgbMode, state.symphonyMode))
            }
            if waitingForState { stateRead() }
        } else if let s = LightSettingsFrame(frame: frame.text) {
            Diag.shared.log("light controller sound input: " + (s.hasSoundInput ? String(format: "%02x", s.soundInput) : "none"))
        }
    }

    // MARK: state for the page (main queue)

    private func currentState() -> [String: String] {
        guard running, let link = link else { return ["state": "off"] }
        let name = link.connected?.name ?? link.connecting?.name ?? link.savedDevice?.name ?? ""
        var out = ["name": name]
        switch link.bluetoothState {
        case .poweredOff:
            out["state"] = "error"; out["detail"] = "藍牙已關閉"
            return out
        case .unauthorized:
            out["state"] = "error"; out["detail"] = "沒有藍牙權限（到「設定」裡允許）"
            return out
        case .unsupported:
            out["state"] = "error"; out["detail"] = "這台裝置不支援藍牙 LE"
            return out
        default:
            break
        }
        if link.isReady && ready {
            out["state"] = "connected"
        } else if link.connected != nil || link.connecting != nil {
            out["state"] = "connecting"
        } else {
            out["state"] = "searching"
        }
        return out
    }

    private func emitState(force: Bool) {
        let now = currentState()
        if !force && now == lastState { return }
        if now["state"] != lastState["state"] {
            Diag.shared.log("light state: \(now["state"] ?? "?")" + (now["detail"].map { " (\($0))" } ?? ""))
        }
        lastState = now
        var event: [String: Any] = ["type": "light", "state": now["state"] ?? "off"]
        let name = now["name"] ?? ""
        event["name"] = name.isEmpty ? NSNull() : name
        event["detail"] = now["detail"].map { $0 as Any } ?? NSNull()
        onEvent?(event)
    }

    // MARK: sending (main queue)

    private func sendLatest() {
        lock.lock()
        let commands = pendingCommands
        pendingCommands = []
        let colour = latestColour
        latestColour = nil
        let zones = latestZone
        latestZone.removeAll()
        sendScheduled = false
        lock.unlock()
        guard running, ready, let link = link else { return }
        /* Mode and restore commands must arrive: they wait for the link. */
        for c in commands { link.send(c, queueIfBusy: true, silent: true) }
        if !zones.isEmpty {
            /* the zone that changed most goes first; one the link cannot take is dropped (its
               next colour is measured from what was really sent) */
            let ordered = LightZoneOrder.order(zones.sorted { $0.key < $1.key }.map { (command: $0.value.command, change: $0.value.change) })
            for command in ordered {
                guard let zone = zones.first(where: { $0.value.command == command })?.key else { continue }
                let handed = link.send(command, queueIfBusy: false, silent: true)
                lock.lock()
                if handed == .sent {
                    zoneSent[zone, default: 0] += 1
                } else {
                    zoneBusy[zone, default: 0] += 1
                    zoneStale.insert(zone)
                }
                lock.unlock()
            }
        }
        guard let command = colour else { return }
        let handed = link.send(command, queueIfBusy: false, silent: true)
        lock.lock()
        if handed == .sent {
            sentCount += 1
        } else {
            busyCount += 1
            gateStale = true   // not sent: the next colour must not be measured against it
        }
        lock.unlock()
    }

    private func setLoopActive(_ on: Bool) {
        wantLoop = on
        lock.lock()
        loopActive = on && !pausedForTest
        lock.unlock()
    }

    // MARK: the test screen (main queue)

    /// The test screen is about to send a command of its own. While the music light runs it
    /// would overwrite it at once, so it pauses until `resumeAfterTest`.
    func pauseForTest() {
        guard running, !pausedForTest else { return }
        pausedForTest = true
        lock.lock()
        loopActive = false
        latestColour = nil
        latestZone.removeAll()
        pendingCommands = []
        lock.unlock()
        Diag.shared.log("light test: music light paused for test")
    }

    /// The test screen or the guided test is holding the music light.
    var testPaused: Bool { return pausedForTest }

    /// The guided test measured the light's delay: use it until the page sends its own settings.
    func setOffset(_ ms: Double) {
        var s = settings
        s.offsetMs = min(500, max(-300, ms))
        apply(s)
    }

    /// The test screen has closed. The test may have changed the controller's mode, so the
    /// next take-over sends the single-colour command whatever the first state frame said.
    func resumeAfterTest() {
        guard pausedForTest else { return }
        pausedForTest = false
        queue.async {
            self.idle.reset()
            self.forceSingleColour = true
            self.gate.reset()
        }
        setLoopActive(wantLoop)
        Diag.shared.log("light test: music light resumed")
    }

    // MARK: the loop (its own queue)

    private func startLoop() {
        queue.async {
            if self.timer != nil { return }
            let now = CACurrentMediaTime()
            self.startedAt = now
            self.lastTick = now
            self.periodStart = now
            self.gate.reset()
            self.idle.reset()
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(40), leeway: .milliseconds(4))
            t.setEventHandler { [weak self] in self?.tick() }
            self.timer = t
            t.resume()
        }
    }

    /// Stops the loop; true when the controller was showing something of ours.
    private func stopLoop() -> Bool {
        setLoopActive(false)
        lock.lock()
        latestColour = nil
        pendingCommands = []
        lock.unlock()
        return queue.sync {
            self.timer?.cancel()
            self.timer = nil
            self.envelopes.removeAll()
            self.sectionCache.removeAll()
            self.songColour.reset()
            self.envelopeOrder.removeAll()
            self.missingSince.removeAll()
            let holding = self.idle.holding
            self.idle.reset()
            return holding
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        lock.lock()
        let active = loopActive
        let pb = playback
        let s = loopSettings
        let own = loopOriginal
        let knownPalettes = palettes
        let fresh = newEnvelopes
        newEnvelopes.removeAll()
        let stale = gateStale
        gateStale = false
        let staleZones = zoneStale
        zoneStale.removeAll()
        lock.unlock()

        for id in fresh { missingSince[id] = nil }
        let dt = min(0.2, max(0.005, now - lastTick))
        maxGap = max(maxGap, now - lastTick)
        lastTick = now
        guard active else { return }
        if stale {
            gate.reset()
            upperGate.reset()
            footGate.reset()
        }
        if staleZones.contains(1) { upperGate.reset() }
        if staleZones.contains(2) { footGate.reset() }
        if mapper.settings != s { mapper.settings = s }
        if split.settings != s { split.settings = s }
        if s.zones != lastZones {
            /* switching between one colour and two: everything is sent fresh */
            lastZones = s.zones
            gate.reset()
            upperGate.reset()
            footGate.reset()
        }
        idle.original = own

        frames += 1
        /* Mixes and changes of song count as playing; short gaps are bridged by LightIdle. */
        let playing = pb.playing && pb.id != nil
        switch idle.step(playing: playing, now: now) {
        case .none:
            break
        case .takeOver(var commands):
            if forceSingleColour {
                forceSingleColour = false
                let single = own?.singleColourCommand ?? "<0400>"
                if !commands.contains(single) { commands.insert(single, at: commands.count - 1) }
            }
            Diag.shared.log("light playing: taking over (" + commands.joined(separator: " ") + ")")
            if let o = own, commands.contains(LightSession.symphonyCommand(LightSession.syncSymphony)) {
                Diag.shared.log(String(format: "light takeover: symphony mode %02X -> 18", UInt32(o.symphonyMode)))
            }
            handCommands(commands)
            gate.reset()
            music(pb, s, now: now, dt: dt, palettes: knownPalettes)
        case .music:
            music(pb, s, now: now, dt: dt, palettes: knownPalettes)
        case .fade(let command):
            hand(command)
        case .restore(let commands):
            Diag.shared.log(commands.isEmpty ? "light idle: own state unknown, leaving the last colour"
                                             : "light idle: restoring original (" + commands.joined(separator: " ") + ")")
            handCommands(commands)
            gate.reset()
        }
        summarise(now)
    }

    /// One frame of music: the colour for what is heard now.
    private func music(_ pb: LightPlayback, _ s: LightMusicSettings, now: CFTimeInterval, dt: Double,
                       palettes: [String: LightPalette]) {
        playingFrames += 1
        var values = (bass: 0.0, mid: 0.0, onset: 0.0)
        var colourParts: [LightSongColour.Part] = []
        if let id = pb.id {
            let heard = LightTiming.heardPosition(reported: pb.position, elapsed: now - pb.at, playing: pb.playing,
                                                  latency: pb.latency, offsetMs: s.offsetMs)
            let voices = LightTiming.voices(current: id, position: heard, plan: pb.plan, incoming: pb.incoming)
            var parts: [(values: (bass: Double, mid: Double, onset: Double), weight: Double)] = []
            for v in voices {
                var inSection = false
                if let e = envelope(v.id, now: now) {
                    parts.append((e.sample(at: v.position), v.weight))
                    if let flags = sectionCache[v.id], !flags.isEmpty {
                        let k = Int(v.position * LightEnvelope.framesPerSecond)
                        inSection = k >= 0 && k < flags.count && flags[k]
                    }
                }
                colourParts.append(LightSongColour.Part(id: v.id, palette: palettes[v.id], inSection: inSection, weight: v.weight))
            }
            if parts.isEmpty { noData += 1 } else { values = LightTiming.combine(parts) }
        }
        var footBase: LightColour?
        if s.mode == .song {
            let drift = LightColour(hue: (now - startedAt) / LightMapper.hueTurn * 360, saturation: 1)
            mapper.base = songColour.step(colourParts, dt: dt, fallback: drift, intensity: s.intensity)
            if s.zones == .split {
                footBase = footColour.step(colourParts, dt: dt, fallback: LightColour(hue: drift.hue + 15, saturation: 1),
                                           intensity: s.intensity)
            }
        } else {
            mapper.base = nil
            songColour.reset()
            footColour.reset()
        }
        if s.zones == .split {
            /* drift and fixed colours: both zones the same colour, each with its own brightness */
            let both = split.step(bass: values.bass, mid: values.mid, onset: values.onset, playing: true,
                                  time: now - startedAt, dt: dt, upperBase: mapper.base, footBase: footBase ?? mapper.base)
            idle.lastColour = both.upper
            var items: [(zone: Int, command: String, change: Int)] = []
            let u = both.upper, f = both.foot
            let uChange = upperGate.change(u)
            if upperGate.admit(u) {
                items.append((1, LightCommand.zoneColor(1, r: u.r, g: u.g, b: u.b), uChange))
            } else {
                zoneUnchanged[1, default: 0] += 1
            }
            let fChange = footGate.change(f)
            if footGate.admit(f) {
                items.append((2, LightCommand.zoneColor(2, r: f.r, g: f.g, b: f.b), fChange))
            } else {
                zoneUnchanged[2, default: 0] += 1
            }
            if items.isEmpty { unchanged += 1 } else { admitted += 1; handZones(items) }
            return
        }
        let c = mapper.step(bass: values.bass, mid: values.mid, onset: values.onset,
                            playing: true, time: now - startedAt, dt: dt)
        idle.lastColour = c
        if gate.admit(c) {
            admitted += 1
            hand(LightCommand.color(r: c.r, g: c.g, b: c.b))
        } else {
            unchanged += 1
        }
    }

    /// The newest colour for the main queue to send (replaces one not sent yet).
    /// The newest colour of each zone for the main queue (replaces one not sent yet).
    private func handZones(_ items: [(zone: Int, command: String, change: Int)]) {
        lock.lock()
        for item in items {
            /* a colour not sent yet: the change counts from what was really sent last */
            let before = latestZone[item.zone]?.change ?? 0
            latestZone[item.zone] = (item.command, max(item.change, before))
        }
        latestColour = nil
        let schedule = !sendScheduled
        sendScheduled = true
        lock.unlock()
        if schedule {
            DispatchQueue.main.async { [weak self] in self?.sendLatest() }
        }
    }

    private func hand(_ command: String) {
        lock.lock()
        latestColour = command
        latestZone.removeAll()
        let schedule = !sendScheduled
        sendScheduled = true
        lock.unlock()
        if schedule {
            DispatchQueue.main.async { [weak self] in self?.sendLatest() }
        }
    }

    /// Commands that must all arrive, in order; a colour not sent yet is dropped (it would
    /// come after them).
    private func handCommands(_ commands: [String]) {
        if commands.isEmpty { return }
        lock.lock()
        pendingCommands += commands
        latestColour = nil
        latestZone.removeAll()
        let schedule = !sendScheduled
        sendScheduled = true
        lock.unlock()
        if schedule {
            DispatchQueue.main.async { [weak self] in self?.sendLatest() }
        }
    }

    private func summarise(_ now: CFTimeInterval) {
        let span = now - periodStart
        if span < 30 { return }
        lock.lock()
        let sent = sentCount
        let busy = busyCount
        sentCount = 0
        busyCount = 0
        let zs = zoneSent, zb = zoneBusy
        zoneSent.removeAll()
        zoneBusy.removeAll()
        lock.unlock()
        if playingFrames > 0 && !(zs.isEmpty && zb.isEmpty && zoneUnchanged.isEmpty) {
            for (zone, name) in [(1, "upper"), (2, "footwell")] {
                Diag.shared.log(String(format: "light rate %@: %.1f sent/s, %.1f unchanged/s, %.1f link busy/s", name,
                                       Double(zs[zone] ?? 0) / span, Double(zoneUnchanged[zone] ?? 0) / span,
                                       Double(zb[zone] ?? 0) / span))
            }
        }
        zoneUnchanged.removeAll()
        if playingFrames > 0 {
            Diag.shared.log(String(format: "light rate: %.1f frames/s, %.1f sent/s, %.1f unchanged/s, %.1f link busy/s, %.1f no envelope/s, longest gap %.0f ms",
                                   Double(frames) / span, Double(sent) / span, Double(unchanged) / span,
                                   Double(busy) / span, Double(noData) / span, maxGap * 1000))
        }
        periodStart = now
        frames = 0
        playingFrames = 0
        admitted = 0
        unchanged = 0
        noData = 0
        maxGap = 0
    }

    /// The song's light envelope from the cache or its file; nil while it does not exist (the
    /// file is looked for again every 2 s, or at once when the analysis says it is there).
    private func envelope(_ id: String, now: CFTimeInterval) -> LightEnvelope? {
        if let e = envelopes[id] { return e }
        if let since = missingSince[id], now - since < 2 { return nil }
        guard let url = SongAnalyzer.lightURL(id), let data = try? Data(contentsOf: url),
              let e = LightEnvelope(data: data) else {
            missingSince[id] = now
            return nil
        }
        missingSince[id] = nil
        envelopes[id] = e
        sectionCache[id] = e.sections()
        envelopeOrder.append(id)
        if envelopeOrder.count > 6 {
            let old = envelopeOrder.removeFirst()
            envelopes[old] = nil
            sectionCache[old] = nil
        }
        Diag.shared.log(String(format: "light envelope in use: %.0f s, bass ref %.4f, mid ref %.4f, onset ref %.3f",
                               e.duration, Double(e.bassRef), Double(e.midRef), Double(e.onsetRef)), song: id)
        return e
    }
}
