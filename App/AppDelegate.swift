import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
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

    func applicationWillTerminate(_ application: UIApplication) {
        /* Give the car's light its own colour back (best effort: the app is ending). */
        LightMusic.shared.appWillTerminate()
    }
}
