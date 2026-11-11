import UIKit
import WebKit

/*
 The page and the app talk through three channels.

 1. Page -> app, commands:  webkit.messageHandlers.ytm.postMessage({ cmd, ... })
      load      { url, startAt }                        play an address the player opens itself
      loadSong  { id, url, headers, startAt, size, duration?, mime?, local? }
                                                        download with these headers, then play the file;
                                                        url may be "" when local is true
      play | pause
      seek      { t }
      meta      { title, artist, artwork, duration }    what the lock screen shows
      dur       { d }                                   the real length of the current song
      queue     { items: [{ id, url, title, artist, artwork, duration, headers?, size?, mime?, local? }] }
                                                        songs to continue with while the page sleeps
      dl        { id, url, headers?, size?, mime? }     keep a song on the phone
      dlDelete  { id }
      dlList    {}
      fx        { key, surround, irL, irR, makeup }     sound setting: irL / irR are base64 WAV files
                                                        (2 channels: left ear, right ear) for the left /
                                                        right input, null when surround is false; makeup
                                                        is a plain factor (1 = unchanged). A repeat of
                                                        the same key is ignored. Remembered over restarts.
                                                        Optional mode: "stage" (no impulse responses;
                                                        stage { width, depth, vocal }, each 0..100) or
                                                        "hrir" (the default).
      eq        { gains: [5 numbers, dB] }              150 / 400 / 1500 / 5000 / 10000 Hz
      normTarget { on, target }                         loudness balancing towards `target` LUFS
      diag      {}                                      answered with a `diag` event
      config    { pc }                                  where the PC is ("http://host:port"); remembered
      mix       { on }                                  automatic mixing between songs; remembered
      carProbe  { action, ... }                         "measure this car" and remote car presets; see
                                                        App/CarProbe.swift (answered with carProbe /
                                                        carPreset events)
      mixInfo   { id, mix }                             what the PC found out about a song, when it comes
                                                        later than the song; loadSong and queue items may
                                                        carry the same object as `mix`:
                                                        { bpm, beat0, conf, dur, soundStart, introStart,
                                                          bodyStart, bodyEnd, outroStart, quietStart, tailEnd }

 2. Page -> app, HTTP without CORS:  await webkit.messageHandlers.ytmHttp.postMessage({...})
      see HttpBridge.swift

 3. App -> page, events:  window.__ytmNativeEvent(event)
      { type: "ready", dur }                      the song can play; dur as the file reports it
      { type: "time", t, dur, playing }           about four times a second
      { type: "state", playing }
      { type: "seeked" }
      { type: "ended" }                           the song is over and the app has no next one
      { type: "advanced", id }                    the app moved on to this queued song by itself
      { type: "remote", action: "next"|"prev" }   lock-screen button the app could not handle alone
      { type: "progress", id, received, total }   loadSong (or a queued song being waited for) is
                                                  downloading; at most every 250 ms; total 0 = unknown
      { type: "error", message }                  playback failed
      { type: "error", id, message }              this song cannot be played: its download failed
                                                  (HTTP 403/404/410 at once,
                                                  anything else after two retries), or it was said
                                                  to be stored but the file is missing
      { type: "prefetchError", id, message }      the download in advance of a queued song failed;
                                                  nothing audible changed
      { type: "dl", id, state: "progress", got, total }
      { type: "dl", id, state: "done", size }
      { type: "dl", id, state: "error" }
      { type: "dlList", items: [{ id, size }] }
      { type: "lufs", id, lufs }                  the loudness of this song has been measured
      { type: "fxUnavailable", id, message }      this song plays without the sound settings (the
                                                  engine could not handle it); music carries on
      { type: "diag", text }                      the last 80 lines of the app's own log
      { type: "mix", stage, from, to, overlap, synced, reason? }
                                                  stage "start": the next song (`to`) begins to come
                                                  in over the current one (`from`); "done": it has
                                                  taken over (an `advanced` event follows at once);
                                                  "cancel": the mix was given up, with the reason.
                                                  During the overlap `time` still reports `from`.

    An `error` always carries the `id` of its song when the app knows it; the page retries the
    current song once and treats any other id as a failed download ahead.
    Every `message` says what happened in the system's own words where there are any, e.g.
    "download failed at 0-1048575: NSURLErrorDomain -1001 The request timed out.",
    "download http 502 at 0-1048575: {"error":"..."}" (the page retries network trouble once and
    does not retry a 4xx),
    "stored file is missing" (exactly this text; the page looks for it),
    "player failed: <domain> <code> <text> [file]".
    The app's own log (Diag.swift) also goes to <pc>/api/debug when the PC is reachable, where
    <pc> is the address from the last `config` command (ServerURL in Info.plist until then).
 */

/// Shows the bundled player page and connects it to the system audio player.
final class PlayerViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate, UIGestureRecognizerDelegate {
    private var webView: WKWebView!
    private let player = NativePlayer()
    /* the page was loaded again after its process ended; the last band status sent to it */
    private var pageReloaded = false
    private var reloadScriptAdded = false
    private var lastBandEvent: [String: Any]?
    private var lastBandState: String { return lastBandEvent?["state"] as? String ?? "none" }
    /// Only for relative addresses in `load`/`dl` and as the optional debug-log target; the
    /// page itself no longer comes from here.
    private var baseURL = URL(string: "http://127.0.0.1:8787")!
    private let messageLabel = UILabel()
    private let retryButton = UIButton(type: .system)

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        if let s = Bundle.main.object(forInfoDictionaryKey: "ServerURL") as? String, let u = URL(string: s) {
            baseURL = u
        }
        /* The address the user set in the page's settings (see the `config` command) wins. */
        if let saved = UserDefaults.standard.string(forKey: Diag.pcKey), let u = PlayerViewController.pcBase(saved) {
            baseURL = u
        }
        /* Only the fallback for songs the app's own yt-dlp cannot look up. */
        Ytdl.shared.pcBase = baseURL

        /* Signing in or out changes what the page asks for, so it is told as soon as it
           happens (the login screen runs on top of this one). */
        NotificationCenter.default.addObserver(forName: Account.changed, object: nil, queue: .main) { [weak self] _ in
            self?.accountChanged()
        }

        /* The page plays no sound itself (it has no media element): nothing about media needs
           setting on the web view. All sound is NativePlayer's. */
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(WebBundle(), forURLScheme: AppScheme.name)
        let content = WKUserContentController()
        /* The content controller keeps its handlers alive, and this one is `self`. That loop is
           harmless: this is the root screen and lives as long as the app. */
        content.add(self, name: "ytm")
        content.addScriptMessageHandler(HttpBridge(), contentWorld: .page, name: "ytmHttp")
        content.addScriptMessageHandler(AccountBridge(), contentWorld: .page, name: "ytmAccount")
        /* Tells the page where it runs, before any of its own code runs. `__ytmYtdlp` says the
           app can find songs by itself (yt-dlp inside the app); `__ytmAccount` says the user
           signed in, so the page's own youtubei calls come back personal. */
        let ytdlp = PythonRuntime.bundled ? "true" : "false"
        let account = Account.shared.isLoggedIn ? "true" : "false"
        let version = "\(Diag.version) (\(Diag.build))".filter { $0 != "\"" && $0 != "\\" }
        // a build without the separation model (a release) hides the band modes
        let bandModel = Bundle.main.bundleURL.appendingPathComponent("BandModel/HTDemucsBody.mlmodelc")
        let noBand = FileManager.default.fileExists(atPath: bandModel.path) ? "false" : "true"
        content.addUserScript(WKUserScript(source: "window.__ytmNative = true; window.__ytmStandalone = true; window.__ytmYtdlp = \(ytdlp); window.__ytmAccount = \(account); window.__ytmAppVersion = \"\(version)\"; window.__ytmNoBand = \(noBand);",
                                           injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = content

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        webView.navigationDelegate = self
        view.addSubview(webView)

        messageLabel.textColor = .white
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center
        messageLabel.font = .systemFont(ofSize: 16)
        messageLabel.isHidden = true
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(messageLabel)

        retryButton.setTitle("重試", for: .normal)
        retryButton.titleLabel?.font = .boldSystemFont(ofSize: 18)
        retryButton.isHidden = true
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.addTarget(self, action: #selector(loadPage), for: .touchUpInside)
        view.addSubview(retryButton)

        NSLayoutConstraint.activate([
            messageLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -30),
            messageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            retryButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            retryButton.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 20),
            retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            retryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 88)
        ])

        /* A way to read the app's own log on the phone that needs neither the page nor the PC:
           tap three times with two fingers. */
        /* Developer mode only (1.3.23): the page's settings turn it on, see the "devMode" command. */
        let tap = UITapGestureRecognizer(target: self, action: #selector(showLog))
        tap.numberOfTapsRequired = 3
        tap.numberOfTouchesRequired = 2
        tap.delegate = self
        view.addGestureRecognizer(tap)

        player.onEvent = { [weak self] event in self?.send(event) }
        /* What the band modes are doing, for the page's status line. */
        SurroundChain.status = { [weak self] status in
            var event: [String: Any] = ["type": "band"]
            switch status {
            case .off: event["state"] = "off"
            case .loading: event["state"] = "loading"
            case .running(let seconds, let realtime):
                event["state"] = "running"
                event["seconds"] = (seconds * 100).rounded() / 100
                event["realtime"] = (realtime * 100).rounded() / 100
            case .late: event["state"] = "late"
            case .failed(let message):
                event["state"] = "failed"
                event["message"] = String(message.prefix(160))
            case .paused(let why):
                event["state"] = "paused"
                event["message"] = why
            }
            DispatchQueue.main.async {
                self?.lastBandEvent = event
                self?.send(event)
            }
        }
        /* The stored sign-in stopped working: the page asks the user to sign in again. Checked
           once a few seconds after start, and whenever an account request notices it. */
        Account.shared.onExpired = { [weak self] in self?.send(["type": "accountExpired"]) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { Account.shared.verifySession() }
        /* A song counts as played: kept for the page (it may not be running), and sent to the
           signed-in account's history. */
        player.onListened = { [weak self] id, title, artist, artwork, duration in
            let entry: [String: Any] = [
                "videoId": id, "title": title, "artist": artist, "thumb": artwork,
                "duration": duration, "playedAt": (Date().timeIntervalSince1970 * 1000).rounded(),
            ]
            PlayHistory.shared.add(entry)
            Diag.shared.log("history: counted \(title.prefix(30))", song: id)
            Account.shared.recordPlay(id)
            self?.send(["type": "history"])
        }
        Downloads.shared.onEvent = { [weak self] event in self?.send(event) }
        LightMusic.shared.onEvent = { [weak self] event in self?.send(event) }
        /* "Measure this car" and the remote car presets (App/CarProbe.swift). */
        CarMeasure.shared.onEvent = { [weak self] event in self?.send(event) }
        CarMeasure.shared.pauseMusic = { [weak self] in self?.player.pause(reason: "car measurement") }
        CarMeasure.shared.start()
        /* Only does anything when the user left the music light on. */
        LightMusic.shared.restoreAtLaunch()
        loadPage()
    }

    /* The web view has gesture recognisers of its own; ours must be allowed alongside them. */
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        return true
    }

    /// Developer mode (seven taps on the version in the page's settings): the test items show, and
    /// the two-finger log gesture works. Off for everyone else.
    static let devModeKey = "ytm.devMode"

    @objc private func showLog() {
        if !UserDefaults.standard.bool(forKey: PlayerViewController.devModeKey) { return }
        if presentedViewController != nil { return }
        present(UINavigationController(rootViewController: LogViewController()), animated: true)
    }

    @objc private func loadPage() {
        messageLabel.isHidden = true
        retryButton.isHidden = true
        webView.isHidden = false
        webView.load(URLRequest(url: AppScheme.home))
    }

    /// Only reached when the page inside the app itself cannot be shown (a broken build).
    private func showFailure(_ error: Error) {
        let code = (error as NSError).code
        if code == NSURLErrorCancelled { return }
        webView.isHidden = true
        messageLabel.text = "無法載入內建的播放器頁面\n\n\(error.localizedDescription)"
        messageLabel.isHidden = false
        retryButton.isHidden = false
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showFailure(error)
    }

    /* The top frame holds the bridges, so it must never leave the bundled page. A link to a
       web site that the user taps opens in Safari instead. */
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        let scheme = url?.scheme?.lowercased() ?? ""
        if scheme == AppScheme.name || scheme == "about" || navigationAction.targetFrame?.isMainFrame == false {
            decisionHandler(.allow)
            return
        }
        if navigationAction.navigationType == .linkActivated, let url = url, scheme == "http" || scheme == "https" {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
        decisionHandler(.cancel)
    }

    /* iOS can end the page's process to free memory while music keeps playing in the
       background. Without this the user would come back to a blank screen. */
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Diag.shared.log("page: the web view's process was ended by the system; the page is loaded again (app footprint \(PerfMonitor.mb(PerfMonitor.footprint())) MB, available \(PerfMonitor.mb(PerfMonitor.available())) MB, band \(lastBandState), model \(BandModel.shared.label))", error: true)
        pageReloaded = true
        /* the band's GPU segments are what pushes iOS to end the page again: CPU from now on */
        BandModel.shared.easeMemory("the page's process was ended")
        /* The page is told it is a reload, so that it can open the player again and follow the
           music that is still playing (added once: it stays for every later load). */
        if !reloadScriptAdded {
            reloadScriptAdded = true
            let tell = WKUserScript(source: "window.__ytmReloaded = true;", injectionTime: .atDocumentStart, forMainFrameOnly: true)
            webView.configuration.userContentController.addUserScript(tell)
        }
        loadPage()
    }

    /* After a reload the page knows nothing of what is playing: tell it everything once it is
       up (song, position, length, playing or not, band state), paused or not. */
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard pageReloaded else { return }
        pageReloaded = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self = self else { return }
            self.player.resync()
            if let band = self.lastBandEvent { self.send(band) }
            Diag.shared.log("page: state sent again after the reload")
        }
    }

    // MARK: page -> app

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard AppScheme.owns(message.frameInfo) else { return }
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
        logCommand(cmd, body)
        switch cmd {
        case "config":
            /* Where the PC is. Used for the app's own log and for addresses given without a host. */
            guard let text = body["pc"] as? String, let base = PlayerViewController.pcBase(text) else {
                Diag.shared.log("cmd config: address not usable", error: true)
                return
            }
            if base != baseURL {
                baseURL = base
                Ytdl.shared.pcBase = base
                UserDefaults.standard.set(base.absoluteString, forKey: Diag.pcKey)
                Diag.shared.setServer(base)
                Diag.shared.log("cmd config: PC is \(base.absoluteString)")
            }
        case "load":
            guard let address = body["url"] as? String, let url = playable(address) else { return }
            player.noteChosenByPage()
            player.load(url: url, startAt: number(body["startAt"]))
        case "loadSong":
            guard let id = body["id"] as? String else { return }
            guard StreamCache.isSafe(id: id) else {
                send(["type": "error", "id": id, "message": "bad loadSong"])
                return
            }
            /* The address is empty for a song the page only knows as stored on the phone
               (`local: true`). The stored file is preferred in every case, so `local` itself
               needs no handling; `mime` is not needed either, the player reads the file. */
            let address = body["url"] as? String ?? ""
            if !address.isEmpty && remote(address) == nil {
                send(["type": "error", "id": id, "message": "address not understood (\(address.count) characters, starts \(address.prefix(24)))"])
                return
            }
            if let info = body["mix"] as? [String: Any] { player.setMixInfo(MixAnalysis(info), of: id) }
            player.noteChosenByPage()
            player.loadSong(id: id, url: remote(address), headers: strings(body["headers"]),
                            size: integer(body["size"]), startAt: number(body["startAt"]),
                            duration: number(body["duration"]))
        case "play":
            player.play()
        case "pause":
            player.pause()
        case "seek":
            player.seek(to: number(body["t"]))
        case "meta":
            player.setMeta(title: body["title"] as? String ?? "",
                           artist: body["artist"] as? String ?? "",
                           artwork: body["artwork"] as? String ?? "",
                           duration: number(body["duration"]),
                           id: body["id"] as? String)
        case "dur":
            player.setDuration(number(body["d"]), id: body["id"] as? String)
        case "queue":
            let items = body["items"] as? [[String: Any]] ?? []
            var tracks: [Track] = []
            for item in items {
                guard let id = item["id"] as? String else { break }
                let address = item["url"] as? String ?? ""
                /* A stored song plays from its file (its address may be empty). Otherwise: with
                   headers the app downloads the song; without, the player opens the address
                   itself as before. */
                var headers: [String: String]? = nil
                var found: URL? = Downloads.shared.localURL(id)
                if found == nil {
                    if item["headers"] is [String: Any] {
                        headers = strings(item["headers"])
                        found = StreamCache.isSafe(id: id) ? remote(address) : nil
                    } else {
                        found = playable(address)
                    }
                }
                /* Stop at a song that cannot be started: skipping it would play out of order. */
                guard let url = found else { break }
                tracks.append(Track(id: id, url: url,
                                    title: item["title"] as? String ?? "",
                                    artist: item["artist"] as? String ?? "",
                                    artwork: item["artwork"] as? String ?? "",
                                    duration: number(item["duration"]),
                                    headers: headers,
                                    size: integer(item["size"]),
                                    mix: (item["mix"] as? [String: Any]).map { MixAnalysis($0) }))
            }
            /* The page sends the same queue several times in a row when a song starts. Only a
               queue that differs from the last one is taken (and gets a line in the log). */
            let key = tracks.map { "\($0.id) \($0.url.absoluteString) \($0.headers == nil ? 0 : 1) \($0.mix == nil ? 0 : 1)" }.joined(separator: "|")
            if player.setQueue(tracks, key: key) {
                let ids = tracks.map { $0.id }.joined(separator: ",")
                Diag.shared.log("cmd queue: \(tracks.count) [\(ids)]")
            }
        case "dl":
            guard let id = body["id"] as? String, let address = body["url"] as? String, let url = resolve(address) else { return }
            if body["headers"] is [String: Any] {
                Downloads.shared.start(id: id, url: url, headers: strings(body["headers"]), size: integer(body["size"]))
            } else {
                Downloads.shared.start(id: id, url: url)
            }
        case "dlDelete":
            if let id = body["id"] as? String { Downloads.shared.remove(id: id) }
        case "dlList":
            send(["type": "dlList", "items": Downloads.shared.list()])
        case "bandMix":
            let mix = NativePlayer.bandMix(from: body)
            BandMix.shared.set(mix)
            let text = mix.parts.enumerated().map { i, p -> String in
                let pct = Int((p.gain * 100).rounded())
                return "\(Demucs.sources[i]) \(pct)%" + (p.solo ? " S" : "") + (p.mute ? " M" : "")
            }.joined(separator: ", ")
            var carText = ""
            if let c = mix.car {
                carText = ", car: " + c.tracks.enumerated().map { i, t in
                    String(format: "%@ pan %.1f width %.1f send %@%@", Demucs.sources[i], t.panDb, t.width,
                           t.sendDb <= CarBandParams.sendOff ? "off" : String(format: "%.1f", t.sendDb), t.rear ? " rear" : " front")
                }.joined(separator: ", ")
                carText += String(format: "; reverb %@ %.1f dB RT60 %.2f s pre %.0f ms %.0f-%.0f Hz hf %.2f low %@ %.0f Hz reverbStyle %@ sendGate %.2f dryGate %@; early %@ %.1f dB %.0f-%.0f ms; xover %.0f Hz",
                                  c.ambienceOn ? "on" : "off", c.ambienceDb, c.rt60, c.predelayMs, c.lowHz, c.highHz, c.hfDamping,
                                  c.lowReverbFront ? "front" : "cut", c.lowSplitHz, c.reverbStyle.rawValue, c.sendGate,
                                  c.dryGate ? "on" : "off", c.earlyOn ? "on" : "off", c.earlyDb,
                                  c.earlyMinMs, c.earlyMaxMs, c.crossoverHz)
            }
            Diag.shared.log("band: mixer " + text + (mix.irs != nil ? ", new responses" : "") + carText)
        case "fx":
            player.setEffect(NativePlayer.effect(from: body), message: body)
            Diag.shared.setSetting("mode", (body["surround"] as? Bool ?? false) ? (body["mode"] as? String ?? "hrir") : "off")
        case "eq":
            let gains = (body["gains"] as? [Any] ?? []).map { Float(number($0)) }
            if gains.count == 5 { player.setEQ(gains) }
            Diag.shared.setSetting("eq", gains.map { Double($0) })
        case "normTarget":
            let target = body["target"] == nil ? -9 : number(body["target"])
            player.setLoudness(on: body["on"] as? Bool ?? false, target: target)
            Diag.shared.setSetting("loudness", ["on": body["on"] as? Bool ?? false, "target": target])
        case "pageInfo":
            if let profile = body["profile"] as? String { Diag.shared.setSetting("profile", String(profile.prefix(20))) }
            if let full = body["full"] as? Bool {
                PerfMonitor.shared.setFullPlayer(full)
                Diag.shared.setSetting("fullPlayer", full)
            }
        case "headroom":
            /* the automatic headroom before the limiter (on unless turned off) */
            if let on = body["on"] as? Bool {
                SoundEngine.autoHeadroom = on
                Diag.shared.log("engine: automatic headroom \(on ? "on" : "off")")
            }
            send(["type": "headroom", "on": SoundEngine.autoHeadroom])
        case "report":
            /* the report receiver: get / set its address, test it, send a report now */
            let action = body["action"] as? String ?? "get"
            func answer(_ problem: String?, _ extra: [String: Any] = [:]) {
                var event: [String: Any] = ["type": "report", "action": action, "ok": problem == nil,
                                            "base": Diag.shared.reportAddress, "message": problem ?? ""]
                for (k, v) in extra { event[k] = v }
                DispatchQueue.main.async { self.send(event) }
            }
            switch action {
            case "set":
                if Diag.shared.setReportBase(body["base"] as? String ?? "") == nil {
                    answer("位址要是 http:// 或 https:// 開頭，並且有主機名稱")
                } else {
                    answer(nil)
                }
            case "ping":
                Diag.shared.ping(body["base"] as? String ?? Diag.shared.reportAddress) { answer($0) }
            case "send":
                Diag.shared.sendReport(trigger: "manual") { answer($0) }
            default:
                answer(nil)
            }
        case "diag":
            send(["type": "diag", "text": Diag.shared.tail(80)])
        case "studentTest":
            /* the student model stress test (App/StudentStress.swift): start A / B, stop, status */
            let action = body["action"] as? String ?? "status"
            let update: ([String: Any]) -> Void = { [weak self] info in
                var e = info
                e["type"] = "studentTest"
                DispatchQueue.main.async { self?.send(e) }
            }
            switch action {
            case "start":
                let kind = (body["kind"] as? String) == "B" ? "B" : "A"
                Diag.shared.log("cmd studentTest start \(kind)")
                if let problem = StudentStress.shared.start(kind: kind, file: player.currentFile, onUpdate: update) {
                    update(["state": "refused", "error": problem])
                } else {
                    update(["state": "starting", "kind": kind])
                }
            case "stop":
                Diag.shared.log("cmd studentTest stop")
                StudentStress.shared.stop()
                update(StudentStress.shared.summary())
            default:
                var info = StudentStress.shared.summary()
                info["available"] = ["A": StudentModel.available("A"), "B": StudentModel.available("B")]
                update(info)
            }
        case "login":
            /* The Google sign-in page, in-app; its cookies are kept by Account. */
            if presentedViewController != nil { return }
            Diag.shared.log("cmd login")
            let screen = LoginViewController()
            screen.modalPresentationStyle = .fullScreen
            present(screen, animated: true)
        case "logout":
            Diag.shared.log("cmd logout")
            Account.shared.store([])
        case "ytdlDiag":
            /* Versions and a one-shot challenge-solver test, for the settings screen. */
            DispatchQueue.global(qos: .userInitiated).async {
                let versions = PythonBridge.shared.versions()
                let probe = PythonBridge.shared.selftest()
                let lines = Diag.shared.tail(40) + "\n--- python ---\n" + versions + "\n--- js solver ---\n" + probe
                DispatchQueue.main.async { self.send(["type": "ytdlDiag", "text": lines]) }
            }
        case "light":
            /* The music light. Bluetooth is only started once it is switched on. */
            LightMusic.shared.apply(message: body)
        case "lightArt":
            /* A song's cover, for its light colour (used only while the music light is on). */
            if let id = body["id"] as? String, let url = body["url"] as? String {
                LightMusic.shared.art(id: id, url: url)
            }
        case "mix":
            player.setMix(on: body["on"] as? Bool ?? false)
        case "carProbe":
            CarMeasure.shared.handle(body)
        case "route":
            /* the page asks what the output is (once when it starts; changes come by themselves) */
            send(player.routeEvent())
        case "devMode":
            let on = body["on"] as? Bool ?? false
            if UserDefaults.standard.bool(forKey: PlayerViewController.devModeKey) != on {
                UserDefaults.standard.set(on, forKey: PlayerViewController.devModeKey)
                Diag.shared.log("developer mode \(on ? "on" : "off")")
            }
        case "mixInfo":
            if let id = body["id"] as? String, let info = body["mix"] as? [String: Any] {
                player.setMixInfo(MixAnalysis(info), of: id)
            }
        default:
            break
        }
    }

    /// A number from the page; also accepts it written as text ("3456789").
    private func number(_ value: Any?) -> Double {
        if let n = value as? NSNumber, n.doubleValue.isFinite { return n.doubleValue }
        if let s = value as? String, let n = Double(s), n.isFinite { return n }
        return 0
    }

    /// One line in the log per command, without the bulky parts.
    private func logCommand(_ cmd: String, _ body: [String: Any]) {
        let id = body["id"] as? String ?? "-"
        switch cmd {
        case "loadSong", "dl":
            let address = body["url"] as? String ?? ""
            let host = URL(string: address)?.host ?? (address.isEmpty ? "(no address)" : "(unparsed)")
            let names = strings(body["headers"]).keys.sorted().joined(separator: ",")
            let size = body["size"].map { "\($0)" } ?? "-"
            let local = body["local"].map { "\($0)" } ?? "-"
            Diag.shared.log("cmd \(cmd): \(host), \(address.count) chars, size \(size), headers [\(names)], startAt \(number(body["startAt"])), duration \(number(body["duration"])), local \(local)", song: id)
        case "load":
            Diag.shared.log("cmd load: \((body["url"] as? String ?? "").prefix(80))")
        case "fx":
            let left = (body["irL"] as? String)?.count ?? 0
            let right = (body["irR"] as? String)?.count ?? 0
            let key = body["key"] as? String ?? ""
            let surround = body["surround"].map { "\($0)" } ?? "-"
            let mode = body["mode"] as? String ?? "hrir"
            Diag.shared.log("cmd fx: key \(key), surround \(surround), mode \(mode), irL \(left) chars, irR \(right) chars, makeup \(number(body["makeup"]))")
        case "eq", "normTarget", "play", "pause", "seek", "mix":
            var rest = body
            rest["cmd"] = nil
            Diag.shared.log("cmd \(cmd) \(rest)")
        default:
            break   // meta, dur, dlList, dlDelete, diag: not worth a line; queue and config log themselves
        }
    }

    private func integer(_ value: Any?) -> Int64 {
        return Int64(max(0, min(number(value), 1e15)))
    }

    /// Request headers as the page gave them; anything that is not text is left out.
    private func strings(_ value: Any?) -> [String: String] {
        var out: [String: String] = [:]
        for (name, text) in value as? [String: Any] ?? [:] {
            if let text = text as? String { out[name] = text }
        }
        return out
    }

    /// Where to play a song from: its stored file when there is one, otherwise the PC.
    private func playable(_ address: String) -> URL? {
        if let r = address.range(of: "/media/[A-Za-z0-9_-]{11}.m4a", options: .regularExpression) {
            let id = String(address[r].dropFirst(7).prefix(11))
            if let local = Downloads.shared.localURL(id) { return local }
        }
        return resolve(address)
    }

    private func resolve(_ address: String) -> URL? {
        return URL(string: address, relativeTo: baseURL)?.absoluteURL
    }

    /// The PC's address as the page gives it: http or https, a host, nothing after it.
    static func pcBase(_ text: String) -> URL? {
        guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parts.host, !host.isEmpty,
              parts.path.isEmpty || parts.path == "/",
              parts.query == nil, parts.fragment == nil, parts.user == nil, parts.password == nil else { return nil }
        var clean = URLComponents()
        clean.scheme = scheme
        clean.host = host
        clean.port = parts.port
        return clean.url
    }

    /// An absolute web address, or nil. `ytdl://<id>` is also accepted: the app looks the real
    /// address up itself (Ytdl.swift).
    private func remote(_ address: String) -> URL? {
        var parsed = URL(string: address)
        if parsed == nil {
            /* Before iOS 17 a single character that should have been escaped makes the whole
               address unreadable. Escape what is not allowed and try again. */
            let allowed = CharacterSet(charactersIn: "!$&'()*+,-./0123456789:;=?@ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz~%#[]")
            parsed = address.addingPercentEncoding(withAllowedCharacters: allowed).flatMap { URL(string: $0) }
        }
        guard let url = parsed, let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == Ytdl.scheme {
            return Ytdl.videoID(from: url) == nil ? nil : url
        }
        guard scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    // MARK: app -> page

    /// Main queue only (WebKit). Every caller already runs there.
    private func send(_ event: [String: Any]) {
        if let type = event["type"] as? String, type == "advanced" || type == "ended" { Diag.shared.songEnded() }
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let json = String(data: data, encoding: .utf8) else { return }
        let type = event["type"] as? String ?? ""
        /* Everything the page is told goes into the log, except the steady stream of small
           updates and the log itself. */
        let steady = type == "time" || type == "progress" || type == "diag" || type == "dlList"
            || (type == "dl" && (event["state"] as? String) == "progress")
        if !steady {
            let bad = type == "error" || type == "prefetchError" || type == "fxUnavailable"
            Diag.shared.log("event \(json.prefix(400))", error: bad, song: event["id"] as? String ?? "-")
        }
        webView.evaluateJavaScript("window.__ytmNativeEvent && window.__ytmNativeEvent(\(json));", completionHandler: nil)
    }

    /// Signing in or out: the page is told, and yt-dlp gets (or loses) the cookie file.
    private func accountChanged() {
        let on = Account.shared.isLoggedIn
        Diag.shared.log("account: \(on ? "signed in" : "signed out")")
        let script = "window.__ytmAccount = \(on); window.__ytmAccountChanged && window.__ytmAccountChanged(\(on));"
        webView.evaluateJavaScript(script, completionHandler: nil)
        let path = on ? Account.shared.ytDlpCookieFile.path : ""
        DispatchQueue.global(qos: .utility).async {
            PythonBridge.shared.setCookies(path)
        }
    }
}

/// Shows the app's own log (see Diag.swift), newest lines at the bottom, with a Copy button.
final class LogViewController: UIViewController {
    private let textView = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Log"
        view.backgroundColor = .black
        textView.frame = view.bounds
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        textView.isEditable = false
        textView.backgroundColor = .black
        textView.textColor = .white
        textView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        textView.text = Diag.shared.tail(300)
        view.addSubview(textView)
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Close", style: .plain, target: self, action: #selector(close))
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "Share", style: .plain, target: self, action: #selector(shareAll)),
            UIBarButtonItem(title: "Copy", style: .plain, target: self, action: #selector(copyAll)),
        ]
    }

    /// Sends the log somewhere (Messages, Mail, a file, a GitHub issue) when asking for help.
    @objc private func shareAll() {
        let sheet = UIActivityViewController(activityItems: [textView.text ?? ""], applicationActivities: nil)
        sheet.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItems?.first
        present(sheet, animated: true)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let end = (textView.text as NSString).length
        if end > 0 { textView.scrollRangeToVisible(NSRange(location: end - 1, length: 1)) }
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    @objc private func copyAll() {
        UIPasteboard.general.string = textView.text
    }
}
