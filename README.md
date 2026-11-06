# HeSuVi Music

[繁體中文](README.zh-TW.md)

An iPhone music player for YouTube Music. It plays by itself (no PC needed), keeps playing with the
screen off, and shows up on the lock screen and CarPlay's Now Playing.

> **Platforms:** iPhone (iOS 16 or later) only. **There is no Android version (no APK).** See
> [Android](#android).

## Features

- Browse and search YouTube Music; sign in (optional) for your own home feed, likes and playlists.
- Plays by itself: [yt-dlp](https://github.com/yt-dlp/yt-dlp) runs inside the app.
- Background playback, lock screen, Control Centre and CarPlay Now Playing.
- Surround effect (headphone impulse responses), 5-band equaliser, loudness balancing.
- Automatic mixing between songs.
- Download songs to the phone; play history on the phone, and when you are signed in, plays are also sent to your YouTube Music history.
- Optional: drives a car ambient-light controller over Bluetooth LE from the music (needs a compatible controller).

## Install on iPhone

The app is **not** on the App Store. You install the `.ipa` from the [Releases](../../releases)
page with a sideloading tool, using your own Apple ID.

**You need:** an iPhone on iOS 16 or later, a USB cable, a Windows PC or a Mac, and an Apple ID.
A free Apple ID works, but the app then **expires after 7 days** and must be installed again
(a paid developer account lasts a year).

### Option A - Sideloadly (Windows or macOS)

1. Install **iTunes** and **iCloud for Windows** from Apple's website (the Microsoft Store versions do
   not work with Sideloadly). On a Mac nothing extra is needed.
2. Install [Sideloadly](https://sideloadly.io/).
3. Download `YTMRemote.ipa` from the latest [release](../../releases/latest).
4. Connect the iPhone with the cable and tap **Trust** on the phone.
5. On the iPhone turn on **Developer Mode**: Settings > Privacy & Security > Developer Mode
   (the phone restarts). If you do not see it yet, do step 6 first and come back.
6. Open Sideloadly, drag the `.ipa` into it, choose your iPhone, type your Apple ID, press **Start** and
   enter your password when it asks. Type your credentials only into Sideloadly's own window.
7. On the iPhone: Settings > General > **VPN & Device Management** > your Apple ID > **Trust**.
8. Open the app.

### Option B - AltStore (Windows or macOS)

1. Install [AltServer](https://altstore.io/) on the computer and use it to install **AltStore** on the
   iPhone (follow AltStore's own guide).
2. Send `YTMRemote.ipa` to the iPhone (AirDrop, Files, or download it in Safari).
3. In AltStore open **My Apps**, tap **+** and pick the `.ipa`.
4. Do steps 5 and 7 from Option A (Developer Mode, Trust).
5. AltStore refreshes the app in the background while AltServer is running on your computer.

### First start

1. Pick a song from the home page. The first song after the app opens needs a few seconds to be looked up.
2. Optional: Settings > **YouTube Music account** > Sign in, to get your own home feed, likes and playlists.
3. Optional: allow Bluetooth only if you use the ambient light.

### Problems

| Symptom | What to do |
| --- | --- |
| "Untrusted developer" | Settings > General > VPN & Device Management > Trust |
| The app closes right away, or shows no Developer Mode | Turn on Developer Mode (step 5), then restart the phone |
| The app stopped opening after about a week | Free Apple IDs expire after 7 days: install it again |
| Sideloadly cannot find the iPhone | Reinstall iTunes (Apple's website version), unlock the phone, tap Trust |
| A song does not play | Wait about 10 seconds for the first lookup; update to the newest release (YouTube changes often) |

### Sending a log when you ask for help

Tap the screen **three times with two fingers**: a log screen opens. **Copy** or **Share** puts it
into a message, mail or file. Read it before you post it; it lists song ids and titles you played.

## Android

There is **no Android app and no APK**. The app uses iOS-only parts (the system audio engine,
CarPlay, Bluetooth LE and an embedded Python runtime), so it cannot be repackaged. An Android
version would be a separate project; contributions are welcome.

## Build it yourself

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md). CI builds an unsigned ipa on every push; pushing a
tag such as `v1.0.0` publishes it as a release.

## Legal

MIT licence, see [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The app is not
affiliated with YouTube, Google or Apple. Reading audio from YouTube may be against YouTube's Terms of
Service; use it at your own risk and for personal use.
