import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        /* A report of the previous run if it ended in front (crash, or killed by the system). */
        if Diag.shared.noteStart() {
            Diag.shared.log("diag: the last run ended while the app was in front")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { Diag.shared.sendReport(trigger: "lastRunEnded") }
        }
        /* The band surround modes: the separation model (loaded the first time it is used). */
        SurroundChain.bandNetwork = { BandModel.shared.network() }
        SurroundChain.log = { Diag.shared.log($0) }
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.backgroundColor = .black
        w.rootViewController = PlayerViewController()
        w.makeKeyAndVisible()
        window = w
        /* Started at once: loading yt-dlp takes a moment and the first song should not wait
           for it. It runs on its own queue. */
        PythonBridge.shared.onReady = { ok, message in
            guard ok else { return }
            /* Already signed in from a previous run: yt-dlp should use those cookies. */
            if Account.shared.isLoggedIn {
                let path = Account.shared.ytDlpCookieFile.path
                DispatchQueue.global(qos: .utility).async {
                    PythonBridge.shared.setCookies(path)
                }
            }
            /* One silent check of the JavaScriptCore side, so the log says whether songs can be
               looked up on this phone before the first song is played. */
            DispatchQueue.global(qos: .utility).async {
                let probe = PythonBridge.shared.selftest()
                Diag.shared.log("python selftest: \(probe)")
            }
        }
        PythonBridge.shared.start()
        return true
    }

    /* Going to the background: noted (see above) and reported; the report gets a little time
       to go out before the app is suspended. */
    func applicationDidEnterBackground(_ application: UIApplication) {
        Diag.shared.noteBackground(true)
        guard !Diag.shared.reportAddress.isEmpty else { return }
        var task = UIBackgroundTaskIdentifier.invalid
        task = application.beginBackgroundTask(withName: "report") {
            application.endBackgroundTask(task)
            task = .invalid
        }
        Diag.shared.sendReport(trigger: "background") { _ in
            DispatchQueue.main.async {
                if task != .invalid { application.endBackgroundTask(task); task = .invalid }
            }
        }
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        Diag.shared.noteBackground(false)
    }

    func applicationWillTerminate(_ application: UIApplication) {
        Diag.shared.noteBackground(true)
        /* Give the car's light its own colour back (best effort: the app is ending). */
        LightMusic.shared.appWillTerminate()
    }
}
