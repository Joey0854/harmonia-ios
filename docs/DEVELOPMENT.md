# YTM Remote (iOS) - developer notes

A small iPhone app: a web page for the interface, the system audio player for the sound
(background playback, lock screen, Control Centre).

## Standalone build

From version 0.2 the app needs no PC. The page and its JavaScript backend are inside the app.

### The `Web/` folder

Everything in `Web/` at the repo root is copied into the app unchanged, sub-folders included
(`Web/data/...` stays `data/...`). The app opens `ytm-app://local/index.html`;
`ytm-app://local/<path>` is `Web/<path>`.

- `Web/index.html` must exist.
- Content types are chosen by extension: html, js/mjs, css, json, txt, svg, png, jpg, webp,
  ico, wav, m4a, mp3, wasm, woff2; anything else is `application/octet-stream`.
- Always HTTP 200 with `Content-Length`, or 404. `Range` requests are not supported, so load
  bundled audio with `fetch()` + `decodeAudioData`, not with an `<audio>` element.
- Use relative addresses (`data/x.json`), or absolute ones starting with `/`.
- Before any page script runs: `window.__ytmNative === true`, `window.__ytmStandalone === true`.
- The top frame cannot navigate away from `ytm-app://`. Tapped http(s) links open in Safari.

### Bridge: HTTP without CORS

```js
const r = await webkit.messageHandlers.ytmHttp.postMessage({
  url: 'https://…',            // http or https only
  method: 'POST',              // default GET
  headers: { 'User-Agent': '…', 'Content-Type': 'application/json' },
  body: btoa('…'),             // base64, optional
  timeoutMs: 20000             // whole request; default 20 s
});
// r = { status, headers /* names lower-cased */, body /* base64 */, url /* after redirects */ }
// rejects with a string: "timed out", "bad url", "response larger than 32 MB", a network error…
```

No cookies and no cache are kept between requests; redirects are followed. Only the top
frame of the bundled page may call it.

### Bridge: player commands

`webkit.messageHandlers.ytm.postMessage({ cmd, ... })`

| cmd | fields | what it does |
| --- | --- | --- |
| `loadSong` | `id, url, headers, startAt, size, duration?, mime?, local?` | `url` may be `""` when `local` is true (stored song). Download `url` with `headers` in 1 MB `Range` requests to `Caches/stream/<id>.m4a`, then play the file. Starts at once when the song is stored or cached. `size` 0 = unknown. Send `play` as usual. |
| `load` | `url, startAt` | Play an address the player can open itself. |
| `play`, `pause` | | |
| `seek` | `t` | |
| `meta` | `title, artist, artwork, duration` | Lock-screen text and picture. |
| `dur` | `d` | Real length of the current song. |
| `queue` | `items: [{ id, url, title, artist, artwork, duration, headers?, size?, mime?, local? }]` | Songs the app continues with by itself. With `headers`, the first item is downloaded ahead while the current song plays. |
| `dl` | `id, url, headers?, size?, mime?` | Keep a song on the phone (with `headers`: ranged download). |
| `dlDelete` | `id` | |
| `dlList` | | Answered with a `dlList` event. |

A new `loadSong`/`load` cancels the download of the previous song; the download of the next
queued song is left alone. About 25 cached songs are kept, least recently used deleted first.
Songs stored with `dl` always win over the cache and the network.

### Events

The app calls `window.__ytmNativeEvent(event)`:

| event | meaning |
| --- | --- |
| `{ type: "ready", dur }` | The song can play. |
| `{ type: "time", t, dur, playing }` | About four times a second. |
| `{ type: "state", playing }` | |
| `{ type: "seeked" }` | |
| `{ type: "ended" }` | Song over, nothing queued in the app. |
| `{ type: "advanced", id }` | The app moved on to this queued song. If its file is not here yet, `progress` events follow and then `ready`. |
| `{ type: "remote", action: "next" \| "prev" }` | Lock-screen button the app could not handle alone. |
| `{ type: "progress", id, received, total }` | Download before playing; at most every 250 ms; `total` 0 = unknown. |
| `{ type: "error", id, message }` | This song cannot be played: download refused (403/404/410, expired address: at once) or failed after two retries per 1 MB piece, or a `local` song whose file is missing. |
| `{ type: "prefetchError", id, message }` | The download in advance of a queued song failed. Not an `error`, because the page treats every `error` as the current song failing. |
| `{ type: "error", message }` | Playback failed. |
| `{ type: "dl", id, state: "progress", got, total }`, `{…state: "done", size }`, `{…state: "error" }` | Stored songs. |
| `{ type: "dlList", items: [{ id, size }] }` | |

### Producing the ipa

There is no Mac involved: push any branch, GitHub Actions builds it.

1. `git push`
2. `gh run watch <id> --exit-status` (find the id with `gh run list`)
3. `gh run download <id> -n YTMRemote-ipa -D _out`

The ipa is **unsigned**; sign and install it with your usual sideloading tool. When a build
fails, the compiler output is in the `build-log` artifact.

`ServerURL` in `project.yml` is no longer where the page comes from. It is only the base for
relative addresses in `load`/`dl` and the optional target for debug logs.

## Sound engine (surround, equaliser, loudness balancing)

Songs that are files on the phone (all songs in the standalone build) are played through
`AVAudioEngine`:

    file -> decode -> surround + make-up gain -> player node -> equaliser + loudness gain -> limiter -> output

The surround is computed by the app itself a few seconds ahead of the play position
(`App/Sound/Convolver.swift`); the equaliser, the loudness gain and the limiter work in real
time. The IO buffer size and the sample rate of the audio session are left to the system.

More `ytm` commands:

| cmd | fields | what it does |
| --- | --- | --- |
| `fx` | `key, surround, irL, irR, makeup` | `irL`/`irR`: base64 WAV (2 channels: left ear, right ear) for the left/right input; `null` when `surround` is false. `makeup` is a plain factor (1 = unchanged, not dB). Applies to the playing song within a moment and to all later ones; the same `key` again is ignored; remembered over restarts. |
| `eq` | `gains` (5 numbers, dB, ±12) | Low shelf 150 Hz, peaks at 400 / 1500 / 5000 Hz, high shelf 10 kHz. |
| `normTarget` | `on, target` | Loudness balancing: gain = target − measured loudness, kept within −12…+6 dB; −4 dB until the song is measured; 0 dB when off. |
| `diag` | | Answered with a `diag` event. |
| `config` | `pc` | Where the PC is (`http://host:port`, nothing after it). Used for the app's log upload and for addresses without a host; remembered. Until the first one, `ServerURL` from `project.yml`. |

More events:

| event | meaning |
| --- | --- |
| `{ type: "lufs", id, lufs }` | The song's loudness (ITU-R BS.1770, gated) has been measured. |
| `{ type: "fxUnavailable", id, message }` | The engine could not play this song; it plays through the plain player without the sound settings. |
| `{ type: "diag", text }` | The last 80 lines of the app's own log. |

`ytm-app://local/env/<id>.bin` is the song's envelope file (same format as the PC server's
`/api/env/<id>`), available once the song has been analysed; 404 before that.

The app keeps its own log (`Caches/diag.log`): commands, every download chunk, player and
engine events, everything sent to the page. When the PC is reachable it is also posted to
`<ServerURL>/api/debug` (kind `native`). On the phone itself: tap three times with two fingers
to read and copy it.

### Tests

`App/Sound` has no UI or engine code in it and also builds as the Swift package `SoundCore`.
`swift test` (run by CI before the app build, on a Mac) checks it against results made with
ffmpeg and the PC server; `node Tests/tools/make-fixtures.js` rebuilds those fixtures.

### Where songs come from

With the yt-dlp engine inside the app (see the next section) songs come from YouTube directly.
Without it, or when it cannot answer, they come from the user's own PC server
(`http://<pc>/media/<id>.m4a?mode=phone`, plain http, so App Transport Security stays open in
`project.yml`). The page sends `headers: {}` and `size: 0`; the app takes the length from the
server's answer. A song stored on the phone always plays from its file, with or without the PC.

## yt-dlp inside the app

iOS apps cannot start other programs. The PC ran `yt-dlp.exe`; the app now carries the same
thing as a library: a CPython interpreter, yt-dlp, and the JavaScriptCore framework that yt-dlp
needs to solve YouTube's player JavaScript (the `n` and `sig` challenges).

How a song is played:

1. The page still sends `{ cmd: "load", url: "/media/<id>.m4a?mode=phone" }`; the glue in
   `Web/standalone.js` turns that into `{ cmd: "loadSong", url: "ytdl://<id>" }` when
   `window.__ytmYtdlp` is true (the app injects it at document start when `PythonRuntime` is in
   the bundle).
2. `App/Ytdl.swift` runs `ytm_bridge.extract(id)` on the Python queue (`App/PythonBridge.swift`),
   which uses yt-dlp to find the AAC (itag 140) address, plus its size, length and headers.
3. `StreamCache` / `Downloads` download it in 1 MB ranges, exactly as they did from the PC.
4. If Python fails, `Ytdl` falls back to the PC's `/media/<id>.m4a?mode=phone`, so an app built
   this way still works with the old setup.

The JavaScript challenge: yt-dlp's own solver scripts (`yt-dlp-ejs`) are fed to a JSC context
through the C API (`Py/ytm_js.py`, ctypes - no PyObjC, no WebView, no extra process), and are
registered as a JS Challenge Provider by `Py/yt_dlp_plugins/extractor/ytm_jsc.py`. This works
with the screen locked, unlike a WKWebView.

### Building it

`tools/build-python.py` downloads and lays out everything (all versions pinned at the top of
the file):

```
vendor/Python.framework            linked and embedded (device slice)
PythonRuntime/lib/python3.14/      PYTHONHOME (stdlib without test/, lib-dynload, site-packages)
```

It must run **before** `xcodegen generate` (CI does it; locally, run it yourself):

```
python3 tools/build-python.py
xcodegen generate
```

The app is about 50 MB bigger: 38 MB runtime, 7.6 MB framework. On the phone the nested
binaries (`Python.framework`, `lib-dynload/*.so`) are signed by whatever signs the ipa - a
sideloading tool that only signs the main binary will leave the app unable to load Python.

### Commands and debugging

`{ cmd: "ytdlDiag" }` answers with a `ytdlDiag` event: the app log, the Python/yt-dlp/EJS/engine
versions and a one-shot solver test. The app also runs that test once at start and writes the
result into its own log as `python selftest: {...}` (two-finger triple tap, or the PC's
`debug.log`). yt-dlp's own lines appear in the app log as `extract <id> ...`.

| what | where |
| --- | --- |
| the interpreter | `App/PythonBridge.swift` (PyConfig, one serial queue) |
| the lookup | `App/Ytdl.swift` (`ytdl://<id>`, cached until the URL expires) |
| the Python side | `Py/ytm_bridge.py` (yt-dlp call), `Py/ytm_js.py` (JSC), `Py/yt_dlp_plugins/...` (provider) |

Not supported (and not needed for playback): ffmpeg post-processing, merging separate audio
and video, `--exec`, and any extractor that needs an external program. Only a single audio
stream is looked up; the app's own engine does the sound.

## Mixing between songs

With `{ cmd: "mix", on: true }` the next song comes in over the end of the current one and
simply continues as the current song. The app decides everything itself from the stored queue
and from what the PC found out about each song (`mix` objects on `loadSong` / `queue` items, or
`{ cmd: "mixInfo", id, mix }`), so it also works with the screen locked.

- `App/Sound/MixPlanner.swift` decides whether and how (a short touch, or beat on beat when
  both tempos are sure, agree within 0.5 % and the current song has no ending of its own).
- `App/Sound/MixShaper.swift` computes the level curves and the bass hand-over into the two
  songs' samples.
- `App/SoundEngine.swift` has two player paths, each with its own surround state and loudness
  gain; equaliser and limiter come after their sum. The incoming song's player is started at
  an exact moment of the audio clock, worked out from where the outgoing one is.

Events: `{ type: "mix", stage: "start" | "done" | "cancel", from, to, overlap, synced, reason? }`.
`advanced` is sent at the end of the overlap (right after `done`); until then `time` reports the
outgoing song. No mix (the ordinary change of song) when mixing is off, an analysis is missing,
the next song is not on the phone yet, the current song is shorter than 30 s, or the overlap
would begin before the middle of the song.

`node Tests/tools/make-mix-fixtures.js` holds the same rules in JavaScript and writes the plans
for 11 real songs that the Swift planner is tested against.

## Music light (0.9, 0.9.1)

`{ cmd: "light", on, style: "soft"|"beat"|"colour", level: 0.1-1, floor: 0-0.5, hue: -1|0-360,
offsetMs: -300..500 }` switches the car's ambient light to follow the music; the app answers
`{ type: "light", state: "off"|"searching"|"connecting"|"connected"|"error", name, detail }`.
Off, nothing of it runs and Bluetooth is not started. The settings are kept, and with the light
left on the app connects at start (the device used last time, otherwise the first one that
advertises AF30/FFF0/FEE7) and reconnects after a drop (1 ... 30 s back-off). The
`bluetooth-central` background mode keeps it working with the screen locked.

- Each song gets a light envelope (`Caches/lightenv/<id>.bin`: bass 40-150 Hz, above 1 kHz and
  onsets at 50 frames a second, each normalised to its 95th percentile), made by the song
  analysis while the light is on.
- 25 times a second (own queue) the envelope is looked up at the heard position (player position
  minus `AVAudioSession.outputLatency` minus the user's offset); during a mix both songs count,
  weighted by their mix levels. `LightMapper` turns that into a colour: a music curve `v` from
  the bass (attack/release, at most 0.25 change per frame, short whiter lifts on onsets), output
  `level × (floor + (1 − floor) × v^2.2)` (floor and level in visible terms: floor 0.12 is
  31/255 in silence), a hue that drifts one turn in two minutes unless fixed. A colour is sent
  only when a channel moved by 2 or more. The newest colour always wins; nothing waits.
- On connect only `<0A01>` is sent (the controller's own state, from the 4E frame). Nothing
  else until music plays (`LightIdle`). Music starts: `<0701>` (only if it was off), `<0400>`
  (only if the mode byte is not 00), `<020009>`, then music. Music stopped for 3 s (shorter
  pauses, seeks, song changes and mixes are bridged): 1 s fade in RGB to the own colour, then
  the own overall brightness and the own colour last, then nothing. Off or app end while the
  light is held: the same restore at once. The controller keeps a colour in its memory only
  a few seconds after changes stop (seen in the car), so the music itself does not wear it.
- Log lines start with `light` (connect, restore, envelope references, a rate summary every 30 s).
- Without an envelope yet (the analysis takes a few seconds), the light rests at the floor;
  there is no live analysis of the output.

### Song colours (0.10)

`colourMode: "song"|"drift"|"fixed"` in `{cmd:"light"}` (missing: from `hue`, -1 = drift) and
`{cmd:"lightArt", id, url}` for each song's cover. In "song" mode every song has its own colour
(`LightPalette`): the cover is downloaded (only while the light is on; `Caches/lightart`, last
50), drawn at 48 × 48, near-black, near-white and grey pixels left out, the rest binned by hue
(24 bins weighted by S × V): primary = strongest group, secondary = strongest group 40° or more
away (else the primary + 35°), saturation at least 0.75. Covers with under 8 % colourful pixels,
covers that fail and songs without a cover get a colour from their sound (ratio of upper range
to bass: dark songs purple to orange, bright songs cyan to blue). Within a song, loud sections
(8 s energy above the song's 75th percentile) glide in 2 s half way to the secondary colour at
full saturation. Song changes glide in about 3 s; during a mix the songs' colours blend by their
levels; a song whose colour is not known yet keeps the previous colour. One log line per song:
`light palette <id>: primary #rrggbb secondary #rrggbb from cover|audio (vivid N %)`.

`saturation: 0-1` in `{cmd:"light"}` (0.10.1, default 1) multiplies the final saturation in every
colour mode, after the cover floor, section boost and upper-range nudge: 1 = unchanged, 0 = white
light at the same brightness. Onset whitening is added on top as before.

0.10.2: the secondary colour is a real second colour when the cover has one (a group 40° or
more from the primary with at least 35 % of its weight, best weight × saturation); otherwise the
cover's own neighbouring colour (of the pixels within 60° of the primary, the heavier side's mean
hue, 12-40° away); for a single flat colour the primary + 15° (− 15° if that is yellow-green).
`intensity: 0-1` in `{cmd:"light"}` (default 1) scales everything the
music drives: brightness `level × lerp(1, floor + (1 − floor) × v^2.2, k)`, the loud-section
shift, the upper-range nudge and desaturation, and the onset lift. 0 = steady brightness at
`level`, only the song colours.


## Now Playing after the app moves on by itself (0.10.3)

After a mix hand-over or a natural end the app shows the next song at once. The page still
describes its old song for a moment (its `playing` handler sends `meta` and `dur`); for 15 s
after such a change a `meta` with the previous title and artist, or a `dur` equal to the previous
length, is dropped (`NowPlayingGuard`). `meta` and `dur` may carry `id`: then only the song being
heard is taken.

The test screen has a section 「幻彩燈條（流水）」 for the strip effects (`<1E09>` chase, `<1E03>` flow, `<1E0B>` meteor, `<1E19>` ping-pong, `<1E0C>`/`<1E0E>` trails, `<1E18>` single-colour sync to restore), speed `<0B01>`-`<0B05>`, direction `<0C00>`/`<0C01>` and a re-send of the last mode. While the music light runs, these pause it until the test screen closes; the next take-over then always sends the single-colour command (0.10.5).

0.10.6: a strip effect is never left running. Taking over sends `<1E18>` (Sync RGB) when the state frame (byte 2) shows another effect, and giving back restores it. The test screen notes the state when it opens (asking `<0A01>` if none is known) and, if any strip command was sent, puts the effect and its speed (byte 13, only 01-05) back when it closes; unknown state means `<1E18>`. The direction is not in the state frame and is left alone.

`zones: "all"|"split"` (0.10.6): split = upper lights (zone 1, `<10rrggbb>`) follow the upper range with a softer curve (60 ms / 400 ms, no onset lift) in the base colour; the footwell (zone 2, `<09rrggbb>`) follows the bass with the style's curve and onset lifts in the song's secondary colour (drift/fixed: the same colour as the upper lights). Each zone has its own send threshold; a busy link takes the larger change first. Idle restore still uses `<06rrggbb>`: the state frame has one colour only.

## CarPlay stays on Now Playing (0.10.8)

The system is told "playing" or "paused" only through `PlaybackReport`: song changes, download waits, seeks, effect changes and mix hand-overs keep rate 1 and `playbackState .playing`. A pause from the page is held 1.5 s (the page pauses before every song change); lock screen / CarPlay / interruption / lost headphones are reported at once. The audio session is activated once (again only after an interruption or media reset), and the output keeps running silently while the next song downloads. Every change is logged as `now playing: state ...` / `audio session: activated ...`.
