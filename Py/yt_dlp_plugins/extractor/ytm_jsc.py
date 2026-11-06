"""yt-dlp's JS challenge provider that runs on Apple's JavaScriptCore.

yt-dlp needs to evaluate YouTube's player JavaScript (the `n` and `sig`
challenges).  The usual way is an external runtime - Deno, Node, QuickJS -
started as a separate process.  iOS apps cannot start processes, but the system
JavaScriptCore framework is right there, so this provider feeds the very same
EJS solver scripts into a JSC context inside the app.

The solver stdin/stdout contract is yt-dlp's own (`EJSBaseJCP`): the script is
evaluated, console output is the answer.  `ytm_js` does the evaluation.
"""

import ytm_js
from yt_dlp.extractor.youtube.jsc.provider import (
    JsChallengeProviderError,
    JsChallengeProvider,
    JsChallengeType,
    register_preference,
    register_provider,
)

# The EJS plumbing (script selection, verification, stdin building) lives in a
# private module; we pin the yt-dlp version that ships in the app, so this is
# safe, and it keeps us from re-implementing the hash checks.
from yt_dlp.extractor.youtube.jsc._builtin.ejs import EJSBaseJCP

__version__ = '0.1.0'


@register_provider
class AppleJSCJCP(EJSBaseJCP):
    PROVIDER_VERSION = __version__
    PROVIDER_NAME = 'apple-jsc'
    BUG_REPORT_LOCATION = 'https://github.com/Joey0854/ytm-remote-ios/issues'
    JS_RUNTIME_NAME = 'apple-jsc'
    _SUPPORTED_TYPES = [JsChallengeType.N, JsChallengeType.SIG]

    def is_available(self):
        """Cheap: only asks whether an engine can be opened (once)."""
        return ytm_js.available()

    def _run_js_runtime(self, stdin, /):
        try:
            return ytm_js.run(stdin)
        except ytm_js.JsRuntimeError as e:
            raise JsChallengeProviderError(f'JavaScriptCore: {e}', expected=False)


@register_preference(AppleJSCJCP)
def apple_jsc_preference(provider: JsChallengeProvider, requests) -> int:
    """The only provider in the app; the built-in ones need an external binary."""
    return 1000
