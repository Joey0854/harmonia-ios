import Accelerate
import AVFoundation

/// One song's way through the engine: its own player node and its own loudness gain. There
/// are two, so that the next song can come in while the current one goes out.
///
/// The fields under "shared" are used from the main queue, the path's worker and the audio
/// callbacks, always with `lock` held; everything else is for the main queue only.
private final class SoundPath {
    let name: String
    let node = AVAudioPlayerNode()
    /// Only its overall gain is used: this song's loudness-balancing gain. (An equaliser unit
    /// because its gain can go above 0 dB, which a mixer's volume cannot.)
    let gain = AVAudioUnitEQ(numberOfBands: 1)
    /// The processing loop runs here, one run after the other. The main queue never waits for it.
    let worker: DispatchQueue

    /* shared */
    let lock = NSLock()
    var generation = 0
    var scheduledFrames: Int64 = 0
    var playedFrames: Int64 = 0
    /// End of what has been given to the node, in frames of the node's own timeline.
    var scheduledEnd: Int64 = 0
    var allScheduled = false
    var endReported = false
    /// A mix this song may go out with, as soon as its processing reaches the right place.
    var plan: MixPlan?
    /// The plan may be taken up in the middle of its overlap (a mix that was already running).
    var joinRunning = false
    var planTaken = false

    /* main queue */
    var file: URL?
    var songID = ""
    var connectedRate: Double = 0
    /// Song position of frame 0 of the node's timeline.
    var base: Double = 0
    var rate: Double = 44100
    var lastPosition: Double = 0
    /// True from asking for a (re)start until its first piece is in the node.
    var restarting = false
    var statedDuration: Double = 0
    /// Incoming song only: the node has been told when to start.
    var anchored = false
    var gainDb: Float = 0
    var gainTimer: Timer?

    init(name: String) {
        self.name = name
        worker = DispatchQueue(label: "sound-path-" + name, qos: .userInitiated)
    }

    /// Makes every earlier run of this path pointless and returns the number of the new one.
    func newGeneration(plan: MixPlan?, joinRunning: Bool) -> Int {
        lock.lock()
        generation += 1
        let g = generation
        scheduledFrames = 0
        playedFrames = 0
        scheduledEnd = 0
        allScheduled = false
        endReported = false
        self.plan = plan
        self.joinRunning = joinRunning
        planTaken = false
        lock.unlock()
        return g
    }

    func isCurrent(_ g: Int) -> Bool {
        lock.lock()
        let same = generation == g
        lock.unlock()
        return same
    }

    func setPlan(_ new: MixPlan?) {
        lock.lock()
        if !planTaken {
            plan = new
            joinRunning = false
        }
        lock.unlock()
    }

    enum Due {
        case notYet
        case take(MixPlan)
        case tooLate
    }

    /// Called by the run for each piece it is about to shape (`start` ..< `end` in song
    /// seconds): is it time to go out with the mix?
    func planDue(_ g: Int, start: Double, end: Double) -> Due {
        lock.lock()
        defer { lock.unlock() }
        guard generation == g, !planTaken, let p = plan else { return .notYet }
        if end < p.startA { return .notYet }
        let latest = joinRunning ? p.startA + p.overlap : p.startA
        if start > latest + 0.0005 {
            plan = nil
            return .tooLate
        }
        planTaken = true
        return .take(p)
    }

    /// Frames given to the node and not yet played.
    func ahead(_ g: Int) -> Int64 {
        lock.lock()
        let value = generation == g ? scheduledFrames - playedFrames : 0
        lock.unlock()
        return value
    }
}

/// Plays song files with the user's sound settings applied, and mixes from one song into the
/// next:
///
///     file -> decode -> surround + make-up gain -> mix curves --> player node -> loudness gain --+
///     (per song, ahead of time, on the song's own queue)                                        sum -> equaliser -> limiter -> output
///     file -> decode -> surround + make-up gain -> mix curves --> player node -> loudness gain --+
///
/// Each song is processed a few seconds ahead of its play position and handed to its player
/// node piece by piece; a whole song is never held in memory. Seeking, or a change of the
/// surround setting, starts that processing again from the wanted position: the sound that is
/// playing carries on until the first new piece is ready, then the node switches over.
///
/// A mix (see MixPlanner): the level curves and the bass hand-over are computed into the two
/// songs' samples (MixShaper), so they are exact to the sample and need no timers. The
/// outgoing song's processing takes the plan up when it reaches the start of the overlap, a few
/// seconds before that is heard; the incoming song is then prepared on the other path and its
/// node is told the exact moment (on the audio clock) to start. When the outgoing song's last
/// faded sample has played, the incoming path simply is the current one.
///
/// The audio session, IO buffer size and sample rate are left exactly as the system sets them.
///
/// All methods and callbacks are for the main queue.
final class SoundEngine {
    /// The song can play; the number is its length as the file states it.
    var onReady: ((Double) -> Void)?
    /// The last piece of the song has been played (and no mix took over).
    var onEnded: (() -> Void)?
    /// The song cannot be played this way (message, position to carry on from).
    var onFailed: ((String, Double) -> Void)?
    /// A mix into the song `id`: stage "armed" (the outgoing song's fade is on its way to the
    /// speaker), "done" (that song is now the current one) or "cancel" (with the reason).
    var onMix: ((_ stage: String, _ plan: MixPlan, _ id: String, _ reason: String?) -> Void)?

    private let engine = AVAudioEngine()
    private let sum = AVAudioMixerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: 5)
    private var limiter: AVAudioUnitEffect?
    private let paths = [SoundPath(name: "a"), SoundPath(name: "b")]
    private var cur = 0
    private var current: SoundPath { return paths[cur] }
    private var spare: SoundPath { return paths[1 - cur] }

    private enum Role {
        case main
        case incoming(MixPlan)
    }

    private struct Offer {
        let plan: MixPlan
        let id: String
        let file: URL
    }

    /* Main queue only. */
    private var settings: SurroundSettings?
    /// The setting before a band mode was chosen (stands in while the band gets ready).
    private var bandFallback: SurroundSettings?
    /// A surround setting that arrived during a mix; applied when the mix is over.
    private var laterSettings: SurroundSettings??
    private var wantPlay = false
    private var announce = false
    /// The nodes have lost what was scheduled (interruption, change of output, pause during a
    /// mix): schedule again before playing.
    private var needsReschedule = false
    /// The mix the current song may go out with (from NativePlayer).
    private var offer: Offer?
    /// The mix that is under way: the current song's processing has taken the plan up.
    private var mix: Offer?

    /* Peaks just before the limiter (a tap on the equaliser's output, read on the tap's own
       thread, never the audio one): logged, and used to give each song a little headroom so
       that the limiter rarely has to act. */
    private static let ceiling: Float = 0.891     // the limiter starts at about -1 dBFS
    private static let maxCut: Float = 3          // dB the automatic headroom may take at most
    private let peakLock = NSLock()
    private var overBlocks = 0                    // since the last log line
    private var worstOver: Float = 0              // dB above the ceiling, since the last line
    private var songOver = 0
    private var songWorst: Float = 0
    private var cutTarget: Float = 0
    private var cutNow: Float = 0
    private var peakTicks = 0
    private var peakTimer: Timer?
    /// Automatic headroom on (default) or off (UserDefaults "autoHeadroom").
    static var autoHeadroom: Bool {
        get { return UserDefaults.standard.object(forKey: "autoHeadroom") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoHeadroom") }
    }

    init() {
        engine.attach(sum)
        engine.attach(eq)
        for path in paths {
            engine.attach(path.node)
            engine.attach(path.gain)
        }
        /* The five bands of the page's equaliser. A peaking band with Q 1 is 1.39 octaves wide. */
        let shapes: [(AVAudioUnitEQFilterType, Float)] = [
            (.lowShelf, 150), (.parametric, 400), (.parametric, 1500), (.parametric, 5000), (.highShelf, 10000)
        ]
        for (i, shape) in shapes.enumerated() {
            let band = eq.bands[i]
            band.filterType = shape.0
            band.frequency = shape.1
            band.bandwidth = 1.388
            band.gain = 0
            band.bypass = false
        }
        /* Apple's peak limiter stops at full scale. Raising its input by 1 dB and lowering the
           output by 1 dB afterwards leaves normal sound unchanged and puts the ceiling at
           about -1 dBFS. */
        var description = AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                                    componentSubType: kAudioUnitSubType_PeakLimiter,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple,
                                                    componentFlags: 0, componentFlagsMask: 0)
        if AudioComponentFindNext(nil, &description) != nil {
            let unit = AVAudioUnitEffect(audioComponentDescription: description)
            engine.attach(unit)
            /* Parameter 2 = pre-gain in dB, scope 0 = global (kLimiterParam_PreGain, kAudioUnitScope_Global). */
            let status = AudioUnitSetParameter(unit.audioUnit, 2, 0, 0, 1.0, 0)
            /* Parameter 1 = release (kLimiterParam_DecayTime, seconds, 0.001 ... 0.06, default
               0.024): the longest, so what the limiter still does is not heard as pumping.
               Read back for the log, since the range is from the header, not measured. */
            let decay = AudioUnitSetParameter(unit.audioUnit, 1, 0, 0, 0.06, 0)
            var attackNow: AudioUnitParameterValue = 0, decayNow: AudioUnitParameterValue = 0
            AudioUnitGetParameter(unit.audioUnit, 0, 0, 0, &attackNow)
            AudioUnitGetParameter(unit.audioUnit, 1, 0, 0, &decayNow)
            Diag.shared.log("engine: limiter present, pre-gain status \(status), decay status \(decay), attack \(attackNow) s, decay \(decayNow) s")
            limiter = unit
        } else {
            Diag.shared.log("engine: no limiter on this system", error: true)
        }
        /* After the sum everything runs at one fixed format; a song at another sample rate is
           converted where its path meets the sum. So nothing here is ever reconnected, and the
           engine never has to stop because the next song is different. */
        if let bus = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2) {
            engine.connect(sum, to: eq, format: bus)
            if let unit = limiter {
                engine.connect(eq, to: unit, format: bus)
                engine.connect(unit, to: engine.mainMixerNode, format: bus)
            } else {
                engine.connect(eq, to: engine.mainMixerNode, format: bus)
            }
            for path in paths { connect(path, bus) }
        }
        engine.mainMixerNode.outputVolume = 0.891
        eq.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            self?.measure(buffer)
        }
        peakTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.peakTick()
        }
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.configurationChanged()
        }
    }

    // MARK: commands

    /// Starts preparing a song. Nothing sounds until `play()`. Ends a mix that is under way.
    func load(file: URL, startAt: Double, id: String) {
        dropMix(reason: "another song was chosen", restartCurrent: false)
        unload(spare)
        let path = current
        path.file = file
        path.songID = id
        path.statedDuration = 0
        wantPlay = false
        announce = true
        needsReschedule = false
        restart(path, at: max(0, startAt), cutNow: true)
    }

    func play() {
        wantPlay = true
        let path = current
        guard path.file != nil else { return }
        if needsReschedule {
            needsReschedule = false
            if mix != nil {
                resumeMix()
            } else {
                restart(path, at: path.lastPosition, cutNow: true)
            }
            return
        }
        if path.restarting { return }   // `begin` starts the sound when it gets there
        guard startEngine() else {
            failNow("audio engine did not start")
            return
        }
        path.node.play()
    }

    func pause() {
        wantPlay = false
        let path = current
        if mix != nil {
            /* Two nodes cannot be paused and resumed at exactly the same instant. So during a
               mix both are emptied, and on resume both songs are prepared again from where they
               were, the second one timed against the first as at the start of the mix. */
            path.lastPosition = position
            _ = path.newGeneration(plan: nil, joinRunning: false)
            _ = spare.newGeneration(plan: nil, joinRunning: false)
            path.node.stop()
            spare.node.stop()
            spare.anchored = false
            needsReschedule = true
        } else if path.node.isPlaying {
            path.lastPosition = position
            path.node.pause()
        }
        engine.pause()
    }

    func seek(to seconds: Double) {
        let path = current
        guard path.file != nil else { return }
        dropMix(reason: "seek", restartCurrent: false)
        restart(path, at: max(0, seconds), cutNow: false)
    }

    /// Unloads everything. With `keepRunning` the output goes on (silent) for the song that
    /// comes next, so that the system does not see the sound stop.
    func stop(keepRunning: Bool = false) {
        dropMix(reason: "stopped", restartCurrent: false)
        unload(current)
        unload(spare)
        if !keepRunning { engine.pause() }
        wantPlay = false
        needsReschedule = false
    }

    /// The app has gone to the background. While paused nothing needs to be read, and an open
    /// file reader would be dead when the app comes back: let go of the readers now. What is
    /// needed is prepared again from the same position when `play()` comes.
    func enteredBackground() {
        guard !wantPlay, current.file != nil else { return }
        for path in paths where path.file != nil {
            _ = path.newGeneration(plan: nil, joinRunning: false)
            path.node.stop()
            path.restarting = false
        }
        spare.anchored = false
        needsReschedule = true
        Diag.shared.log("engine: paused in the background, files let go at \(String(format: "%.2f", current.lastPosition)) s")
    }

    /// Another app took the sound. The system has stopped the engine; what was scheduled may
    /// be gone when we get it back.
    func interrupted() {
        let path = current
        if path.file == nil { return }
        if path.node.isPlaying && engine.isRunning { path.lastPosition = position }
        wantPlay = false
        needsReschedule = true
    }

    var isPlaying: Bool { return wantPlay }

    var statedDuration: Double { return current.statedDuration }

    /// Where in the current song the listener is, in seconds.
    var position: Double { return position(of: current) }

    private func position(of path: SoundPath) -> Double {
        if path.restarting || !engine.isRunning || !path.node.isPlaying { return path.lastPosition }
        if let nodeTime = path.node.lastRenderTime, nodeTime.isSampleTimeValid,
           let playerTime = path.node.playerTime(forNodeTime: nodeTime) {
            path.lock.lock()
            let end = path.scheduledEnd
            path.lock.unlock()
            /* If processing ever falls behind, the node plays silence while its clock runs on;
               never report more than what was actually given to it. */
            let frames = min(max(0, playerTime.sampleTime), end)
            path.lastPosition = path.base + Double(frames) / path.rate
        }
        return path.lastPosition
    }

    // MARK: sound settings

    /// Surround and make-up gain. Takes effect on the playing song from its current position;
    /// during a mix, right after it (restarting two songs in step would be heard).
    func setEffect(_ new: SurroundSettings?) {
        if mix != nil {
            if new?.key == settings?.key { laterSettings = nil } else { laterSettings = .some(new) }
            return
        }
        if new?.key == settings?.key { return }
        /* switching into a band mode: the mode before stands in until the band is ready */
        if let n = new, n.surround, n.mode.isBand {
            if let old = settings, !(old.surround && old.mode.isBand) { bandFallback = old }
        } else {
            bandFallback = nil
        }
        settings = new
        Diag.shared.log("engine: effect \(new?.key ?? "none"), surround \(new?.surround ?? false), mode \(new?.mode.rawValue ?? "-")")
        if current.file != nil { restart(current, at: position, cutNow: false) }
    }

    /// Five gains in dB, low to high. Shared by both songs of a mix.
    func setEQ(_ gains: [Float]) {
        for (i, gain) in gains.prefix(5).enumerated() {
            eq.bands[i].gain = min(12, max(-12, gain))
        }
    }

    /// Loudness-balancing gain in dB of the song `id` (the current one, or the one coming in).
    /// A change while it plays glides over a quarter of a second instead of jumping.
    func setGain(db: Float, smooth: Bool, id: String) {
        for path in paths where path.file != nil && path.songID == id {
            path.gainDb = min(24, max(-40, db))
            glide(path, to: path.gainDb, seconds: smooth ? 0.25 : 0, then: nil)
        }
    }

    private func glide(_ path: SoundPath, to target: Float, seconds: Double, then: (() -> Void)?) {
        path.gainTimer?.invalidate()
        path.gainTimer = nil
        let from = path.gain.globalGain
        if seconds <= 0 || abs(target - from) < 0.05 {
            path.gain.globalGain = target
            then?()
            return
        }
        var step = 0
        let steps = 10
        path.gainTimer = Timer.scheduledTimer(withTimeInterval: seconds / Double(steps), repeats: true) { [weak path] timer in
            step += 1
            path?.gain.globalGain = from + (target - from) * Float(step) / Float(steps)
            if step >= steps {
                timer.invalidate()
                then?()
            }
        }
    }

    // MARK: mixing

    /// The mix the current song may go out with: into song `id` (file on the phone) by `plan`.
    /// nil = none. Once a mix is under way a different target ends it (`reason` is reported);
    /// a merely recalculated plan for the same target is ignored.
    func setMixOffer(_ plan: MixPlan?, id: String, file: URL?, reason: String) {
        if let m = mix {
            if plan == nil || id != m.id { dropMix(reason: reason, restartCurrent: true) } else { return }
        }
        if let plan = plan, let file = file {
            if let o = offer, o.plan == plan, o.id == id { return }
            offer = Offer(plan: plan, id: id, file: file)
            current.setPlan(plan)
            /* band modes: the incoming song's first segments separated before the mix */
            prefetchBand(id: id, file: file, from: plan.bOffset, seconds: plan.overlap + 15)
        } else {
            offer = nil
            current.setPlan(nil)
        }
    }

    /// Band modes: separate the start of the next song ahead of time (for a mix from
    /// `position`; without one from its start). Nothing in other modes.
    func prefetchBand(id: String, file: URL, from position: Double, seconds: Double) {
        guard let s = settings, s.surround, s.mode.isBand,
              let network = SurroundChain.bandNetwork?() else {
            BandPrefetch.shared.cancel("not in a band mode")
            return
        }
        BandPrefetch.shared.prepare(id: id, file: file, from: position, seconds: seconds,
                                    network: network, queue: SurroundChain.bandQueue)
    }

    /// The plan of the mix under way, if any.
    var mixPlan: MixPlan? { return mix?.plan }
    /// The song coming in with the mix under way, if any.
    var mixTargetID: String? { return mix?.id }

    /// Called regularly while playing. If the overlap is about to be heard and the incoming
    /// song is not in place, the mix is given up in time: the current song is prepared again
    /// without its fade and plays to its own end.
    func watchMix() {
        guard let m = mix, wantPlay, !spare.anchored else { return }
        if position >= m.plan.startA - 0.4 {
            dropMix(reason: "the next song was not ready in time", restartCurrent: true)
        }
    }

    /// "Next" while the incoming song is already sounding: the outgoing one fades out in 150 ms
    /// and the incoming one is the current song from here on. False = no such mix; do the
    /// ordinary thing.
    func finishMixNow() -> Bool {
        guard let m = mix, spare.anchored, position >= m.plan.startA + m.plan.bDelay else { return false }
        let old = current
        _ = old.newGeneration(plan: nil, joinRunning: false)
        fadeOutAndUnload(old)
        cur = 1 - cur
        completeMix(m)
        return true
    }

    /// The outgoing song's last faded piece has played (or it was faded out early): the
    /// incoming path is the current one now.
    private func completeMix(_ m: Offer) {
        mix = nil
        offer = nil
        current.setPlan(nil)
        Diag.shared.log("mix done: now playing from path \(current.name)", song: m.id)
        applyLaterSettings()
        onMix?("done", m.plan, m.id, nil)
    }

    /// Ends a mix that is planned or under way. The incoming song fades out quickly; the
    /// current song, if its fade had been taken up, is prepared again without it.
    private func dropMix(reason: String, restartCurrent: Bool) {
        offer = nil
        current.setPlan(nil)
        guard let m = mix else { return }
        BandPrefetch.shared.cancel("mix cancelled: \(reason)")
        mix = nil
        Diag.shared.log("mix cancel: \(reason)", song: m.id)
        _ = spare.newGeneration(plan: nil, joinRunning: false)
        fadeOutAndUnload(spare)
        if let later = laterSettings {
            settings = later
            laterSettings = nil
        }
        if restartCurrent, current.file != nil {
            if wantPlay {
                restart(current, at: position, cutNow: false)
            } else {
                needsReschedule = false
                restart(current, at: current.lastPosition, cutNow: true)
            }
        }
        onMix?("cancel", m.plan, m.id, reason)
    }

    private func applyLaterSettings() {
        guard let later = laterSettings else { return }
        laterSettings = nil
        settings = later
        Diag.shared.log("engine: effect \(later?.key ?? "none") (held back during the mix)")
        if current.file != nil { restart(current, at: position, cutNow: false) }
    }

    /// The current song's processing has taken the plan up (worker -> main).
    private func planTaken(_ path: SoundPath, _ g: Int, _ plan: MixPlan) {
        guard path === current, path.isCurrent(g) else { return }
        if mix != nil { return }   // taken up again after a pause or an interruption
        guard let o = offer, o.plan == plan else {
            /* The offer changed in the meantime, but the fade is already in the samples:
               prepare the song again without it. */
            restart(path, at: position, cutNow: false)
            return
        }
        mix = o
        let p = o.plan
        Diag.shared.log(String(format: "mix armed: startA %.3f overlap %.3f end %.3f bOffset %.3f bDelay %.3f synced %@",
                               p.startA, p.overlap, p.end, p.bOffset, p.bDelay, p.synced ? "yes" : "no"), song: o.id)
        let incoming = spare
        incoming.file = o.file
        incoming.songID = o.id
        incoming.statedDuration = 0
        onMix?("armed", o.plan, o.id, nil)   // the incoming song's loudness gain is set in here
        guard mix != nil else { return }
        restart(incoming, at: p.bOffset, cutNow: true, role: .incoming(p))
    }

    /// The plan came too late for this run (worker -> main).
    private func planMissed(_ path: SoundPath, _ g: Int) {
        guard path === current, path.isCurrent(g) else { return }
        if mix != nil {
            /* Taken up again too close to the end of the overlap: the current song simply
               plays on to its own end. */
            dropMix(reason: "resumed after the overlap", restartCurrent: false)
        } else if offer != nil {
            Diag.shared.log("mix: too late for this song")
            offer = nil
        }
    }

    /// After a pause, an interruption or a change of output during a mix: both songs again,
    /// from where the current one was.
    private func resumeMix() {
        guard let m = mix else { return }
        let a = current
        let positionA = a.lastPosition
        let positionB = m.plan.bOffset + max(0, positionA - m.plan.startA - m.plan.bDelay)
        spare.anchored = false
        if positionA >= m.plan.startA + m.plan.overlap - 0.05 {
            /* The outgoing song had all but gone: carry on with the incoming one alone. */
            unload(a)
            cur = 1 - cur
            completeMix(m)
            restart(current, at: positionB, cutNow: true)
            return
        }
        restart(a, at: positionA, cutNow: true)
        restart(spare, at: positionB, cutNow: true, role: .incoming(m.plan))
    }

    private func fadeOutAndUnload(_ path: SoundPath) {
        path.lock.lock()
        let g = path.generation
        path.lock.unlock()
        path.restarting = false
        path.anchored = false
        path.file = nil
        glide(path, to: -60, seconds: 0.15) { [weak self, weak path] in
            guard let path = path, path.isCurrent(g) else { return }
            path.node.stop()
            path.gain.globalGain = 0
            _ = self
        }
    }

    private func unload(_ path: SoundPath) {
        _ = path.newGeneration(plan: nil, joinRunning: false)
        path.gainTimer?.invalidate()
        path.gainTimer = nil
        path.node.stop()
        path.file = nil
        path.restarting = false
        path.anchored = false
    }

    // MARK: (re)starting

    private func restart(_ path: SoundPath, at position: Double, cutNow: Bool, role: Role = .main) {
        guard let file = path.file else { return }
        var plan: MixPlan?
        var join = false
        if case .main = role, path === current {
            plan = mix?.plan ?? offer?.plan
            join = mix != nil
        }
        let g = path.newGeneration(plan: plan, joinRunning: join)
        path.restarting = true
        path.lastPosition = position
        if cutNow { path.node.stop() }
        let settings = self.settings
        let fallback = self.bandFallback
        let label = path.songID
        path.worker.async { [weak self] in
            self?.run(path, g, label: label, file: file, from: position, settings: settings, fallback: fallback, role: role)
        }
    }

    private enum Handed {
        case more
        case done    // the song's part is over: nothing further to process
        case stop    // this run is no longer wanted
    }

    /// The processing loop for one (re)start of one path. Runs on the path's worker until the
    /// song is fully scheduled or a newer (re)start has made this run pointless.
    private func run(_ path: SoundPath, _ g: Int, label: String, file: URL, from position: Double, settings: SurroundSettings?,
                     fallback: SurroundSettings?, role: Role) {
        if !path.isCurrent(g) { return }
        let decoder: SongDecoder
        var piece: (left: [Float], right: [Float])?
        do {
            /* The song coming in during a mix must sit exactly where the plan puts it: its
               samples are counted from the start of the file (it starts near its beginning,
               so that costs little). Otherwise the quick way is taken. */
            var exact = false
            if case .incoming = role { exact = true }
            decoder = try SongDecoder(url: file, startAt: position, exact: exact)
            /* A reader that died (the app was suspended) is replaced inside the decoder; the
               few seconds already waiting in the node cover the moment that takes. */
            decoder.onReopen = { message in Diag.shared.log(message, song: label) }
            piece = try decoder.next()
        } catch {
            fail(path, g, "cannot decode: \(error)", at: position)
            return
        }
        guard piece != nil else {
            if position > 1 {
                /* Asked to start at or after the end. */
                DispatchQueue.main.async { self.finished(path, g) }
            } else {
                fail(path, g, "the file holds no sound", at: position)
            }
            return
        }
        let rate = decoder.sampleRate
        guard rate >= 8000, let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else {
            fail(path, g, "unusable sample rate \(rate)", at: position)
            return
        }
        let chain = SurroundChain(settings: settings, sampleRate: Int(rate.rounded()), song: label, startTime: decoder.startTime,
                                  fallback: fallback)
        if let problem = chain.problem { Diag.shared.log("engine: \(problem)", error: true) }
        let startTime = decoder.startTime
        let stated = decoder.statedDuration
        let aheadLimit = Int64(4 * rate)

        var started = false
        /* Frames this run has produced so far; the next piece begins at this frame. */
        var emitted: Int64 = 0
        /* The mix curves, once this song is part of a mix; `overlapAt` is the frame of this run
           at which the overlap begins (negative when the run began inside it). */
        var shaper: MixShaper?
        var overlapAt: Int64 = 0
        /* Outgoing song: the frame after which it is silent, so nothing more is needed. */
        var stopAt = Int64.max
        /* Incoming song: its pieces are placed at exact frames of the node's timeline, which
           begins `skip` frames into this run. */
        var exact = false
        var skip: Int64 = 0
        if case .incoming(let plan) = role {
            shaper = MixShaper(role: .incoming, synced: plan.synced, overlap: plan.overlap, sampleRate: rate)
            overlapAt = -Int64(((plan.bDelay + (startTime - plan.bOffset)) * rate).rounded())
            exact = true
        }

        func hand(_ out: (left: [Float], right: [Float])) -> Handed {
            var left = out.left, right = out.right
            let produced = Int64(min(left.count, right.count))
            if produced == 0 { return .more }
            let first = emitted
            emitted += produced

            if shaper == nil, case .main = role {
                let from = startTime + Double(first) / rate
                switch path.planDue(g, start: from, end: from + Double(produced) / rate) {
                case .take(let plan):
                    let made = MixShaper(role: .outgoing, synced: plan.synced, overlap: plan.overlap, sampleRate: rate)
                    shaper = made
                    overlapAt = Int64(((plan.startA - startTime) * rate).rounded())
                    stopAt = overlapAt + Int64(made.overlapSamples)
                    DispatchQueue.main.async { self.planTaken(path, g, plan) }
                case .tooLate:
                    DispatchQueue.main.async { self.planMissed(path, g) }
                case .notYet:
                    break
                }
            }
            if let s = shaper { s.process(left: &left, right: &right, firstSample: Int(first - overlapAt)) }

            var count = produced
            var last = false
            if first + count >= stopAt {
                count = max(0, stopAt - first)
                left = Array(left[0..<Int(count)])
                right = Array(right[0..<Int(count)])
                last = true
            }
            if count > 0, let buffer = SoundEngine.buffer((left, right), format: format) {
                if !started {
                    started = true
                    switch role {
                    case .main:
                        var accepted = false
                        DispatchQueue.main.sync {
                            accepted = self.begin(path, g, format: format, base: startTime, stated: stated, first: buffer)
                        }
                        if !accepted { return .stop }
                    case .incoming(let plan):
                        /* Wait until the outgoing song is playing, then have this node told
                           when to start. */
                        var answer = Anchor.wait
                        while true {
                            DispatchQueue.main.sync {
                                answer = self.beginIncoming(path, g, plan: plan, format: format, startTime: startTime, stated: stated)
                            }
                            if case .wait = answer {
                                Thread.sleep(forTimeInterval: 0.1)
                                if !path.isCurrent(g) { return .stop }
                                continue
                            }
                            break
                        }
                        guard case .go(let frames) = answer else { return .stop }
                        skip = frames
                        schedule(path, buffer, g, at: first - skip)
                    }
                } else if exact {
                    schedule(path, buffer, g, at: first - skip)
                } else {
                    schedule(path, buffer, g, at: nil)
                }
            }
            return last ? .done : .more
        }

        var over = false
        while let input = piece, !over {
            if !path.isCurrent(g) { return }
            switch hand(chain.process(left: input.left, right: input.right)) {
            case .stop:
                return
            case .done:
                over = true
                continue
            case .more:
                break
            }
            /* Enough is waiting to be played: rest until the listener has caught up. */
            while path.ahead(g) > aheadLimit {
                Thread.sleep(forTimeInterval: 0.05)
                if !path.isCurrent(g) { return }
            }
            do {
                piece = try decoder.next()
            } catch {
                fail(path, g, "decoding stopped: \(error)", at: startTime + Double(decoder.framesRead) / rate)
                return
            }
        }
        /* The band modes hold sound back while their network works: hand it on now, never
           letting playback run dry (short of two seconds, the original sound goes on). */
        while !over, let part = chain.drain(urgent: path.ahead(g) < Int64(2 * rate)) {
            if !path.isCurrent(g) { return }
            switch hand(part) {
            case .stop:
                return
            case .done:
                over = true
            case .more:
                break
            }
            while !over && path.ahead(g) > aheadLimit {
                Thread.sleep(forTimeInterval: 0.05)
                if !path.isCurrent(g) { return }
            }
        }
        if !over {
            if case .stop = hand(chain.finish()) { return }
        }
        if !started {
            if over {
                /* The run began after the song's faded part was over. */
                DispatchQueue.main.async { self.finished(path, g) }
            } else {
                fail(path, g, "the file holds no sound", at: position)
            }
            return
        }
        path.lock.lock()
        var done = false
        if path.generation == g {
            path.allScheduled = true
            if path.playedFrames >= path.scheduledFrames && !path.endReported {
                path.endReported = true
                done = true
            }
        }
        path.lock.unlock()
        if done { DispatchQueue.main.async { self.finished(path, g) } }
    }

    private static func buffer(_ pair: (left: [Float], right: [Float]), format: AVAudioFormat, from: Int = 0) -> AVAudioPCMBuffer? {
        let count = min(pair.left.count, pair.right.count) - from
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(count)
        pair.left.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { memcpy(channels[0], base + from, count * MemoryLayout<Float>.size) }
        }
        pair.right.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { memcpy(channels[1], base + from, count * MemoryLayout<Float>.size) }
        }
        return buffer
    }

    /// The same sound without its first `frames` frames.
    private static func tail(of buffer: AVAudioPCMBuffer, from frames: Int) -> AVAudioPCMBuffer? {
        let count = Int(buffer.frameLength) - frames
        guard count > 0, let source = buffer.floatChannelData,
              let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(count)),
              let target = out.floatChannelData else { return nil }
        out.frameLength = AVAudioFrameCount(count)
        for channel in 0..<Int(buffer.format.channelCount) {
            memcpy(target[channel], source[channel] + frames, count * MemoryLayout<Float>.size)
        }
        return out
    }

    /// Any queue. `frame` nil: after whatever the node already has (the ordinary case).
    /// Otherwise at exactly that frame of the node's timeline; what should already have been
    /// heard by now is cut off, so a late piece comes in late but in its right place, never
    /// shifted.
    ///
    /// A run that has been overtaken schedules nothing: a path's worker runs one run after the
    /// other, so by the time a newer run reaches `begin` (which empties the node), the older
    /// one has returned.
    private func schedule(_ path: SoundPath, _ buffer: AVAudioPCMBuffer, _ g: Int, at frame: Int64?) {
        var piece = buffer
        var when: AVAudioTime?
        var start: Int64 = 0
        if let frame = frame {
            start = frame
            var cut: Int64 = start < 0 ? -start : 0
            if path.node.isPlaying, let nodeTime = path.node.lastRenderTime, nodeTime.isSampleTimeValid,
               let playerTime = path.node.playerTime(forNodeTime: nodeTime) {
                /* a 30 ms margin: the audio system needs a moment to take a piece in */
                let earliest = playerTime.sampleTime + Int64(0.03 * buffer.format.sampleRate)
                if start + cut < earliest { cut = earliest - start }
            }
            if cut > 0 {
                guard let rest = SoundEngine.tail(of: buffer, from: Int(cut)) else { return }
                piece = rest
                start += cut
            }
            when = AVAudioTime(sampleTime: start, atRate: buffer.format.sampleRate)
        }
        let frames = Int64(piece.frameLength)
        path.lock.lock()
        let current = path.generation == g
        if current {
            path.scheduledFrames += frames
            path.scheduledEnd = frame == nil ? path.scheduledEnd + frames : max(path.scheduledEnd, start + frames)
        }
        path.lock.unlock()
        if !current { return }
        path.node.scheduleBuffer(piece, at: when, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.played(path, g, frames)
        }
    }

    /// Called by the audio system when a piece has been heard (also when a node is emptied;
    /// those calls carry an old generation and are ignored).
    private func played(_ path: SoundPath, _ g: Int, _ frames: Int64) {
        path.lock.lock()
        var done = false
        if path.generation == g {
            path.playedFrames += frames
            if path.allScheduled && path.playedFrames >= path.scheduledFrames && !path.endReported {
                path.endReported = true
                done = true
            }
        }
        path.lock.unlock()
        if done { DispatchQueue.main.async { self.finished(path, g) } }
    }

    /// Main queue, called by a run with its first piece: switch the node over to this run.
    private func begin(_ path: SoundPath, _ g: Int, format: AVAudioFormat, base: Double, stated: Double, first: AVAudioPCMBuffer) -> Bool {
        guard path.isCurrent(g) else { return false }
        connect(path, format)
        path.node.stop()
        path.base = base
        path.rate = format.sampleRate
        path.lastPosition = base
        path.statedDuration = stated
        path.restarting = false
        path.gainTimer?.invalidate()
        path.gainTimer = nil
        path.gain.globalGain = path.gainDb
        schedule(path, first, g, at: nil)
        if wantPlay {
            guard startEngine() else {
                failNow("audio engine did not start")
                return false
            }
            path.node.play()
        }
        if announce, path === current {
            announce = false
            onReady?(stated)
        }
        return true
    }

    private enum Anchor {
        case wait
        case go(Int64)   // start; the node's timeline begins this many frames into the run
        case stop
    }

    /// Main queue, called by the incoming song's run when its first piece is ready: tell its
    /// node when to start.
    ///
    /// Alignment: the outgoing node reports which of its frames it was playing at which
    /// moment of the audio clock. From that, the clock time at which the outgoing song
    /// reaches the point where the incoming one belongs is computed, and the incoming node is
    /// told to start its timeline at that clock time. Its pieces are then placed at exact
    /// frames of that timeline. If that moment is already past (the run was late), the
    /// timeline is started a little from now and begins correspondingly further into the song.
    private func beginIncoming(_ path: SoundPath, _ g: Int, plan: MixPlan, format: AVAudioFormat,
                               startTime: Double, stated: Double) -> Anchor {
        guard path.isCurrent(g), mix != nil, path === spare else { return .stop }
        let a = current
        guard wantPlay, engine.isRunning, !a.restarting, a.node.isPlaying,
              let nodeTime = a.node.lastRenderTime, nodeTime.isSampleTimeValid, nodeTime.isHostTimeValid,
              let playerTime = a.node.playerTime(forNodeTime: nodeTime) else { return .wait }
        let now = mach_absolute_time()
        /* A reading from before a pause is of no use. */
        let age = nodeTime.hostTime <= now ? AVAudioTime.seconds(forHostTime: now - nodeTime.hostTime) : 0
        if age > 0.5 { return .wait }

        let positionA = a.base + Double(playerTime.sampleTime) / a.rate
        /* Where the outgoing song is when the first frame of this run belongs. */
        let targetA = plan.startA + plan.bDelay + (startTime - plan.bOffset)
        var wait = (targetA - positionA) - age   // seconds from now
        var skip: Int64 = 0
        if wait < 0.1 {
            skip = Int64(((0.1 - wait) * format.sampleRate).rounded(.up))
            wait += Double(skip) / format.sampleRate
            Diag.shared.log(String(format: "mix: incoming song late, begins %.3f s further in", Double(skip) / format.sampleRate), song: path.songID)
        }
        connect(path, format)
        path.node.stop()
        path.base = startTime + Double(skip) / format.sampleRate
        path.rate = format.sampleRate
        path.lastPosition = path.base
        path.statedDuration = stated
        path.restarting = false
        path.gainTimer?.invalidate()
        path.gainTimer = nil
        path.gain.globalGain = path.gainDb
        path.node.play(at: AVAudioTime(hostTime: now + AVAudioTime.hostTime(forSeconds: wait)))
        path.anchored = true
        Diag.shared.log(String(format: "mix: incoming song starts in %.3f s (outgoing at %.3f)", wait, positionA), song: path.songID)
        return .go(skip)
    }

    /// Connects a path for a song's format (only when it differs from what the path has).
    private func connect(_ path: SoundPath, _ format: AVAudioFormat) {
        if path.connectedRate == format.sampleRate { return }
        path.node.stop()
        engine.connect(path.node, to: path.gain, format: format)
        engine.connect(path.gain, to: sum, format: format)
        path.connectedRate = format.sampleRate
        Diag.shared.log("engine: path \(path.name) connected for \(Int(format.sampleRate)) Hz")
    }

    private func startEngine() -> Bool {
        if engine.isRunning { return true }
        do {
            try engine.start()
            Diag.shared.log("engine: started")
            return true
        } catch {
            Diag.shared.log("engine: start failed: \(SongDecoder.describe(error))", error: true)
            return false
        }
    }

    /// A run has played its last piece.
    // MARK: peaks before the limiter

    private func measure(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let n = vDSP_Length(buffer.frameLength)
        var peak: Float = 0
        for c in 0..<Int(buffer.format.channelCount) {
            var m: Float = 0
            vDSP_maxmgv(data[c], 1, &m, n)
            peak = max(peak, m)
        }
        guard peak > SoundEngine.ceiling else { return }
        let over = 20 * log10(peak / SoundEngine.ceiling)
        peakLock.lock()
        overBlocks += 1
        songOver += 1
        worstOver = max(worstOver, over)
        songWorst = max(songWorst, over)
        peakLock.unlock()
    }

    private var modeName: String {
        guard let s = settings, s.surround else { return "off" }
        return s.mode.rawValue
    }

    /* Ten times a second: the headroom glides (at most 0.5 dB a second) towards what this
       song's peaks ask for; every 30 s a log line if the ceiling was crossed. */
    private func peakTick() {
        peakLock.lock()
        let worst = songWorst
        peakLock.unlock()
        if SoundEngine.autoHeadroom {
            if worst > 0 { cutTarget = min(SoundEngine.maxCut, max(cutTarget, worst + 0.3)) }
        } else {
            cutTarget = 0
        }
        if cutNow != cutTarget {
            cutNow = cutNow < cutTarget ? min(cutTarget, cutNow + 0.05) : max(cutTarget, cutNow - 0.05)
            sum.outputVolume = powf(10, -cutNow / 20)
        }
        peakTicks += 1
        if peakTicks >= 300 {
            peakTicks = 0
            peakLock.lock()
            let blocks = overBlocks, over = worstOver
            overBlocks = 0
            worstOver = 0
            peakLock.unlock()
            if blocks > 0 {
                Diag.shared.log(String(format: "engine: over ceiling %d blocks, worst +%.1f dB, mode %@, headroom -%.1f dB", blocks, over, modeName, cutNow))
            }
        }
    }

    /* At the end of a song: one line for it, and the next song starts without the cut (it
       glides back up). */
    private func peaksSongEnd() {
        peakLock.lock()
        let blocks = songOver, over = songWorst
        songOver = 0
        songWorst = 0
        peakLock.unlock()
        Diag.shared.log(String(format: "engine: song end: over ceiling %d blocks, worst +%.1f dB, mode %@, headroom -%.1f dB%@", blocks, over, modeName, cutNow, SoundEngine.autoHeadroom ? "" : " (auto headroom off)"))
        cutTarget = 0
    }

    private func finished(_ path: SoundPath, _ g: Int) {
        guard path.isCurrent(g) else { return }
        peaksSongEnd()
        path.lock.lock()
        let end = path.scheduledEnd
        path.lock.unlock()
        if !path.restarting { path.lastPosition = path.base + Double(end) / path.rate }
        path.restarting = false
        if path === current, let m = mix {
            /* The outgoing song has faded away: the incoming one takes its place. */
            if spare.anchored {
                unload(path)
                cur = 1 - cur
                completeMix(m)
                return
            }
            /* Should not happen (watchMix gives a mix up before its fade is heard): the
               incoming song is not there. Fall through to the ordinary end of a song. */
            dropMix(reason: "the next song was not there at the end of the overlap", restartCurrent: false)
        }
        guard path === current else { return }
        wantPlay = false
        path.node.stop()
        onEnded?()
    }

    /// Any queue.
    private func fail(_ path: SoundPath, _ g: Int, _ message: String, at position: Double) {
        DispatchQueue.main.async {
            guard path.isCurrent(g) else { return }
            if path === self.spare {
                /* The incoming song cannot be prepared: no mix; the current song is not cut short. */
                Diag.shared.log("mix: next song failed: \(message)", error: true, song: path.songID)
                if self.mix != nil {
                    self.dropMix(reason: "the next song could not be prepared: \(message)", restartCurrent: true)
                }
                return
            }
            path.lastPosition = position
            self.failNow(message)
        }
    }

    private func failNow(_ message: String) {
        let at = current.lastPosition
        let callback = onFailed
        stop()
        callback?(message, at)
    }

    /// The output changed (headphones, Bluetooth, CarPlay). The system has stopped the engine.
    private func configurationChanged() {
        Diag.shared.log("engine: output changed, running \(engine.isRunning)")
        guard current.file != nil else { return }
        needsReschedule = true
        /* Not at once: when headphones are pulled out the player is paused a moment later, and
           the song must not carry on through the phone's speaker in between. */
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, self.wantPlay, self.needsReschedule, self.current.file != nil else { return }
            self.needsReschedule = false
            if self.mix != nil {
                self.resumeMix()
            } else {
                self.restart(self.current, at: self.current.lastPosition, cutNow: true)
            }
        }
    }
}
