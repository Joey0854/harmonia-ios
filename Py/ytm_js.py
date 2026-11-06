"""A small JavaScript runner for the yt-dlp EJS challenge solver.

On iOS the engine is JavaScriptCore, which ships with the system; it is used
through its C API with ctypes, so no extra binary is needed and no process is
started.  On a development machine (macOS/Windows/Linux) there is no JSC, so a
`node` binary is used instead - only for testing, never on the phone.

The contract is the one yt-dlp's EJS providers expect: the whole script is
evaluated, whatever it passes to console.log() is the result.  The script is
synchronous (lib + core + console.log(JSON.stringify(jsc(...)))).
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile

__all__ = ['run', 'available', 'engine', 'JsRuntimeError']


class JsRuntimeError(Exception):
    pass


_FRAMEWORK = '/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore'

# Runs before the challenge script: collects console output and gives the page
# the globals a browser would have (the solver's own setup does the rest).
_PRELUDE = r"""
(function () {
  var out = [];
  function one(v) {
    if (typeof v === 'string') return v;
    try { var s = JSON.stringify(v); return s === undefined ? String(v) : s; }
    catch (e) { return String(v); }
  }
  function log() { out.push(Array.prototype.map.call(arguments, one).join(' ')); }
  var c = { log: log, info: log, debug: log, warn: log, error: log, trace: log, assert: log };
  globalThis.console = c;
  if (typeof globalThis.window === 'undefined') globalThis.window = globalThis;
  if (typeof globalThis.self === 'undefined') globalThis.self = globalThis;
  if (typeof globalThis.global === 'undefined') globalThis.global = globalThis;
  globalThis.__ytm_out = out;
})();
"""


class _JSC:
    """One JavaScriptCore context, kept for the life of the process.

    JSC objects are not thread safe, so the caller must always use the same
    thread; the bridge does (a single serial queue).
    """

    def __init__(self):
        import ctypes
        from ctypes import (c_char_p, c_int, c_size_t, c_void_p, POINTER,
                            create_string_buffer)

        self._ctypes = ctypes
        self._c_void_p = c_void_p
        self._create_string_buffer = create_string_buffer

        lib = ctypes.CDLL(_FRAMEWORK)
        self._lib = lib

        def sig(name, restype, *argtypes):
            fn = getattr(lib, name)
            fn.restype = restype
            fn.argtypes = list(argtypes)
            return fn

        self._ctx_create = sig('JSGlobalContextCreate', c_void_p, c_void_p)
        self._ctx_release = sig('JSGlobalContextRelease', None, c_void_p)
        self._eval = sig('JSEvaluateScript', c_void_p,
                         c_void_p, c_void_p, c_void_p, c_void_p, c_int, POINTER(c_void_p))
        self._str_new = sig('JSStringCreateWithUTF8CString', c_void_p, c_char_p)
        self._str_max = sig('JSStringGetMaximumUTF8CStringSize', c_size_t, c_void_p)
        self._str_get = sig('JSStringGetUTF8CString', c_size_t, c_void_p, c_char_p, c_size_t)
        self._str_release = sig('JSStringRelease', None, c_void_p)
        self._to_string = sig('JSValueToStringCopy', c_void_p,
                              c_void_p, c_void_p, POINTER(c_void_p))
        self._ctx = None

    # -- helpers ---------------------------------------------------------

    def _jsstring(self, text):
        data = text.encode('utf-8') if isinstance(text, str) else text
        ref = self._str_new(data)
        if not ref:
            raise JsRuntimeError('JSStringCreateWithUTF8CString failed')
        return ref

    def _text(self, value):
        exc = self._c_void_p()
        js = self._to_string(self._ctx, value, self._ctypes.byref(exc))
        if not js:
            raise JsRuntimeError('JSValueToStringCopy failed')
        try:
            size = int(self._str_max(js)) + 1
            buf = self._create_string_buffer(size)
            self._str_get(js, buf, size)
            return buf.value.decode('utf-8', 'replace')
        finally:
            self._str_release(js)

    def eval(self, script):
        """Evaluates `script`; returns its value as text. Raises on a JS exception."""
        src = self._jsstring(script)
        exc = self._c_void_p()
        try:
            value = self._eval(self._ctx, src, None, None, 1, self._ctypes.byref(exc))
        finally:
            self._str_release(src)
        if exc.value:
            message = ''
            try:
                message = self._text(exc)
            except Exception:
                message = '<unreadable exception>'
            raise JsRuntimeError(message)
        if not value:
            return 'undefined'
        return self._text(value)

    def _open(self):
        """A fresh context with the prelude in it."""
        self.close()
        self._ctx = self._ctx_create(None)
        if not self._ctx:
            raise JsRuntimeError('JSGlobalContextCreate failed')
        self.eval(_PRELUDE)

    def run(self, script):
        """Evaluates one EJS script in a context of its own.

        A fresh context every time: the solver's own globals and the collected console
        output would otherwise carry over, and the second answer of the session would be
        the first one joined with it - which is unreadable JSON, so the `n` signature is
        lost and every format that needs it disappears ("Requested format is not
        available").
        """
        self._open()
        try:
            self.eval(script)
            return self.eval('__ytm_out.join("\\n")')
        finally:
            self.close()

    def close(self):
        if getattr(self, '_ctx', None):
            self._ctx_release(self._ctx)
            self._ctx = None


class _Node:
    """Test-only engine: runs the script with a `node` binary."""

    def __init__(self, binary):
        self.binary = binary

    def eval(self, script):
        fd, path = tempfile.mkstemp(prefix='ytmjs-', suffix='.js')
        try:
            with os.fdopen(fd, 'wb') as fh:
                fh.write(_PRELUDE.encode('utf-8'))
                fh.write(b'\n')
                fh.write(script.encode('utf-8'))
                fh.write(b"\nprocess.stdout.write(__ytm_out.join('\\n'));\n")
            proc = subprocess.run([self.binary, path], capture_output=True, timeout=120)
        finally:
            try:
                os.unlink(path)
            except OSError:
                pass
        if proc.returncode != 0:
            err = proc.stderr.decode('utf-8', 'replace').strip()
            raise JsRuntimeError(err[-2000:] or f'node exited {proc.returncode}')
        return proc.stdout.decode('utf-8', 'replace')

    def run(self, script):
        return self.eval(script)

    def close(self):
        pass


_engine = None


def engine():
    """The engine object, created on first use. `None` when there is none."""
    global _engine
    if _engine is not None:
        return _engine
    if sys.platform in ('ios', 'tvos', 'visionos', 'watchos') or (
            sys.platform == 'darwin' and os.path.exists(_FRAMEWORK)):
        _engine = _JSC()
        return _engine
    node = os.environ.get('YTM_JS_NODE') or shutil.which('node')
    if node:
        _engine = _Node(node)
        return _engine
    raise JsRuntimeError('no JavaScript engine (JavaScriptCore is not on this system)')


def available():
    try:
        engine()
        return True
    except Exception:
        return False


def run(script):
    """Evaluates the EJS script, returns what it printed to console."""
    return engine().run(script)


def _selftest():
    first = run('console.log(JSON.stringify({ok: true, sum: [1, 2, 3].reduce((a, b) => a + b, 0)}));')
    assert json.loads(first) == {'ok': True, 'sum': 6}, first
    # A second solve in the same session must be readable on its own.
    second = run('console.log(JSON.stringify({ok: true}));')
    assert json.loads(second) == {'ok': True}, second
    return 'ok'


if __name__ == '__main__':
    print(_selftest())
