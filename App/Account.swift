import Foundation
import WebKit
import CommonCrypto

/// `Result` needs an `Error`, and everything in this file already produces the message as a
/// string - so a failure is just that text, and `"..."` works as one.
struct AccountFailure: Error, ExpressibleByStringInterpolation, CustomStringConvertible {
    let text: String

    init(_ text: String) { self.text = text }
    init(stringLiteral value: String) { text = value }
    init(stringInterpolation: StringInterpolation) { text = stringInterpolation.text }
    var description: String { text }

    struct StringInterpolation: StringInterpolationProtocol {
        var text = ""
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ literal: String) { text += literal }
        mutating func appendInterpolation<T>(_ value: T) { text += String(describing: value) }
    }
}

/// The user's YouTube Music account, as the app sees it: the cookies the login page left
/// behind, and the requests that need them.
///
/// Two users of the same cookies:
///  - yt-dlp, through a Netscape cookie file (so restricted songs can be played);
///  - the page's own `youtubei` calls, which go through HttpBridge. They are stamped here with
///    the cookies and with `Authorization: SAPISIDHASH …`, which is what makes the answers
///    personal (home, library, search) instead of anonymous.
///
/// Safe to call from any queue: everything that matters runs on `queue`.
final class Account {
    static let shared = Account()

    /// Posted (on the main queue) when the account is signed in or out.
    static let changed = Notification.Name("ytm.account.changed")

    /// The hosts whose requests carry the account. Anything else is untouched.
    static let hosts = ["music.youtube.com", "www.youtube.com", "youtube.com", "m.youtube.com"]

    struct Cookie: Codable {
        var name: String
        var value: String
        var domain: String
        var path: String
        var secure: Bool
        /// Unix time; nil for a session cookie.
        var expires: Double?
    }

    /// The host and client the page uses; the same values as the PC server.
    private static let apiHost = "music.youtube.com"
    private static let origin = "https://music.youtube.com"
    private static let clientVersion = "1.20260101.01.00"
    private static let language = "zh-TW"
    private static let region = "TW"

    private let queue = DispatchQueue(label: "ytm.account")
    private var all: [Cookie] = []
    private let file: URL
    private let cookieFile: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        file = base.appendingPathComponent("account.json")
        cookieFile = base.appendingPathComponent("cookies.txt")
        if let data = try? Data(contentsOf: file),
           let list = try? JSONDecoder().decode([Cookie].self, from: data) {
            all = list
        }
    }

    // MARK: - state

    /// Where yt-dlp reads the cookies from. Written on every change.
    var ytDlpCookieFile: URL { cookieFile }

    var isLoggedIn: Bool {
        var result = false
        queue.sync {
            result = !all.isEmpty && all.contains { $0.name == "LOGIN_INFO" }
                && (sapisidLocked("__Secure-3PAPISID") != nil || sapisidLocked("SAPISID") != nil)
        }
        return result
    }

    // MARK: - cookies in and out

    /// Replaces the stored cookies (after the login page closes, or for a sign-out).
    func store(_ cookies: [Cookie]) {
        queue.sync {
            all = cookies
            if cookies.isEmpty {
                try? FileManager.default.removeItem(at: file)
                try? FileManager.default.removeItem(at: cookieFile)
            } else {
                if let data = try? JSONEncoder().encode(cookies) {
                    try? data.write(to: file, options: .atomic)
                }
                writeNetscapeLocked(cookies)
            }
        }
        Diag.shared.log("account: \(cookies.isEmpty ? "signed out" : "\(cookies.count) cookies stored")")
        DispatchQueue.main.async { NotificationCenter.default.post(name: Account.changed, object: nil) }
    }

    /// The `Cookie:` line for a URL, or nil when the host is not YouTube's.
    func cookieHeader(for url: URL) -> String? {
        guard let host = url.host?.lowercased(), Account.hosts.contains(host) else { return nil }
        var pairs: [String] = []
        queue.sync {
            let now = Date().timeIntervalSince1970
            for cookie in all where matches(cookie, host: host, url: url) {
                if let expires = cookie.expires, expires > 0, expires < now { continue }
                pairs.append("\(cookie.name)=\(cookie.value)")
            }
        }
        return pairs.isEmpty ? nil : pairs.joined(separator: "; ")
    }

    /// Adds the account to a request that goes to YouTube: cookies plus the signed
    /// `Authorization` header the API wants. Other hosts are left alone.
    func authorize(_ request: inout URLRequest) {
        guard let url = request.url, let host = url.host?.lowercased(),
              Account.hosts.contains(host) else { return }
        if let header = cookieHeader(for: url) {
            request.setValue(header, forHTTPHeaderField: "Cookie")
        }
        guard isLoggedIn else { return }
        var authorization = ""
        queue.sync {
            let stamp = String(Int(Date().timeIntervalSince1970))
            var parts: [String] = []
            for (scheme, name) in [("SAPISIDHASH", "SAPISID"),
                                   ("SAPISID1PHASH", "__Secure-1PAPISID"),
                                   ("SAPISID3PHASH", "__Secure-3PAPISID")] {
                guard let sid = sapisidLocked(name) else { continue }
                let hash = Account.sha1("\(stamp) \(sid) \(Account.origin)")
                parts.append("\(scheme) \(stamp)_\(hash)")
            }
            authorization = parts.joined(separator: " ")
        }
        guard !authorization.isEmpty else { return }
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue(Account.origin, forHTTPHeaderField: "X-Origin")
        request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        request.setValue("1", forHTTPHeaderField: "X-Youtube-Bootstrap-Logged-In")
    }

    private func sapisidLocked(_ name: String) -> String? {
        return all.first { $0.name == name && !$0.value.isEmpty }?.value
    }

    private func matches(_ cookie: Cookie, host: String, url: URL) -> Bool {
        var domain = cookie.domain.lowercased()
        if domain.hasPrefix(".") { domain.removeFirst() }
        if host != domain && !host.hasSuffix("." + domain) { return false }
        let path = url.path.isEmpty ? "/" : url.path
        return path.hasPrefix(cookie.path)
    }

    /// yt-dlp wants a Netscape file; it also rewrites it, which keeps the session fresh.
    private func writeNetscapeLocked(_ cookies: [Cookie]) {
        var text = "# Netscape HTTP Cookie File\n"
        for cookie in cookies {
            let domain = cookie.domain
            let subdomains = domain.hasPrefix(".") ? "TRUE" : "FALSE"
            let secure = cookie.secure ? "TRUE" : "FALSE"
            let expires = cookie.expires.map { String(Int($0)) } ?? "0"
            /* Tabs separate the fields; a stray tab would break the line. */
            let name = cookie.name.replacingOccurrences(of: "\t", with: "")
            let value = cookie.value.replacingOccurrences(of: "\t", with: "")
            text += "\(domain)\t\(subdomains)\t\(cookie.path)\t\(secure)\t\(expires)\t\(name)\t\(value)\n"
        }
        try? text.write(to: cookieFile, atomically: true, encoding: .utf8)
    }

    // MARK: - the account's own actions

    /// One `youtubei` call as the signed-in user. `completion` runs on the main queue.
    func call(_ endpoint: String, _ body: [String: Any],
              completion: @escaping (Result<[String: Any], AccountFailure>) -> Void) {
        guard let url = URL(string: "https://\(Account.apiHost)/youtubei/v1/\(endpoint)?prettyPrint=false") else {
            completion(.failure("bad endpoint"))
            return
        }
        var payload: [String: Any] = [
            "context": ["client": [
                "clientName": "WEB_REMIX",
                "clientVersion": Account.clientVersion,
                "hl": Account.language,
                "gl": Account.region,
            ]],
        ]
        for (key, value) in body { payload[key] = value }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            completion(.failure("bad body"))
            return
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Account.origin, forHTTPHeaderField: "Origin")
        request.setValue(Account.origin + "/", forHTTPHeaderField: "Referer")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        /* The same browser the PC server pretends to be; YouTube treats an app's default
           user agent differently. */
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                         + "(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
                         forHTTPHeaderField: "User-Agent")
        authorize(&request)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                DispatchQueue.main.async { completion(.failure(AccountFailure(error.localizedDescription))) }
                return
            }
            guard let http = response as? HTTPURLResponse else {
                DispatchQueue.main.async { completion(.failure("no response")) }
                return
            }
            guard http.statusCode == 200 else {
                self.noteSession(loggedIn: nil, status: http.statusCode)
                DispatchQueue.main.async { completion(.failure("HTTP \(http.statusCode)")) }
                return
            }
            guard let data = data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async { completion(.failure("not JSON")) }
                return
            }
            self.noteSession(loggedIn: Account.loggedInFlag(object), status: nil)
            DispatchQueue.main.async { completion(.success(object)) }
        }.resume()
    }

    // MARK: - is the sign-in still good?

    /// Called on the main queue, at most once in ten minutes, when YouTube says the stored
    /// sign-in no longer counts (the answers say "not logged in", or HTTP 401).
    var onExpired: (() -> Void)?
    private var expiredAt = Date.distantPast

    private func noteSession(loggedIn flag: String?, status: Int?) {
        guard isLoggedIn, flag == "0" || status == 401 else { return }
        DispatchQueue.main.async {
            guard Date().timeIntervalSince(self.expiredAt) > 600 else { return }
            self.expiredAt = Date()
            Diag.shared.log("account: the sign-in is no longer accepted", error: true)
            self.onExpired?()
        }
    }

    /// One small request just to learn whether the sign-in still works (at start).
    func verifySession() {
        guard isLoggedIn else { return }
        call("browse", ["browseId": "FEmusic_home"]) { _ in }
    }

    /// YouTube's answers carry "logged_in": "1" or "0" among their tracking parameters.
    private static func loggedInFlag(_ json: [String: Any]) -> String? {
        var flag: String?
        walk(json, depth: 0) { node in
            if flag != nil { return true }
            if (node["key"] as? String) == "logged_in", let value = node["value"] as? String {
                flag = value
                return true
            }
            return false
        }
        return flag
    }

    /// What the watch page says about the song's like state.
    func likeStatus(_ videoID: String, completion: @escaping (Result<String, AccountFailure>) -> Void) {
        /* The song's own queue ("RDAMVM" + id, as the web player asks) makes the answer list the
           song itself first, with its menu. */
        call("next", ["videoId": videoID, "playlistId": "RDAMVM" + videoID,
                      "isAudioOnly": true, "enablePersistentPlaylistPanel": true]) { result in
            switch result {
            case .failure(let message):
                completion(.failure(message))
            case .success(let json):
                if let status = Account.likeStatus(in: json, of: videoID) {
                    completion(.success(status))
                    return
                }
                /* nothing found: say what the answer looked like, to be fixed from the log */
                var panels = 0, buttons = 0, endpoints = 0
                Account.walk(json, depth: 0) { node in
                    if node["playlistPanelVideoRenderer"] != nil { panels += 1 }
                    if node["likeButtonRenderer"] != nil { buttons += 1 }
                    if node["likeEndpoint"] != nil { endpoints += 1 }
                    return false
                }
                Diag.shared.log("like state: not found; answer has \(panels) queue entries, \(buttons) like buttons, \(endpoints) like actions; top keys \(json.keys.sorted().joined(separator: ","))",
                                error: true, song: videoID)
                completion(.success(Account.findString(json, "likeStatus") ?? "INDIFFERENT"))
            }
        }
    }

    /// The like state of this very song. The answer lists the songs that follow as well, each
    /// with its own state, and a dictionary has no order: the first "likeStatus" found by a
    /// plain search may belong to any of them.
    private static func likeStatus(in json: [String: Any], of videoID: String) -> String? {
        var found: String?
        walk(json, depth: 0) { dictionary in
            if found != nil { return true }
            if let panel = dictionary["playlistPanelVideoRenderer"] as? [String: Any],
               (panel["videoId"] as? String) == videoID {
                if let status = findString(panel, "likeStatus") {
                    Diag.shared.log("like state read from likeStatus: \(status)", song: videoID)
                    found = status
                    return true
                }
                /* The song's menu holds the like button as an action: what pressing it would
                   do. A liked song offers INDIFFERENT (take the like away), any other offers LIKE. */
                var action: String?
                walk(panel, depth: 0) { node in
                    if action != nil { return true }
                    if let endpoint = node["defaultServiceEndpoint"] as? [String: Any],
                       let like = endpoint["likeEndpoint"] as? [String: Any],
                       let status = like["status"] as? String {
                        action = status
                        return true
                    }
                    return false
                }
                if let action = action {
                    Diag.shared.log("like state read from the menu action: \(action)", song: videoID)
                    found = action == "INDIFFERENT" ? "LIKE" : "INDIFFERENT"
                    return true
                }
                Diag.shared.log("like state: the song's entry has no like information", error: true, song: videoID)
            }
            if let button = dictionary["likeButtonRenderer"] as? [String: Any],
               let target = button["target"] as? [String: Any],
               (target["videoId"] as? String) == videoID,
               let status = button["likeStatus"] as? String {
                found = status
                return true
            }
            return false
        }
        return found
    }

    /// Tells YouTube Music that the song was listened to, so it shows in the account's history
    /// (the same small request the web player sends). The answer only goes to the log.
    func recordPlay(_ videoID: String) {
        guard isLoggedIn else { return }
        let stamp = Int(Date().timeIntervalSince1970 / 86400) - 1
        let body: [String: Any] = [
            "videoId": videoID,
            "playbackContext": ["contentPlaybackContext": ["signatureTimestamp": stamp]],
        ]
        call("player", body) { result in
            switch result {
            case .failure(let message):
                Diag.shared.log("history: player failed: \(message.text)", error: true, song: videoID)
            case .success(let json):
                guard let tracking = json["playbackTracking"] as? [String: Any],
                      let stats = tracking["videostatsPlaybackUrl"] as? [String: Any],
                      let base = stats["baseUrl"] as? String else {
                    Diag.shared.log("history: no tracking address in the answer", error: true, song: videoID)
                    return
                }
                self.sendPlayed(base, videoID)
            }
        }
    }

    private func sendPlayed(_ base: String, _ videoID: String) {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let cpn = String((0..<16).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
        guard var parts = URLComponents(string: base) else { return }
        var items = parts.queryItems ?? []
        items.append(URLQueryItem(name: "ver", value: "2"))
        items.append(URLQueryItem(name: "c", value: "WEB_REMIX"))
        items.append(URLQueryItem(name: "cpn", value: cpn))
        parts.queryItems = items
        guard let url = parts.url else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue(Account.origin, forHTTPHeaderField: "Origin")
        request.setValue(Account.origin + "/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                         + "(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
                         forHTTPHeaderField: "User-Agent")
        /* The address is on another host of the same account: the cookies are added by hand, and
           the signature headers are made for the music host and copied. */
        if let cookies = cookieHeader(for: url) { request.setValue(cookies, forHTTPHeaderField: "Cookie") }
        if let home = URL(string: Account.origin + "/") {
            var signed = URLRequest(url: home)
            authorize(&signed)
            for name in ["Authorization", "X-Origin", "X-Goog-AuthUser", "X-Youtube-Bootstrap-Logged-In"] {
                if let value = signed.value(forHTTPHeaderField: name) { request.setValue(value, forHTTPHeaderField: name) }
            }
        }
        URLSession.shared.dataTask(with: request) { _, response, error in
            let text: String
            var failed = false
            if let error = error {
                text = error.localizedDescription
                failed = true
            } else if let http = response as? HTTPURLResponse {
                text = "HTTP \(http.statusCode)"
                failed = http.statusCode >= 400
            } else {
                text = "no response"
                failed = true
            }
            DispatchQueue.main.async { Diag.shared.log("history: sent to YouTube Music: \(text)", error: failed, song: videoID) }
        }.resume()
    }

    /// LIKE, DISLIKE or INDIFFERENT.
    func setLike(_ videoID: String, status: String, completion: @escaping (Result<String, AccountFailure>) -> Void) {
        let endpoints = ["LIKE": "like/like", "DISLIKE": "like/dislike", "INDIFFERENT": "like/removelike"]
        guard let endpoint = endpoints[status] else {
            completion(.failure("bad status"))
            return
        }
        call(endpoint, ["target": ["videoId": videoID]]) { result in
            switch result {
            case .failure(let message): completion(.failure(message))
            case .success: completion(.success(status))
            }
        }
    }

    /// The playlists a song can be added to.
    func playlists(_ videoID: String, completion: @escaping (Result<[[String: Any]], AccountFailure>) -> Void) {
        call("playlist/get_add_to_playlist", ["videoIds": [videoID], "excludeWatchLater": true]) { result in
            switch result {
            case .failure(let message):
                completion(.failure(message))
            case .success(let json):
                var items: [[String: Any]] = []
                Account.walk(json, depth: 0) { object in
                    guard let option = object["playlistAddToOptionRenderer"] as? [String: Any],
                          let playlistID = option["playlistId"] as? String else { return false }
                    items.append([
                        "playlistId": playlistID,
                        "title": Account.runs(option["title"]),
                        "contains": (option["containsSelectedVideos"] as? String) == "ALL",
                    ])
                    return false
                }
                completion(.success(items))
            }
        }
    }

    func addToPlaylist(_ videoID: String, playlistID: String, completion: @escaping (Result<Void, AccountFailure>) -> Void) {
        let body: [String: Any] = [
            "playlistId": playlistID,
            "actions": [["action": "ACTION_ADD_VIDEO", "addedVideoId": videoID]],
        ]
        call("browse/edit_playlist", body) { result in
            switch result {
            case .failure(let message):
                completion(.failure(message))
            case .success(let json):
                if let status = json["status"] as? String, status != "STATUS_SUCCEEDED" {
                    completion(.failure("YouTube Music: \(status)"))
                } else {
                    completion(.success(()))
                }
            }
        }
    }

    // MARK: - small helpers

    private static func walk(_ object: Any, depth: Int, visit: ([String: Any]) -> Bool) {
        guard depth < 80 else { return }
        /* YouTube keeps most of what is wanted inside lists (tabs, queue entries, menu items). */
        if let list = object as? [Any] {
            for item in list { walk(item, depth: depth + 1, visit: visit) }
            return
        }
        guard let dictionary = object as? [String: Any] else { return }
        if visit(dictionary) { return }
        for value in dictionary.values { walk(value, depth: depth + 1, visit: visit) }
    }

    private static func findString(_ object: Any, _ key: String) -> String? {
        var found: String?
        walk(object, depth: 0) { dictionary in
            if let value = dictionary[key] as? String { found = value; return true }
            return false
        }
        return found
    }

    private static func runs(_ value: Any?) -> String {
        guard let dictionary = value as? [String: Any] else { return "" }
        if let runs = dictionary["runs"] as? [[String: Any]] {
            return runs.compactMap { $0["text"] as? String }.joined()
        }
        return dictionary["simpleText"] as? String ?? ""
    }

    private static func sha1(_ text: String) -> String {
        let data = Data(text.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA1(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// The page's account requests (like, playlists), answered with the same shapes as the PC
/// server's `/api/song/<id>/…` routes.
final class AccountBridge: NSObject, WKScriptMessageHandlerWithReply {
    private func report(_ op: String, _ id: String, _ text: String, error: Bool = false) {
        Diag.shared.log("account \(op): \(text)", error: error, song: id)
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard AppScheme.owns(message.frameInfo) else {
            replyHandler(nil, "not allowed")
            return
        }
        guard let body = message.body as? [String: Any], let op = body["op"] as? String else {
            replyHandler(nil, "bad request")
            return
        }
        /* Songs listened to meanwhile, for the phone's own history: no account needed. */
        if op == "historyPull" {
            replyHandler(["items": PlayHistory.shared.drain()], nil)
            return
        }
        guard Account.shared.isLoggedIn else {
            replyHandler(nil, "not signed in")
            return
        }
        guard let id = body["id"] as? String,
              id.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil else {
            replyHandler(nil, "bad id")
            return
        }
        switch op {
        case "like":
            if let status = body["status"] as? String {
                Account.shared.setLike(id, status: status) { result in
                    switch result {
                    case .success(let applied):
                        self.report("like", id, applied)
                        replyHandler(["ok": true, "status": applied], nil)
                    case .failure(let message):
                        self.report("like", id, message.text, error: true)
                        replyHandler(nil, message.text)
                    }
                }
            } else {
                Account.shared.likeStatus(id) { result in
                    switch result {
                    case .success(let status):
                        self.report("like status", id, status)
                        replyHandler(["status": status], nil)
                    case .failure(let message):
                        self.report("like status", id, message.text, error: true)
                        replyHandler(nil, message.text)
                    }
                }
            }
        case "playlists":
            Account.shared.playlists(id) { result in
                switch result {
                case .success(let items):
                    self.report("playlists", id, "\(items.count)")
                    replyHandler(["items": items], nil)
                case .failure(let message):
                    self.report("playlists", id, message.text, error: true)
                    replyHandler(nil, message.text)
                }
            }
        case "save":
            guard let playlistID = body["playlistId"] as? String, !playlistID.isEmpty else {
                replyHandler(nil, "bad playlistId")
                return
            }
            Account.shared.addToPlaylist(id, playlistID: playlistID) { result in
                switch result {
                case .success:
                    self.report("save", id, playlistID)
                    replyHandler(["ok": true], nil)
                case .failure(let message):
                    self.report("save", id, message.text, error: true)
                    replyHandler(nil, message.text)
                }
            }
        default:
            replyHandler(nil, "unknown op")
        }
    }
}
