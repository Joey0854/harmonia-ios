import AVFoundation
import MediaPlayer
import UIKit

/// One song as the page describes it.
struct Track {
    let id: String
    let url: URL
    let title: String
    let artist: String
    let artwork: String
    let duration: Double
    /// Set when the song cannot be streamed by the player itself: it has to be downloaded with
    /// these request headers first and is then played from the file.
    var headers: [String: String]? = nil
    /// Length of the file in bytes when the page knows it, otherwise 0.
    var size: Int64 = 0
    /// What the PC found out about the song, for mixing into and out of it.
    var mix: MixAnalysis? = nil
}

/// Plays songs so that the phone treats this like any music app: it keeps running in the
/// background, survives other apps taking the sound, and stays in Control Centre while paused.
/// The page is told what happens through `onEvent`.
///
/// There are two ways a song is played:
/// - a file on the phone goes through `SoundEngine`, which applies surround, equaliser and
///   loudness balancing;
/// - anything else (an address on the PC), and any file the engine cannot handle, goes
///   through the plain system player without those effects (`fxUnavailable` tells the page).
final class NativePlayer: NSObject {
    var onEvent: (([String: Any]) -> Void)?
    /// A song was listened to long enough to count (id, title, artist, artwork, length). The app
    /// counts it itself: the page cannot while the screen is off.
    var onListened: ((String, String, String, String, Double) -> Void)?
    private var listen = ListenCounter()

    private let player = AVPlayer()
    private let sound = SoundEngine()
    /// True while the current song plays through the sound engine.
    private var usingEngine = false
    private var currentFile: URL?
    private var currentID: String?
    private var engineTimer: Timer?

    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var controlObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?

    private var wantPlay = false
    private var interruptedWhilePlaying = false
    /* What the system is told (playing / paused); see PlaybackReport. */
    private var report = PlaybackReport()
    private var reportedState: MPNowPlayingPlaybackState?
    /* The audio session has been activated and not taken away since. */
    private var sessionActive = false
    private var finishing = false

    /// Songs that follow the current one. Kept here so the next song starts even when the
    /// page is not running (screen locked).
    private var upNext: [Track] = []

    private var title = ""
    private var artist = ""
    private var artworkAddress = ""
    private var artwork: MPMediaItemArtwork?
    /// The real length of the song as the page knows it (the file can report a longer one).
    private var knownDuration: Double = 0
    /// Drops the page's description of the previous song after the app moved on by itself.
    private var nowPlayingGuard = NowPlayingGuard()

    /// The song we are downloading before it can be played, if any.
    private var waitingID: String?
    /// Goes up every time a different song is asked for. A download that finishes compares its
    /// own number with this one, so an answer for a song nobody wants any more is dropped.
    private var waitToken = 0
    /// The address whose download in advance failed, so we do not try it again on every
    /// queue update. It is tried once more when its turn to play comes.
    private var failedPrefetch = Set<URL>()

    /// The song being downloaded ahead, and (when the queue stopped listing it) the moment
    /// until which its download is left running all the same.
    private var prefetchID: String?
    private var prefetchDropAt: Date?

    /// What the last queue from the page looked like; nil once this player has moved on by
    /// itself or been given another song, so that the page's next queue is always taken then.
    private var lastQueueKey: String?

    /* Mixing from one song into the next. */
    private var mixOn = UserDefaults.standard.bool(forKey: "mixOn")
    /// What is known about songs, by id (from `loadSong`, `queue` and `mixInfo`).
    private var mixInfo: [String: MixAnalysis] = [:]
    /// The song that is coming in (a mix is under way), its file, and whether the page has been
    /// told that the overlap has begun.
    private var incoming: Track?
    private var incomingFile: URL?
    private var mixStartSent = false
    /// The last decision that was written to the log, so each is written once.
    private var lastMixLog = ""
    /// "A>B" pairs whose mix failed; not tried again.
    private var mixGivenUp = Set<String>()

    /* Loudness balancing as the page set it. */
    private var normOn = false
    private var normTarget = -9.0

    override init() {
        super.init()
        configureSession()
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                                                      queue: .main) { [weak self] _ in
            guard let self = self, !self.usingEngine else { return }
            self.tick()
        }
        controlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self = self, !self.usingEngine else { return }
                self.sendState()
            }
        }
        /* The system player reports its position by itself; the engine has to be asked. */
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self, self.usingEngine else { return }
            self.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        engineTimer = timer

        sound.onReady = { [weak self] stated in
            guard let self = self, self.usingEngine else { return }
            Diag.shared.log("engine ready, file says \(stated) s", song: self.currentID ?? "-")
            self.onEvent?(["type": "ready", "dur": self.itemDuration()])
            self.updateNowPlaying()
        }
        sound.onEnded = { [weak self] in self?.engineEnded() }
        sound.onFailed = { [weak self] message, position in self?.engineFailed(message, at: position) }
        SongAnalyzer.shared.onLoudness = { [weak self] id, lufs in
            guard let self = self else { return }
            self.onEvent?(["type": "lufs", "id": id, "lufs": lufs])
            if id == self.currentID || id == self.incoming?.id { self.applyLoudnessGain(of: id, smooth: true) }
        }
        /* The app finds the parts of each song itself, so mixing needs no PC. What a PC says about
           a song (which also has its tempo) takes the place of this. */
        SongAnalyzer.shared.onStructure = { [weak self] id, info in
            guard let self = self, self.mixInfo[id] == nil else { return }
            self.remember(info, of: id)
            Diag.shared.log(String(format: "mix: parts found, main part %.1f-%.1f s, last sound %.1f s", info.bodyStart ?? 0, info.bodyEnd ?? 0, info.tailEnd ?? 0), song: id)
            self.updateMixPlan()
        }
        SongAnalyzer.shared.onLength = { [weak self] id, seconds in
            self?.adoptLength(seconds, of: id)
            self?.updateMixPlan()
        }
        sound.onMix = { [weak self] stage, plan, id, reason in
            self?.mixReported(stage, plan, id, reason)
        }
        restoreSoundSettings()

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleInterruption(_:)),
                           name: AVAudioSession.interruptionNotification, object: nil)
        center.addObserver(self, selector: #selector(handleRouteChange(_:)),
                           name: AVAudioSession.routeChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(handleBackground),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(handleMediaReset),
                           name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        setupRemoteCommands()
    }

    private func configureSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        } catch {
            Diag.shared.log("audio session category: \(SongDecoder.describe(error))", error: true)
        }
    }

    // MARK: commands from the page

    /// Plays an address the player can open directly (the PC, or a file on the phone).
    func load(url: URL, startAt: Double) {
        waitToken += 1
        waitingID = nil
        lastQueueKey = nil
        open(url: url, startAt: startAt)
        sweepDownloads()
    }

    /// Plays a song that has to be downloaded first. A song the user stored, or one already in
    /// the cache, starts at once. `url` is nil when the page only knows the song as stored on
    /// the phone. `duration` is the real length when the page knows it, otherwise 0.
    func loadSong(id: String, url: URL?, headers: [String: String], size: Int64, startAt: Double, duration: Double) {
        /* The page asks for the very song that is already coming in: do not start it again,
           let it take over at once from where it is. */
        if usingEngine, incoming?.id == id, sound.finishMixNow() {
            if wantPlay { play(reason: "mix hand-over") }
            return
        }
        waitToken += 1
        let token = waitToken
        waitingID = nil
        lastQueueKey = nil
        /* A new song: the length of the previous one must not be shown or used for it. The
           file itself is no help here, this audio format can report about twice its length. */
        knownDuration = duration > 0 ? duration : 0
        if let file = Downloads.shared.localURL(id) ?? StreamCache.shared.cachedURL(id) {
            Diag.shared.log("loadSong: already on the phone (\(file.deletingLastPathComponent().lastPathComponent))", song: id)
            open(url: file, startAt: startAt)
            if wantPlay { play(reason: "song on the phone") }
            sweepDownloads()
            return
        }
        /* Nothing to play yet: silence the previous song instead of letting it run on. */
        silence()
        guard let url = url else {
            /* Said to be stored on the phone, but the file is gone and there is no address. */
            sweepDownloads()
            /* The page looks for exactly this text to take the song off its list of stored songs. */
            onEvent?(["type": "error", "id": id, "message": "stored file is missing"])
            return
        }
        waitingID = id
        StreamCache.shared.fetch(id: id, url: url, headers: headers, size: size,
            progress: { [weak self] got, total in
                guard let self = self, self.waitToken == token else { return }
                self.onEvent?(["type": "progress", "id": id, "received": got, "total": total])
            },
            done: { [weak self] file, message in
                guard let self = self, self.waitToken == token else { return }
                self.waitingID = nil
                guard let file = file else {
                    self.onEvent?(["type": "error", "id": id, "message": message ?? "download failed"])
                    return
                }
                self.open(url: file, startAt: startAt)
                /* `play` may have been asked for while we were downloading. */
                if self.wantPlay { self.play(reason: "download done") }
            })
        sweepDownloads()
    }

    /// Stops whatever is sounding and unloads it.
    private func silence() {
        removeItemObservers()
        player.replaceCurrentItem(with: nil)
        /* While waiting for the next song the output keeps running (silent), so that to the
           system the app goes on playing. */
        sound.stop(keepRunning: wantPlay)
        usingEngine = false
        currentFile = nil
        currentID = nil
    }

    /// Starts on a song that can be opened now: a file through the engine, anything else
    /// through the system player.
    private func open(url: URL, startAt: Double) {
        removeItemObservers()
        finishing = false
        if url.isFileURL {
            player.replaceCurrentItem(with: nil)
            usingEngine = true
            currentFile = url
            /* Stored and cached songs are named <id>.m4a. */
            let id = url.deletingPathExtension().lastPathComponent
            currentID = id
            applyHeldMeta()
            if let seconds = SongAnalyzer.shared.length(id) { adoptLength(seconds, of: id) }
            sound.load(file: url, startAt: startAt, id: id)
            applyLoudnessGain(of: id, smooth: false)
            SongAnalyzer.shared.analyze(id: id, file: url)
            updateMixPlan()
            return
        }
        sound.stop()
        usingEngine = false
        currentFile = nil
        currentID = nil
        openInSystemPlayer(url: url, startAt: startAt)
    }

    private func openInSystemPlayer(url: URL, startAt: Double) {
        let item = AVPlayerItem(url: url)
        let name = url.isFileURL ? url.lastPathComponent : (url.host ?? "?")
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if item.status == .readyToPlay {
                    Diag.shared.log("system player ready: \(name), file says \(item.duration.seconds) s")
                    self.onEvent?(["type": "ready", "dur": self.itemDuration()])
                    self.updateNowPlaying()
                } else if item.status == .failed {
                    var event: [String: Any] = ["type": "error",
                                                "message": "player failed: \(SongDecoder.describe(item.error)) [\(name)]"]
                    if let id = self.currentID { event["id"] = id }
                    self.onEvent?(event)
                }
            }
        }
        let center = NotificationCenter.default
        endObserver = center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            self?.finishCurrent()
        }
        failObserver = center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
            guard let self = self else { return }
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            var event: [String: Any] = ["type": "error",
                                        "message": "playback stopped: \(SongDecoder.describe(error)) [\(name)]"]
            /* With the id the page knows which song this is about (it retries that song once). */
            if let id = self.currentID { event["id"] = id }
            self.onEvent?(event)
        }
        player.replaceCurrentItem(with: item)
        if startAt > 0.5 {
            player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600))
        }
    }

    /// `reason` says who asked; `source` whether the system hears of it at once.
    func play(reason: String = "page", source: PlaybackReport.Source = .page) {
        wantPlay = true
        activateSession(reason: reason)
        if usingEngine {
            sound.play()
            sendState()
        } else {
            player.play()
        }
        if let changed = report.want(true, source: source, now: now()) {
            reportState(changed, reason: reason)
        }
        updateNowPlaying()
    }

    func pause(reason: String = "page", source: PlaybackReport.Source = .page) {
        wantPlay = false
        if usingEngine {
            sound.pause()
            sendState()
        } else {
            player.pause()
        }
        if let changed = report.want(false, source: source, now: now()) {
            reportState(changed, reason: reason)
        } else if report.pendingPauseAt != nil {
            schedulePendingPause(reason: reason)
        }
        updateNowPlaying()
    }

    private func now() -> Double { return ProcessInfo.processInfo.systemUptime }

    /// A pause from the page becomes real only if no play follows within the grace.
    private func schedulePendingPause(reason: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + PlaybackReport.pageGrace + 0.05) { [weak self] in
            guard let self = self, let changed = self.report.resolve(now: self.now()) else { return }
            self.reportState(changed, reason: reason + " (held \(PlaybackReport.pageGrace) s)")
            self.updateNowPlaying()
        }
    }

    /// The one place the system's playing / paused state is changed.
    private func reportState(_ playing: Bool, reason: String) {
        let state: MPNowPlayingPlaybackState = playing ? .playing : .paused
        if reportedState == state { return }
        reportedState = state
        MPNowPlayingInfoCenter.default().playbackState = state
        Diag.shared.log("now playing: state \(playing ? "playing" : "paused") (\(reason))")
    }

    /// Activates the audio session once; again only after the system took it away.
    private func activateSession(reason: String) {
        if sessionActive { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            sessionActive = true
            Diag.shared.log("audio session: activated (\(reason))")
        } catch {
            Diag.shared.log("audio session activate (\(reason)): \(SongDecoder.describe(error))", error: true)
        }
    }

    func seek(to seconds: Double) {
        if usingEngine {
            sound.seek(to: seconds)
            updateMixPlan()
            pushLight()
            DispatchQueue.main.async { [weak self] in
                self?.onEvent?(["type": "seeked"])
                self?.updateNowPlaying()
            }
            return
        }
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                self?.onEvent?(["type": "seeked"])
                self?.updateNowPlaying()
            }
        }
    }

    /// The page chose a song itself (load / loadSong from the page).
    func noteChosenByPage() {
        nowPlayingGuard.pageChose()
    }

    /// What is shown now, for the guard.
    private var shownMeta: NowPlayingMeta {
        return NowPlayingMeta(title: title, artist: artist, artwork: artworkAddress, duration: knownDuration)
    }

    func setMeta(title: String, artist: String, artwork: String, duration: Double, id: String? = nil) {
        let meta = NowPlayingMeta(title: title, artist: artist, artwork: artwork, duration: duration)
        if !nowPlayingGuard.acceptMeta(meta, id: id, current: currentID, now: ProcessInfo.processInfo.systemUptime) {
            if let id = id, !id.isEmpty, id != currentID {
                /* About a song that is not playing yet (the page describes a song it has just
                   chosen before asking for it): used when that song starts. */
                nowPlayingGuard.hold(meta, id: id)
                Diag.shared.log("now playing: page meta for another song kept until it plays", song: id)
            } else {
                Diag.shared.log("now playing: page meta for the previous song ignored (\(title.prefix(30)))", song: currentID ?? "-")
            }
            return
        }
        showMeta(meta)
    }

    /// The song that has just become the current one may have been described already.
    private func applyHeldMeta() {
        if let meta = nowPlayingGuard.takeHeld(for: currentID) { showMeta(meta) }
    }

    private func showMeta(_ meta: NowPlayingMeta) {
        let title = meta.title, artist = meta.artist, artwork = meta.artwork, duration = meta.duration
        self.title = title
        self.artist = artist
        /* The page's list gives whole seconds. When that is just the rounded form of the exact
           length we already have, keep the exact one. */
        if duration > 0 && abs(duration - knownDuration) > 1.5 { knownDuration = duration }
        loadArtwork(artwork)
        updateNowPlaying()
    }

    func setDuration(_ seconds: Double, id: String? = nil) {
        guard nowPlayingGuard.acceptDuration(seconds, id: id, current: currentID, now: ProcessInfo.processInfo.systemUptime) else { return }
        if seconds > 0 && abs(seconds - knownDuration) > 0.05 {
            knownDuration = seconds
            updateNowPlaying()
        }
    }

    /// Takes the songs that follow. `key` describes the list; the same list again, with nothing
    /// having happened in between, changes nothing and returns false.
    @discardableResult
    func setQueue(_ tracks: [Track], key: String) -> Bool {
        if key == lastQueueKey { return false }
        lastQueueKey = key
        upNext = tracks
        for track in tracks {
            if let info = track.mix { remember(info, of: track.id) }
        }
        prefetchNext()
        updateMixPlan()
        return true
    }

    // MARK: sound settings

    private static let settingsFile: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("fx.json")
    }()

    /// Surround and make-up gain. `message` is the page's command as it came; it is kept on
    /// disk so that a song started before the page has spoken (after a relaunch) sounds the same.
    func setEffect(_ settings: SurroundSettings, message: [String: Any]) {
        sound.setEffect(settings)
        if let data = try? JSONSerialization.data(withJSONObject: message) {
            try? data.write(to: NativePlayer.settingsFile, options: .atomic)
        }
    }

    func setEQ(_ gains: [Float]) {
        sound.setEQ(gains)
        UserDefaults.standard.set(gains.map { Double($0) }, forKey: "eqGains")
    }

    func setLoudness(on: Bool, target: Double) {
        normOn = on
        normTarget = min(-5, max(-16, target))
        UserDefaults.standard.set(on, forKey: "normOn")
        UserDefaults.standard.set(normTarget, forKey: "normTarget")
        if let id = currentID { applyLoudnessGain(of: id, smooth: true) }
        if let id = incoming?.id { applyLoudnessGain(of: id, smooth: true) }
    }

    // MARK: mixing

    /// The user's switch.
    func setMix(on: Bool) {
        mixOn = on
        UserDefaults.standard.set(on, forKey: "mixOn")
        updateMixPlan()
    }

    /// What the PC found out about a song (it may arrive after the song was loaded or queued).
    func setMixInfo(_ info: MixAnalysis, of id: String) {
        remember(info, of: id)
        updateMixPlan()
    }

    private func remember(_ info: MixAnalysis, of id: String) {
        if mixInfo.count > 400 { mixInfo.removeAll() }
        mixInfo[id] = info
    }

    /// Works out again whether and how the current song goes over into the next one, and
    /// tells the engine. Called whenever something it depends on has changed. Everything is
    /// decided here, from what the app has stored: it also works with the page asleep.
    private func updateMixPlan() {
        guard usingEngine, let a = currentID else { return }
        var decision = MixDecision.none("no next song")
        var file: URL?
        var b = ""
        if let next = upNext.first {
            b = next.id
            file = Downloads.shared.localURL(b) ?? StreamCache.shared.cachedURL(b)
            if mixGivenUp.contains(a + ">" + b) {
                decision = .none("this mix failed before")
            } else if file == nil {
                /* Never wait for it: the current song ends in the ordinary way instead. */
                decision = .none("the next song is not on the phone yet")
            } else {
                decision = MixPlanner.plan(a: mixInfo[a], b: mixInfo[b],
                                           durationA: SongAnalyzer.shared.length(a) ?? 0,
                                           availableB: SongAnalyzer.shared.length(b) ?? 0,
                                           mixOn: mixOn)
            }
        }
        var line = ""
        switch decision {
        case .plan(let p):
            line = String(format: "mix plan %@ -> %@: startA %.3f overlap %.3f end %.3f bOffset %.3f bDelay %.3f synced %@",
                          a, b, p.startA, p.overlap, p.end, p.bOffset, p.bDelay, p.synced ? "yes" : "no")
            sound.setMixOffer(p, id: b, file: file, reason: "the queue changed")
        case .none(let reason):
            line = "no mix \(a) -> \(b.isEmpty ? "-" : b): \(reason)"
            sound.setMixOffer(nil, id: b, file: nil, reason: "the queue changed (\(reason))")
        }
        if line != lastMixLog {
            lastMixLog = line
            Diag.shared.log(line, song: a)
        }
    }

    private func mixEvent(_ stage: String, _ plan: MixPlan, to id: String, reason: String?) {
        var event: [String: Any] = ["type": "mix", "stage": stage, "from": currentID ?? "", "to": id,
                                    "overlap": plan.overlap, "synced": plan.synced]
        if let reason = reason { event["reason"] = reason }
        onEvent?(event)
    }

    /// The engine reports on a mix.
    private func mixReported(_ stage: String, _ plan: MixPlan, _ id: String, _ reason: String?) {
        switch stage {
        case "armed":
            /* The fade is in the outgoing song's samples, a few seconds before it is heard.
               The page hears of the start when it is heard (see tick). */
            incoming = upNext.first(where: { $0.id == id })
            incomingFile = Downloads.shared.localURL(id) ?? StreamCache.shared.cachedURL(id)
            mixStartSent = false
            applyLoudnessGain(of: id, smooth: false)
        case "done":
            /* The page counts on every "start" being followed by one "done" or "cancel": these
               two go out whatever else is known. */
            if !mixStartSent {
                mixStartSent = true
                mixEvent("start", plan, to: id, reason: nil)
            }
            mixEvent("done", plan, to: id, reason: nil)
            let known = incoming?.id == id ? incoming : upNext.first(where: { $0.id == id })
            guard let file = incomingFile ?? Downloads.shared.localURL(id) ?? StreamCache.shared.cachedURL(id) else {
                Diag.shared.log("mix done, but the song's file is not known", error: true, song: id)
                return
            }
            let track = known ?? Track(id: id, url: file, title: title, artist: artist, artwork: artworkAddress, duration: 0)
            nowPlayingGuard.advancedBySelf(from: shownMeta, now: ProcessInfo.processInfo.systemUptime)
            /* From here on the incoming song is the current one: what is shown, what `time`
               reports, what the lock screen says. It carries on from where it is. */
            incoming = nil
            incomingFile = nil
            if let at = upNext.firstIndex(where: { $0.id == id }) { upNext.removeFirst(at + 1) }
            lastQueueKey = nil
            waitToken += 1
            waitingID = nil
            finishing = false
            currentID = id
            currentFile = file
            title = track.title
            artist = track.artist
            knownDuration = track.duration
            loadArtwork(track.artwork)
            applyHeldMeta()
            if let seconds = SongAnalyzer.shared.length(id) { adoptLength(seconds, of: id) }
            lastMixLog = ""
            onEvent?(["type": "advanced", "id": id])
            sendState()
            /* The page waits for the first position before it shows the new song (it is already
               some seconds in): send one now instead of at the next quarter second. */
            onEvent?(["type": "time", "t": currentTime(), "dur": itemDuration(), "playing": isPlaying()])
            SongAnalyzer.shared.analyze(id: id, file: file)
            prefetchNext()
            updateMixPlan()
        default:
            mixEvent("cancel", plan, to: id, reason: reason)
            incoming = nil
            incomingFile = nil
            /* A mix that failed for a reason of its own is not tried again for this pair;
               one that the user or the queue ended may be planned again. */
            let ours = reason ?? ""
            if !(ours == "seek" || ours.hasPrefix("the queue changed") || ours == "another song was chosen" || ours == "stopped"),
               let a = currentID {
                mixGivenUp.insert(a + ">" + id)
                if mixGivenUp.count > 200 { mixGivenUp.removeAll() }
            }
            lastMixLog = ""
        }
    }

    /// Reads a page `fx` command (also the copy kept on disk).
    static func effect(from message: [String: Any]) -> SurroundSettings {
        func wav(_ value: Any?) -> Data? {
            guard let text = value as? String, !text.isEmpty else { return nil }
            return Data(base64Encoded: text, options: .ignoreUnknownCharacters)
        }
        var makeup: Float = 1
        if let n = message["makeup"] as? NSNumber, n.doubleValue.isFinite, n.doubleValue > 0 {
            makeup = Float(min(16, n.doubleValue))
        }
        return SurroundSettings(key: message["key"] as? String ?? "",
                                surround: message["surround"] as? Bool ?? false,
                                irLeft: wav(message["irL"]), irRight: wav(message["irR"]), makeup: makeup)
    }

    private func restoreSoundSettings() {
        if let data = try? Data(contentsOf: NativePlayer.settingsFile),
           let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            sound.setEffect(NativePlayer.effect(from: message))
        } else {
            /* Nothing remembered yet (first start): the level the page uses with surround off,
               so the first song does not start louder than it will be a moment later. */
            sound.setEffect(SurroundSettings(key: "off", surround: false, irLeft: nil, irRight: nil, makeup: 0.708))
        }
        let defaults = UserDefaults.standard
        if let gains = defaults.array(forKey: "eqGains") as? [Double] {
            sound.setEQ(gains.map { Float($0) })
        }
        if defaults.object(forKey: "normTarget") != nil {
            normOn = defaults.bool(forKey: "normOn")
            normTarget = defaults.double(forKey: "normTarget")
        }
    }

    /// Loudness balancing: bring the song to the target loudness, within -12 ... +6 dB; until
    /// the song has been measured, -4 dB (the same rule as the PC server).
    /// Each song has its own gain, so two songs of different loudness can sound together
    /// during a mix, each at its own balanced level.
    private func applyLoudnessGain(of id: String, smooth: Bool) {
        var db = 0.0
        if normOn {
            if let lufs = SongAnalyzer.shared.loudness(id) {
                db = min(6, max(-12, normTarget - lufs))
            } else {
                db = -4
            }
        }
        sound.setGain(db: Float(db), smooth: smooth, id: id)
    }

    /// The song's real length, counted from its decoded sound. Used when the page gave none, or
    /// one that is clearly something else (the page's list has whole seconds; the file's own
    /// figure can be double).
    private func adoptLength(_ seconds: Double, of id: String) {
        guard id == currentID, usingEngine, seconds > 1 else { return }
        if knownDuration <= 0 || abs(knownDuration - seconds) < 1.5 {
            knownDuration = seconds
            updateNowPlaying()
        }
    }

    // MARK: the engine reports

    private func engineEnded() {
        guard usingEngine else { return }
        let at = sound.position
        /* The decoder ran out long before the song's real end: that is not "song over". Carry
           on with the plain player from here. */
        if knownDuration > 0 && at < knownDuration - 5 {
            engineFailed("decoder stopped at \(Int(at)) s of \(Int(knownDuration)) s", at: at)
            return
        }
        finishCurrent()
    }

    /// The engine cannot play this song: let the plain player take over so there is music,
    /// and tell the page that the sound settings do not apply.
    private func engineFailed(_ message: String, at position: Double) {
        guard usingEngine, let file = currentFile else { return }
        usingEngine = false
        sound.stop(keepRunning: false)
        onEvent?(["type": "fxUnavailable", "id": currentID ?? "", "message": message])
        openInSystemPlayer(url: file, startAt: position)
        if wantPlay { player.play() }
    }

    // MARK: downloads ahead

    /// Downloads the next song while the current one plays, so it can start from its file the
    /// moment this one ends, also with the screen locked and the page asleep.
    private func prefetchNext() {
        for next in aheadTracks() {
            let id = next.id
            if let file = Downloads.shared.localURL(id) ?? StreamCache.shared.cachedURL(id) {
                /* Already here: measured now, so its loudness gain is right from the first note. */
                SongAnalyzer.shared.analyze(id: id, file: file)
                continue
            }
            guard let headers = next.headers, !failedPrefetch.contains(next.url) else { continue }
            let address = next.url
            prefetchID = id
            StreamCache.shared.fetch(id: id, url: address, headers: headers, size: next.size,
                progress: nil,
                done: { [weak self] file, message in
                    if let file = file {
                        SongAnalyzer.shared.analyze(id: id, file: file)
                        self?.updateMixPlan()
                        /* This one is here: now the one after it, so that a mix out of a short
                           song finds its next song on the phone too. */
                        self?.prefetchNext()
                        return
                    }
                    guard let self = self else { return }
                    if self.failedPrefetch.count > 50 { self.failedPrefetch.removeAll() }
                    self.failedPrefetch.insert(address)
                    /* Not an "error" event: the page reads every "error" as "the song that is
                       playing failed" and skips it. This one only says the address of a later
                       song is no good, so the page can look it up again in time. */
                    self.onEvent?(["type": "prefetchError", "id": id, "message": message ?? "download failed"])
                })
        }
        sweepDownloads()
    }

    /// The songs to have on the phone ahead of time: the next one, and as soon as that one is
    /// here (its download finished, or it was stored), the one after it.
    private func aheadTracks() -> [Track] {
        var out: [Track] = []
        for track in upNext.prefix(2) {
            out.append(track)
            if Downloads.shared.localURL(track.id) == nil && StreamCache.shared.cachedURL(track.id) == nil { break }
        }
        return out
    }

    /// Stops downloads nobody is waiting for: all but the song about to play and those wanted
    /// ahead of time.
    private func sweepDownloads() {
        var keep = Set<String>()
        if let id = waitingID { keep.insert(id) }
        for track in aheadTracks() where track.headers != nil { keep.insert(track.id) }
        /* While the page looks up addresses again it sends a shorter queue (often an empty one)
           and the full one a moment later. A download ahead that is under way is therefore not
           stopped at once when its song drops off the list, only if it stays off for a while;
           if the song comes back, the same download simply carries on. */
        if let ahead = prefetchID {
            if keep.contains(ahead) {
                prefetchDropAt = nil
            } else if let dropAt = prefetchDropAt {
                if Date() < dropAt {
                    keep.insert(ahead)
                } else {
                    prefetchID = nil
                    prefetchDropAt = nil
                }
            } else {
                prefetchDropAt = Date().addingTimeInterval(6)
                keep.insert(ahead)
                DispatchQueue.main.asyncAfter(deadline: .now() + 6.2) { [weak self] in self?.sweepDownloads() }
            }
        }
        StreamCache.shared.cancel(except: keep)
    }

    // MARK: moving on

    private func start(_ track: Track) {
        knownDuration = track.duration
        title = track.title
        artist = track.artist
        loadArtwork(track.artwork)
        if let headers = track.headers {
            /* Normally the file is already here (see prefetchNext) and this starts at once.
               If it is not, nothing is audible until the download ends. The audio session is
               left active and StreamCache holds a background task for the length of the
               download, so the app keeps running for that gap with the screen locked.
               `play()` below records that we want sound; loadSong starts it when the file
               arrives. */
            loadSong(id: track.id, url: track.url, headers: headers, size: track.size, startAt: 0,
                     duration: track.duration)
        } else {
            load(url: track.url, startAt: 0)
        }
        play(reason: "next song")
        prefetchNext()
    }

    /// The current song is over: start the next one here if we know it, otherwise ask the page.
    private func finishCurrent() {
        if finishing { return }
        finishing = true
        if !upNext.isEmpty {
            let track = upNext.removeFirst()
            nowPlayingGuard.advancedBySelf(from: shownMeta, now: ProcessInfo.processInfo.systemUptime)
            start(track)
            onEvent?(["type": "advanced", "id": track.id])
        } else {
            wantPlay = false
            /* The page usually carries on with another song: held like a page pause. */
            if report.want(false, source: .page, now: now()) == nil, report.pendingPauseAt != nil {
                schedulePendingPause(reason: "queue ended")
            }
            onEvent?(["type": "ended"])
        }
    }

    private func currentTime() -> Double {
        let t = usingEngine ? sound.position : player.currentTime().seconds
        return t.isFinite ? t : 0
    }

    private func isPlaying() -> Bool {
        return usingEngine ? sound.isPlaying : player.timeControlStatus != .paused
    }

    private func tick() {
        pushLight()
        let playing = isPlaying()
        if usingEngine && !playing { return }   // nothing moves while paused
        let t = currentTime()
        if let id = currentID, listen.feed(id: id, position: t, playing: playing, duration: knownDuration) {
            onListened?(id, title, artist, artworkAddress, knownDuration)
        }
        if usingEngine, let plan = sound.mixPlan, let to = incoming?.id {
            if !mixStartSent && t >= plan.startA {
                mixStartSent = true
                Diag.shared.log("mix start", song: to)
                mixEvent("start", plan, to: to, reason: nil)
            }
            sound.watchMix()
        }
        let dur = itemDuration()
        /* The file sometimes claims to be longer than the song; past the real end is silence. */
        if knownDuration > 0 && dur > knownDuration + 2 && t >= knownDuration - 0.3 && playing {
            finishCurrent()
            return
        }
        /* `exact`: the length is the song's own (measured by the app or given by the page), not
           what the file claims - which can be twice as long. */
        onEvent?(["type": "time", "t": t, "dur": dur, "playing": playing, "exact": usingEngine && knownDuration > 0])
    }

    private func sendState() {
        onEvent?(["type": "state", "playing": isPlaying()])
        updateNowPlaying()
        pushLight()
    }

    /// Tells the music light where the music is (nothing when the light is off).
    private func pushLight() {
        let music = LightMusic.shared
        guard music.settings.on else { return }
        var now = LightPlayback()
        now.id = currentID
        now.position = currentTime()
        now.at = CACurrentMediaTime()
        now.playing = isPlaying()
        if usingEngine {
            now.plan = sound.mixPlan
            now.incoming = sound.mixTargetID
        }
        now.next = upNext.first?.id
        now.latency = AVAudioSession.sharedInstance().outputLatency
        music.update(now)
    }

    /// The song's length as told to the page. With the engine the real length is used when we
    /// know it (the engine also ends at the real end of the sound, whatever the file claims).
    private func itemDuration() -> Double {
        if usingEngine { return knownDuration > 0 ? knownDuration : sound.statedDuration }
        let d = player.currentItem?.duration.seconds ?? 0
        return d.isFinite ? d : 0
    }

    private func removeItemObservers() {
        statusObservation?.invalidate()
        statusObservation = nil
        let center = NotificationCenter.default
        if let o = endObserver { center.removeObserver(o) }
        if let o = failObserver { center.removeObserver(o) }
        endObserver = nil
        failObserver = nil
    }

    // MARK: lock screen and Control Centre

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            self?.play(reason: "remote play", source: .immediate)
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            self?.pause(reason: "remote pause", source: .immediate)
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.wantPlay {
                self.pause(reason: "remote toggle", source: .immediate)
            } else {
                self.play(reason: "remote toggle", source: .immediate)
            }
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            /* The next song is already coming in: let it take over now. */
            if self.usingEngine, self.incoming != nil, self.sound.finishMixNow() { return .success }
            if !self.upNext.isEmpty {
                self.finishing = false
                self.finishCurrent()
            } else {
                self.onEvent?(["type": "remote", "action": "next"])
            }
            return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.currentTime() > 3 {
                self.seek(to: 0)
            } else {
                self.onEvent?(["type": "remote", "action": "prev"])
            }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: e.positionTime)
            return .success
        }
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist
        ]
        /* The length the page gave wins: the file's own figure can be about double. */
        let dur = knownDuration > 0 ? knownDuration : itemDuration()
        if dur > 0 { info[MPMediaItemPropertyPlaybackDuration] = dur }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime()
        /* What the system was told, not what the engine does this instant: a song change, a
           download wait, a seek or a mix hand-over must not look like a pause. */
        info[MPNowPlayingInfoPropertyPlaybackRate] = report.playing ? 1.0 : 0.0
        if let art = artwork { info[MPMediaItemPropertyArtwork] = art }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(_ address: String) {
        if address == artworkAddress { return }
        artworkAddress = address
        artwork = nil
        guard let url = URL(string: address) else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data, let image = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                guard let self = self, self.artworkAddress == address else { return }
                self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.updateNowPlaying()
            }
        }.resume()
    }

    // MARK: other apps and headphones

    @objc private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            Diag.shared.log("interruption began, wanted to play: \(wantPlay)")
            interruptedWhilePlaying = wantPlay
            /* The system has deactivated the session. */
            sessionActive = false
            if usingEngine { sound.interrupted() }
            wantPlay = false
            if let changed = report.want(false, source: .immediate, now: now()) {
                reportState(changed, reason: "interruption")
            }
            updateNowPlaying()
            sendState()
        } else {
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            Diag.shared.log("interruption ended, should resume: \(options.contains(.shouldResume))")
            if interruptedWhilePlaying && options.contains(.shouldResume) {
                play(reason: "interruption ended", source: .immediate)
            }
            interruptedWhilePlaying = false
            sendState()
        }
    }

    @objc private func handleBackground() {
        if usingEngine { sound.enteredBackground() }
    }

    @objc private func handleMediaReset() {
        Diag.shared.log("audio session: media services were reset")
        sessionActive = false
        configureSession()
        if wantPlay { play(reason: "media services reset") }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        /* Headphones taken off or disconnected: do not carry on through the phone speaker. */
        if reason == .oldDeviceUnavailable {
            DispatchQueue.main.async { [weak self] in
                Diag.shared.log("output device went away: pausing")
                self?.pause(reason: "output device went away", source: .immediate)
            }
        }
    }
}
