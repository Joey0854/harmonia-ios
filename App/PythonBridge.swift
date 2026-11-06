import Foundation

/// A PyObject *. The CPython headers give PyObject as a complete struct, so the
/// importer turns it into a typed pointer rather than OpaquePointer.
private typealias PyRef = UnsafeMutablePointer<PyObject>

/// The Python that ships inside the app: where its standard library and our
/// modules are. `tools/build-python.py` builds exactly this layout.
enum PythonRuntime {
    /// Must match the Python version in tools/build-python.py.
    static let version = "3.14"

    static var root: String {
        (Bundle.main.resourcePath ?? AppPaths.documents) + "/PythonRuntime"
    }

    static var stdlib: String { root + "/lib/python" + version }
    static var dynload: String { stdlib + "/lib-dynload" }
    static var sitePackages: String { stdlib + "/site-packages" }

    /// True when the bundle really contains the runtime (a build made without it).
    static var bundled: Bool {
        FileManager.default.fileExists(atPath: sitePackages + "/ytm_bridge.py")
    }
}

enum AppPaths {
    static var documents: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
    }

    static var caches: String {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].path
    }
}

/// The embedded CPython, started once, used from one queue.
///
/// yt-dlp needs a Python interpreter; iOS apps cannot start one as a process, so
/// it is linked in as a framework and started here. Everything runs on the same
/// serial queue: CPython is single interpreter, and the JavaScriptCore context
/// the challenge provider uses is not thread safe either.
final class PythonBridge {
    static let shared = PythonBridge()

    /// Called on the main queue when the interpreter is up (or has failed).
    var onReady: ((Bool, String) -> Void)?

    private let queue = DispatchQueue(label: "ytm.python", qos: .userInitiated)
    private var started = false
    private var startError: String?
    private var module: PyRef?
    private var extractFunction: PyRef?
    private var versionFunction: PyRef?
    private var selftestFunction: PyRef?
    private var logFunction: PyRef?
    private var cookiesFunction: PyRef?

    /// Read on the main queue after `onReady`.
    private(set) var ready = false
    private(set) var detail = "not started"

    private init() {}

    // MARK: - start

    /// Starts the interpreter in the background; safe to call more than once.
    func start() {
        queue.async { self.startLocked() }
    }

    private func startLocked() {
        if started { return }
        started = true
        guard PythonRuntime.bundled else {
            finish(ok: false, message: "no Python runtime in the bundle")
            return
        }
        _ = setenv("YTM_CACHE_DIR", AppPaths.caches, 1)
        _ = setenv("PYTHONDONTWRITEBYTECODE", "1", 1)
        /* Keep the app's own files out of the way of a user's Documents backup. */
        _ = setenv("HOME", NSHomeDirectory(), 1)

        let home = PythonRuntime.root
        var config = PyConfig()
        PyConfig_InitIsolatedConfig(&config)
        config.buffered_stdio = 0
        config.write_bytecode = 0
        config.install_signal_handlers = 0
        config.parse_argv = 0
        config.module_search_paths_set = 1

        var status = PyStatus_Ok()
        /* `&config` and `&config.home` in one call would be overlapping accesses in Swift, so
           the config is used through a pointer here. */
        withUnsafeMutablePointer(to: &config) { pointer in
            status = PyConfig_SetBytesString(pointer, &pointer.pointee.home, home)
        }
        if PyStatus_Exception(status) != 0 {
            PyConfig_Clear(&config)
            finish(ok: false, message: "PyConfig home: \(PyBridgeMessage(status))")
            return
        }

        status = PyConfig_Read(&config)
        if PyStatus_Exception(status) != 0 {
            PyConfig_Clear(&config)
            finish(ok: false, message: "PyConfig read: \(PyBridgeMessage(status))")
            return
        }

        for path in [PythonRuntime.stdlib, PythonRuntime.dynload, PythonRuntime.sitePackages] {
            guard let wide = Py_DecodeLocale(path, nil) else { continue }
            _ = PyWideStringList_Append(&config.module_search_paths, wide)
            PyMem_RawFree(wide)
        }

        status = Py_InitializeFromConfig(&config)
        PyConfig_Clear(&config)
        if PyStatus_Exception(status) != 0 {
            finish(ok: false, message: "Py_Initialize: \(PyBridgeMessage(status))")
            return
        }

        /* The interpreter now lives on this queue's thread; let other threads take the GIL. */
        _ = PyEval_SaveThread()

        let gil = PyGILState_Ensure()
        defer { PyGILState_Release(gil) }

        guard let mod = PyImport_ImportModule("ytm_bridge") else {
            let error = popError()
            finish(ok: false, message: "import ytm_bridge: \(error)")
            return
        }
        module = mod
        guard let fn = PyObject_GetAttrString(mod, "extract") else {
            finish(ok: false, message: "ytm_bridge.extract is missing")
            return
        }
        extractFunction = fn
        versionFunction = PyObject_GetAttrString(mod, "version")
        selftestFunction = PyObject_GetAttrString(mod, "selftest")
        logFunction = PyObject_GetAttrString(mod, "log_text")
        cookiesFunction = PyObject_GetAttrString(mod, "set_cookies")

        Diag.shared.log("python: \(PythonRuntime.version) up, yt-dlp bridge loaded")
        finish(ok: true, message: "ready")
    }

    private func finish(ok: Bool, message: String) {
        ready = ok
        detail = message
        if !ok {
            startError = message
            Diag.shared.log("python: \(message)", error: true)
        }
        DispatchQueue.main.async {
            self.onReady?(ok, message)
        }
    }

    // MARK: - calls

    /// yt-dlp's answer for one song, as it returns it (see Py/ytm_bridge.py).
    /// Blocks the calling thread (seconds); call off the main queue.
    func extract(_ videoID: String) -> [String: Any]? {
        var out: [String: Any]?
        queue.sync {
            self.startLocked()
            guard startError == nil, let fn = extractFunction else { return }
            out = callJSON(fn, videoID)
        }
        return out
    }

    /// Versions of Python, yt-dlp, EJS and the JS engine.
    func versions() -> String {
        var out = ""
        queue.sync {
            self.startLocked()
            guard startError == nil, let fn = versionFunction else {
                out = "python not running: \(startError ?? "?")"
                return
            }
            out = callString(fn)
        }
        return out
    }

    /// Runs the challenge solver once (a tiny script, no network).
    func selftest() -> String {
        var out = ""
        queue.sync {
            self.startLocked()
            guard startError == nil, let fn = selftestFunction else {
                out = "python not running: \(startError ?? "?")"
                return
            }
            out = callString(fn)
        }
        return out
    }

    /// Hands yt-dlp the cookie file written after a sign-in (an empty path clears it).
    func setCookies(_ path: String) {
        queue.sync {
            self.startLocked()
            guard startError == nil, let fn = cookiesFunction else { return }
            _ = callStringArg(fn, path)
        }
    }

    /// The last lines of yt-dlp's own log.
    func logText() -> String {
        var out = ""
        queue.sync {
            guard let fn = logFunction else { return }
            out = callString(fn)
        }
        return out
    }

    private func callString(_ fn: PyRef) -> String {
        let gil = PyGILState_Ensure()
        defer { PyGILState_Release(gil) }
        guard let value = PyObject_CallObject(fn, nil) else {
            return "error: " + popError()
        }
        defer { Py_DecRef(value) }
        guard let text = PyUnicode_AsUTF8(value) else { return "" }
        return String(cString: text)
    }

    /// Calls a Python function that takes one string and answers with a string.
    private func callStringArg(_ fn: PyRef, _ argument: String) -> String {
        let gil = PyGILState_Ensure()
        defer { PyGILState_Release(gil) }
        guard let arg = PyUnicode_FromString(argument) else { return "" }
        guard let args = PyTuple_New(1) else {
            Py_DecRef(arg)
            return ""
        }
        _ = PyTuple_SetItem(args, 0, arg)
        let value = PyObject_CallObject(fn, args)
        Py_DecRef(args)
        guard let value = value else { return "" }
        defer { Py_DecRef(value) }
        guard let text = PyUnicode_AsUTF8(value) else { return "" }
        return String(cString: text)
    }

    private func callJSON(_ fn: PyRef, _ argument: String) -> [String: Any]? {
        let gil = PyGILState_Ensure()
        defer { PyGILState_Release(gil) }
        guard let arg = PyUnicode_FromString(argument) else { return nil }
        guard let args = PyTuple_New(1) else {
            Py_DecRef(arg)
            return nil
        }
        /* PyTuple_SetItem takes the reference to arg. */
        _ = PyTuple_SetItem(args, 0, arg)
        let value = PyObject_CallObject(fn, args)
        Py_DecRef(args)
        guard let value = value else {
            Diag.shared.log("python: extract failed: \(popError())", error: true)
            return nil
        }
        defer { Py_DecRef(value) }
        guard let text = PyUnicode_AsUTF8(value) else { return nil }
        let json = String(cString: text)
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    /// Turns the interpreter's current exception into one line and clears it.
    private func popError() -> String {
        var type: PyRef?
        var value: PyRef?
        var traceback: PyRef?
        PyErr_Fetch(&type, &value, &traceback)
        PyErr_NormalizeException(&type, &value, &traceback)
        defer {
            if let t = type { Py_DecRef(t) }
            if let v = value { Py_DecRef(v) }
            if let b = traceback { Py_DecRef(b) }
        }
        guard let v = value, let text = PyObject_Str(v), let utf8 = PyUnicode_AsUTF8(text) else {
            return "unknown Python error"
        }
        Py_DecRef(text)
        return String(cString: utf8)
    }
}

/// The message of a failed `PyStatus` (the exit code when there is no message).
private func PyBridgeMessage(_ status: PyStatus) -> String {
    if let message = status.err_msg { return String(cString: message) }
    return "exit code \(status.exitcode)"
}
