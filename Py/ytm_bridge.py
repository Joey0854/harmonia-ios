"""The yt-dlp entry point of the app, called from Swift.

`extract(video_id)` returns JSON:

    {"ok": true, "url": ..., "headers": {...}, "size": 3449447,
     "duration": 213.089, "mime": "audio/mp4", "expires": 1793995095,
     "title": ..., "artist": ...}

    {"ok": false, "error": "..."}

Everything happens in this process: yt-dlp extracts, the JavaScriptCore
challenge provider solves YouTube's player JavaScript.  No subprocess, no
external binary, no PC.

Only the module's functions are used by the app; the interpreter is started
once by PythonBridge.swift and every call runs on its single Python thread.
"""

import json
import os
import sys
import time

__all__ = ['extract', 'selftest', 'version', 'log_text', 'configure', 'set_cookies']

_VIDEO_ID_CHARS = set('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-')

# The same format order the PC server uses: AAC in MP4, which iOS plays natively.
_FORMAT = '140/bestaudio[ext=m4a]/bestaudio'

_log = []
_log_limit = 400


def _note(text):
    line = time.strftime('%H:%M:%S ') + str(text)
    _log.append(line)
    if len(_log) > _log_limit:
        del _log[0:len(_log) - _log_limit]
    try:
        print(line, file=sys.stderr, flush=True)
    except Exception:
        pass


def log_text():
    return '\n'.join(_log[-120:])


class _Logger:
    """yt-dlp's logger: keep the lines, let the app read them."""

    def debug(self, msg):
        if not msg.startswith('[debug] '):
            _note(msg)

    def info(self, msg):
        _note(msg)

    def warning(self, msg):
        _note('warning: ' + msg)

    def error(self, msg):
        _note('error: ' + msg)


class _Settings:
    video_id = ''
    cachedir = ''
    cookies = ''
    source_address = ''


def configure(video_id='', cachedir='', cookies='', source_address=''):
    """Set by Swift before the first extract(): cache folder, cookie file."""
    _Settings.video_id = video_id or ''
    if cachedir:
        _Settings.cachedir = cachedir
    if cookies:
        _Settings.cookies = cookies
    if source_address:
        _Settings.source_address = source_address


def set_cookies(path):
    """The Netscape cookie file written by the app after a sign-in ('' clears it).

    yt-dlp reads it on every extraction and rewrites it, so the session it gets is the one
    the user signed in with - age-restricted songs and the like then work.
    """
    path = str(path or '')
    _Settings.cookies = path if path and os.path.exists(path) else ''
    _note('cookies: ' + (_Settings.cookies or 'none'))
    return _Settings.cookies


def _cache_dir():
    """Where yt-dlp keeps its own caches (player code, signature functions)."""
    if _Settings.cachedir:
        return _Settings.cachedir
    candidates = []
    if os.environ.get('YTM_CACHE_DIR'):
        candidates.append(os.environ['YTM_CACHE_DIR'])
    candidates.append(os.path.join(os.path.expanduser('~'), 'Library', 'Caches'))
    import tempfile
    candidates.append(tempfile.gettempdir())
    for base in candidates:
        path = os.path.join(base, 'yt-dlp')
        try:
            os.makedirs(path, exist_ok=True)
            return path
        except OSError:
            continue
    return tempfile.gettempdir()


def version():
    """Versions of everything involved, as JSON; shown on the app's diag screen."""
    import yt_dlp
    import ytm_js
    out = {
        'python': sys.version.split()[0],
        'platform': sys.platform,
        'yt_dlp': yt_dlp.version.__version__,
        'js': 'unknown',
    }
    try:
        import yt_dlp_ejs
        out['ejs'] = getattr(yt_dlp_ejs, 'version', '?')
    except Exception:
        out['ejs'] = 'missing'
    try:
        import yt_dlp_plugins.extractor.ytm_jsc  # noqa: F401
        out['provider'] = 'loaded'
    except Exception as e:
        out['provider'] = 'failed: %s' % e
    try:
        out['js'] = 'ok' if ytm_js.available() else 'unavailable'
    except Exception as e:
        out['js'] = 'failed: %s' % e
    return json.dumps(out, ensure_ascii=False)


def selftest():
    """Runs the challenge solver twice: the second answer must stand on its own."""
    result = {'ok': False}
    try:
        import ytm_js
        probe = ('console.log(JSON.stringify({ok: true, sum: [1, 2, 3].reduce((a, b) => a + b, 0)}));')
        first = json.loads(ytm_js.run(probe))
        again = json.loads(ytm_js.run('console.log(JSON.stringify({again: true}));'))
        result['js'] = first
        result['again'] = again
        result['ok'] = first.get('ok') is True and again.get('again') is True and len(again) == 1
        if not result['ok']:
            result['error'] = 'the second solve did not stand on its own'
    except Exception as e:
        result['error'] = '%s: %s' % (type(e).__name__, e)
    result['versions'] = json.loads(version())
    return json.dumps(result, ensure_ascii=False)


def _headers_for(headers):
    """Only what a ranged download may send; no Accept-Encoding (it would compress)."""
    keep = ('User-Agent', 'Referer', 'Origin', 'Accept-Language')
    out = {}
    for name, value in (headers or {}).items():
        if name in keep and isinstance(value, str):
            out[name] = value
    if 'User-Agent' not in out:
        out['User-Agent'] = ('Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) '
                             'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1')
    return out


def _mime(ext, acodec):
    ext = (ext or '').lower()
    if ext == 'm4a' or 'mp4a' in (acodec or ''):
        return 'audio/mp4'
    if ext == 'webm':
        return 'audio/webm'
    if ext == 'mp3':
        return 'audio/mpeg'
    return 'audio/mp4'


def _expires(url):
    try:
        from urllib.parse import urlparse, parse_qs
        query = parse_qs(urlparse(url).query)
        value = query.get('expire') or query.get('expire_at')
        if value:
            return int(value[0])
    except Exception:
        pass
    return 0


def _lookup(yt_dlp, params, url):
    """One extraction attempt. Answers (info, error)."""
    try:
        with yt_dlp.YoutubeDL(params) as ydl:
            info = ydl.extract_info(url, download=False)
    except Exception as e:
        lines = str(e).strip().splitlines()
        return None, (lines[0] if lines else type(e).__name__)
    if isinstance(info, dict) and info.get('_type') == 'playlist':
        entries = info.get('entries') or []
        info = entries[0] if entries else None
    if not isinstance(info, dict) or not info.get('url'):
        return None, 'no audio address'
    return info, None


def extract(video_id):
    """Looks up one song's playable audio address. Returns JSON text."""
    video_id = str(video_id or '').strip()
    if not video_id or len(video_id) != 11 or any(ch not in _VIDEO_ID_CHARS for ch in video_id):
        return json.dumps({'ok': False, 'error': 'bad video id'}, ensure_ascii=False)

    started = time.time()
    try:
        import yt_dlp
    except Exception as e:
        _note('import yt_dlp failed: %s: %s' % (type(e).__name__, e))
        return json.dumps({'ok': False, 'error': 'yt-dlp is not available (%s)' % e}, ensure_ascii=False)

    params = {
        'quiet': True,
        'no_warnings': False,
        'noprogress': True,
        'skip_download': True,
        'noplaylist': True,
        'format': _FORMAT,
        'cachedir': _cache_dir(),
        'socket_timeout': 20,
        'retries': 2,
        'nocheckcertificate': False,
        'no_color': True,
        'force_json': True,
        'logger': _Logger(),
        # Do not look for deno/node on the device: the JSC provider handles it.
        'js_runtimes': {},
        'extractor_args': {'youtube': {'skip': ['hls', 'dash']}},
    }
    if _Settings.cookies and os.path.exists(_Settings.cookies):
        params['cookiefile'] = _Settings.cookies
    if _Settings.source_address:
        params['source_address'] = _Settings.source_address

    url = 'https://music.youtube.com/watch?v=' + video_id
    info, error = _lookup(yt_dlp, params, url)
    account_error = ''
    if error and params.get('cookiefile'):
        # Signed in, but the account cannot have this song: play it anonymously rather than
        # not at all. What the account said stays in the log (and in `accountError`).
        _note('extract %s with the account failed: %s - trying without cookies' % (video_id, error))
        account_error = error
        plain = dict(params)
        plain.pop('cookiefile', None)
        info, again = _lookup(yt_dlp, plain, url)
        if info is not None:
            error = None
        else:
            error = '%s / anonymously: %s' % (account_error, again)
    if error:
        _note('extract %s failed after %.1f s: %s' % (video_id, time.time() - started, error))
        return json.dumps({'ok': False, 'error': error}, ensure_ascii=False)

    selected = info
    if info.get('requested_formats'):
        selected = info['requested_formats'][0]
    address = selected.get('url') or ''
    if not address.startswith('https://'):
        return json.dumps({'ok': False, 'error': 'unexpected address'}, ensure_ascii=False)

    size = selected.get('filesize') or selected.get('filesize_approx') or 0
    duration = info.get('duration') or selected.get('duration') or 0
    result = {
        'ok': True,
        'url': address,
        'headers': _headers_for(info.get('http_headers')),
        'size': int(size or 0),
        'duration': float(duration or 0),
        'mime': _mime(selected.get('ext') or info.get('ext'), selected.get('acodec')),
        'expires': _expires(address),
        'title': info.get('title') or '',
        'artist': info.get('artist') or info.get('uploader') or '',
        'seconds': round(time.time() - started, 2),
    }
    if account_error:
        result['accountError'] = account_error
    if account_error:
        _note('extract %s: played anonymously (account: %s)' % (video_id, account_error))
    else:
        _note('extract %s: %.1f s, %s, %s bytes, %s' % (
            video_id, result['seconds'], result['mime'], result['size'], video_id))
    return json.dumps(result, ensure_ascii=False)
