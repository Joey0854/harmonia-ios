import UIKit
import WebKit

/// Signing in to YouTube Music inside the app.
///
/// A plain WKWebView on Google's sign-in page; when it comes back to music.youtube.com the
/// cookies of that session are taken out of the web view's cookie store and kept by
/// `Account` (HttpOnly cookies included - that is where SAPISID lives, and the page cannot
/// see it, but the app can).
final class LoginViewController: UIViewController, WKNavigationDelegate {
    /// Called after the cookies were taken (on the main queue), whether or not the sign-in
    /// actually completed - `Account.isLoggedIn` says which.
    var onFinish: (() -> Void)?

    private var webView: WKWebView!
    private let bar = UIView()
    private let titleLabel = UILabel()
    private let doneButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var harvested = false

    private static let start = "https://accounts.google.com/ServiceLogin"
        + "?service=youtube&continue=https%3A%2F%2Fmusic.youtube.com%2F&hl=zh-TW"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        bar.backgroundColor = UIColor(white: 0.08, alpha: 1)
        view.addSubview(bar)

        titleLabel.text = "登入 YouTube Music"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        bar.addSubview(titleLabel)

        let cancel = UIButton(type: .system)
        cancel.setTitle("取消", for: .normal)
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        bar.addSubview(cancel)

        doneButton.setTitle("完成", for: .normal)
        doneButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        doneButton.isEnabled = false
        bar.addSubview(doneButton)

        spinner.color = .white
        bar.addSubview(spinner)

        let config = WKWebViewConfiguration()
        /* The default store is persistent, so the session survives a restart. */
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        /* Google refuses some sign-ins from web views that look unusual; this is the same
           string Safari sends. */
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        view.addSubview(webView)

        bar.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        cancel.translatesAutoresizingMaskIntoConstraints = false
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 48),

            cancel.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            cancel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            titleLabel.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            doneButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            doneButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            spinner.trailingAnchor.constraint(equalTo: doneButton.leadingAnchor, constant: -8),
            spinner.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            webView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        guard let url = URL(string: LoginViewController.start) else { return }
        webView.load(URLRequest(url: url))
    }

    // MARK: - buttons

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func doneTapped() {
        harvest()
    }

    // MARK: - navigation

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        spinner.stopAnimating()
        /* Back at YouTube Music: the sign-in is over (or was already done). */
        let host = webView.url?.host?.lowercased() ?? ""
        if host == "music.youtube.com" || host == "www.youtube.com" {
            doneButton.isEnabled = true
            doneButton.setTitle("完成", for: .normal)
        } else {
            doneButton.setTitle("完成", for: .normal)
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        spinner.startAnimating()
        doneButton.isEnabled = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        spinner.stopAnimating()
        doneButton.isEnabled = true
    }

    // MARK: - taking the cookies

    private func harvest() {
        guard !harvested else { return }
        harvested = true
        doneButton.isEnabled = false
        spinner.startAnimating()
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            let wanted = cookies.filter { cookie in
                let domain = cookie.domain.lowercased()
                return domain.contains("youtube.com") || domain.contains("google.com")
            }.map { cookie in
                Account.Cookie(name: cookie.name,
                               value: cookie.value,
                               domain: cookie.domain,
                               path: cookie.path.isEmpty ? "/" : cookie.path,
                               secure: cookie.isSecure,
                               expires: cookie.expiresDate?.timeIntervalSince1970)
            }
            Account.shared.store(wanted)
            DispatchQueue.main.async {
                guard let self = self else { return }
                let signedIn = Account.shared.isLoggedIn
                self.spinner.stopAnimating()
                self.dismiss(animated: true) {
                    self.onFinish?()
                    if !signedIn {
                        Diag.shared.log("account: login finished but not signed in", error: true)
                    }
                }
            }
        }
    }
}
