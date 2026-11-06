import Foundation
import WebKit

/// Lets the bundled page make HTTP requests that a web page cannot make itself: no CORS, and
/// headers such as `User-Agent` are really sent.
///
/// Page side:
///   const r = await webkit.messageHandlers.ytmHttp.postMessage(
///       { url, method, headers, body /* base64 */, timeoutMs });
///   // r = { status, headers /* lower-cased names */, body /* base64 */, url /* after redirects */ }
///   // the promise rejects with a string when the request fails
///
/// The URLSession keeps this object alive for the life of the app, which is what we want.
final class HttpBridge: NSObject, WKScriptMessageHandlerWithReply, URLSessionDataDelegate {
    private static let maxBytes = 32 * 1024 * 1024
    private static let defaultTimeout: TimeInterval = 20

    private struct Pending {
        var data = Data()
        let reply: (Any?, String?) -> Void
    }

    private var session: URLSession!
    /// Requests in flight, by task number. Only touched on the main queue (the session calls
    /// its delegate there too).
    private var pending: [Int: Pending] = [:]

    override init() {
        super.init()
        /* Nothing is remembered between requests: no cookies, no cache. The page decides
           everything that is sent. */
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = HttpBridge.defaultTimeout
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        /* Answered with an error instead of silence so a promise never hangs. */
        guard AppScheme.owns(message.frameInfo) else {
            replyHandler(nil, "not allowed")
            return
        }
        guard let body = message.body as? [String: Any],
              let address = body["url"] as? String,
              let url = URL(string: address),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            replyHandler(nil, "bad url")
            return
        }
        var timeout = HttpBridge.defaultTimeout
        if let ms = (body["timeoutMs"] as? NSNumber)?.doubleValue, ms.isFinite, ms > 0 {
            timeout = min(max(ms / 1000, 1), 300)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = (body["method"] as? String)?.uppercased() ?? "GET"
        request.httpShouldHandleCookies = false
        if let headers = body["headers"] as? [String: Any] {
            for (name, value) in headers {
                if let text = value as? String { request.setValue(text, forHTTPHeaderField: name) }
            }
        }
        if let encoded = body["body"] as? String {
            guard let data = Data(base64Encoded: encoded) else {
                replyHandler(nil, "body is not base64")
                return
            }
            request.httpBody = data
        }
        /* YouTube requests made while signed in carry the account, so the page's own
           `youtubei` calls answer with the user's home feed, library and search. */
        Account.shared.authorize(&request)

        let task = session.dataTask(with: request)
        let key = task.taskIdentifier
        pending[key] = Pending(reply: replyHandler)
        task.resume()
        /* The request's own timeout only measures silence; this bounds the whole request. */
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self, weak task] in
            guard let self = self, let waiting = self.pending.removeValue(forKey: key) else { return }
            task?.cancel()
            waiting.reply(nil, "timed out")
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let key = dataTask.taskIdentifier
        guard var entry = pending[key] else { return }
        entry.data.append(data)
        if entry.data.count > HttpBridge.maxBytes {
            pending[key] = nil
            dataTask.cancel()
            entry.reply(nil, "response larger than 32 MB")
        } else {
            pending[key] = entry
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let entry = pending.removeValue(forKey: task.taskIdentifier) else { return }
        if let error = error {
            entry.reply(nil, error.localizedDescription)
            return
        }
        guard let http = task.response as? HTTPURLResponse else {
            entry.reply(nil, "no response")
            return
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            headers[String(describing: name).lowercased()] = String(describing: value)
        }
        let status = http.statusCode
        let finalURL = http.url?.absoluteString ?? ""
        let data = entry.data
        let reply = entry.reply
        /* Encoding a large body takes a moment; keep it off the main queue. WebKit wants the
           answer back on the main queue. */
        DispatchQueue.global(qos: .userInitiated).async {
            let encoded = data.base64EncodedString()
            DispatchQueue.main.async {
                reply(["status": status, "headers": headers, "body": encoded, "url": finalURL], nil)
            }
        }
    }
}
