# Third-party notices

The MIT licence in `LICENSE` covers the code written for this project. The app bundles or
downloads the following; each stays under its own licence and terms.

| Component | Used for | Licence / terms |
| --- | --- | --- |
| [yt-dlp](https://github.com/yt-dlp/yt-dlp) | finding the audio address of a song | The Unlicense (see its repository) |
| [yt-dlp-ejs](https://github.com/yt-dlp/ejs) | solving YouTube's JavaScript challenges | see its repository |
| [CPython](https://www.python.org/) via [Python-Apple-support](https://github.com/beeware/Python-Apple-support) | running yt-dlp inside the app | PSF licence (see upstream) |
| `Web/data/hrir-*.wav`, `Web/data/kemar-*.wav` | impulse responses for the surround effect | Taken from the HeSuVi project and public KEMAR measurements. **Their licence terms have not been verified here; check them before you redistribute the app.** |

The app is not affiliated with, endorsed by or sponsored by YouTube, Google or Apple. "YouTube"
and "YouTube Music" are trademarks of Google LLC.

## Use at your own risk

The app reads audio from YouTube the way a browser would, through yt-dlp. Doing that may be
against YouTube's Terms of Service, and it can stop working at any time when YouTube changes.
It is meant for personal use with music you are entitled to listen to. You are responsible for
how you use it.
