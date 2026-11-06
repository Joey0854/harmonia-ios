import Foundation
import WebKit

/// The address the bundled page lives at. A custom scheme (instead of file://) gives the page
/// a normal origin, so `fetch()` of its own files and ES modules work.
enum AppScheme {
    static let name = "ytm-app"
    static let home = URL(string: "ytm-app://local/index.html")!

    /// True when a script message comes from the top frame of the bundled page. The bridges
    /// can make arbitrary network requests, so nothing else may talk to them.
    static func owns(_ frame: WKFrameInfo) -> Bool {
        guard frame.isMainFrame else { return false }
        return frame.request.url?.scheme == name || frame.securityOrigin.protocol == name
    }
}

/// Serves `ytm-app://local/<path>` from the `Web` folder inside the app bundle, and
/// `ytm-app://local/env/<id>.bin` from the envelope files in Caches (404 until made).
final class WebBundle: NSObject, WKURLSchemeHandler {
    private let root: URL? = Bundle.main.resourceURL?.appendingPathComponent("Web", isDirectory: true)

    private static let types: [String: String] = [
        "html": "text/html; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "mjs": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "json": "application/json; charset=utf-8",
        "txt": "text/plain; charset=utf-8",
        "svg": "image/svg+xml",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "webp": "image/webp",
        "ico": "image/x-icon",
        "wav": "audio/wav",
        "m4a": "audio/mp4",
        "mp3": "audio/mpeg",
        "wasm": "application/wasm",
        "woff2": "font/woff2",
        "bin": "application/octet-stream"
    ]

    /* The whole answer is given before this returns, so there is never a task that is still
       running when WebKit calls `stop` (answering a stopped task raises an exception). */
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        guard let file = fileURL(for: url),
              let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            respond(urlSchemeTask, url: url, status: 404, type: "text/plain; charset=utf-8",
                    data: Data("not found".utf8))
            return
        }
        let type = WebBundle.types[file.pathExtension.lowercased()] ?? "application/octet-stream"
        respond(urlSchemeTask, url: url, status: 200, type: type, data: data)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
    }

    /// The bundled file an address points to, or nil when it is missing or outside `Web`.
    private func fileURL(for url: URL) -> URL? {
        guard let root = root else { return nil }
        /* `path` is already percent-decoded, so an encoded "%2e%2e" is caught here as well. */
        var parts = url.path.split(separator: "/").map { String($0) }
        if parts.isEmpty { parts = ["index.html"] }
        if parts.contains("..") || parts.contains(".") { return nil }
        /* Not in the bundle: the envelope files the app makes itself (see SongAnalyzer). */
        if parts.count == 2, parts[0] == "env", parts[1].hasSuffix(".bin") {
            guard let made = SongAnalyzer.envelopeURL(String(parts[1].dropLast(4))),
                  FileManager.default.fileExists(atPath: made.path) else { return nil }
            return made
        }
        var file = root
        for part in parts { file.appendPathComponent(part) }
        let rootPath = root.standardizedFileURL.path
        guard file.standardizedFileURL.path.hasPrefix(rootPath + "/") else { return nil }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isFolder), !isFolder.boolValue else {
            return nil
        }
        return file
    }

    private func respond(_ task: WKURLSchemeTask, url: URL, status: Int, type: String, data: Data) {
        let headers = [
            "Content-Type": type,
            "Content-Length": String(data.count),
            /* The files change only with an app update; never keep an old copy across updates. */
            "Cache-Control": "no-cache"
        ]
        if let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) {
            task.didReceive(response)
        } else {
            task.didReceive(URLResponse(url: url, mimeType: nil, expectedContentLength: data.count, textEncodingName: nil))
        }
        task.didReceive(data)
        task.didFinish()
    }
}
