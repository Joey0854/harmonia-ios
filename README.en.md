# Harmonia

[繁體中文](README.md)

An iPhone music player for YouTube Music. It plays by itself (no PC needed), keeps playing with the
screen off, and shows up on the lock screen and CarPlay's Now Playing.

> **Platforms:** iPhone (iOS 16 or later) only. **There is no Android version (no APK).** See
> [Android](#android).
>
> **Read the [important notes](#️-important-notes) first: turn off the car's original surround sound.**

## Features

- Browse and search YouTube Music; sign in (optional) for your own home feed, likes and playlists.
- Plays by itself: [yt-dlp](https://github.com/yt-dlp/yt-dlp) runs inside the app.
- Background playback, lock screen, Control Centre and CarPlay Now Playing.
- Surround effect (headphone impulse responses), 5-band equaliser, loudness balancing.
- Automatic mixing between songs.
- Download songs to the phone; play history on the phone, and when you are signed in, plays are also sent to your YouTube Music history.
- Optional: drives a car ambient-light controller over Bluetooth LE from the music (needs a compatible controller).

## ⚠️ Important notes

> [!IMPORTANT]
> **Turn off the car's original surround sound first.**
> Harmonia makes its own surround (headphone impulse responses) and equaliser. If the car stereo (or the headphones, or the phone) also has surround, sound field, 3D, Live, Dolby or spatial audio switched on, the sound is processed twice and can turn dull, smeared, hollow or distorted.
>
> - **Car stereo:** switch off the factory surround / sound field / virtual stage, and set its equaliser to flat (Off).
> - **Headphones and phone:** switch off the headphones' own enhancement and the phone's Spatial Audio.
> - Turn the volume down before you start, then raise it slowly.
> - The app's own **Surround** and **Equaliser & loudness** are yours to adjust; to listen without surround, switch **Surround** off in the player.

> [!WARNING]
> **Expires after 7 days.** An app sideloaded with a free Apple ID stops opening after 7 days and must be installed again (a paid developer account lasts a year).

> [!WARNING]
> **Terms of service and stability.** The app reads audio from YouTube with yt-dlp. That may be against YouTube's Terms of Service, and playback can stop working for a while when YouTube changes. Personal use only, at your own risk.

> [!NOTE]
> - **iPhone only.** There is no Android version (no APK).
> - **Sign in only on Google's own page.** Never type your account or password anywhere else.
> - **The ambient light is optional.** It only fits compatible car Bluetooth LE controllers; use it at your own risk, and ignore it if you do not need it.
> - **Check a log before you post it.** It lists the song ids and titles you played.
> - **The first song after each start** needs a few seconds to be looked up. That is normal.

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

## User guide

### The screen

Four tabs at the bottom: **Home** (首頁), **Search** (搜尋), **Downloads** (下載), **History** (紀錄). The gear opens **Settings**.

| Tab | What it does |
| --- | --- |
| Home | YouTube Music's recommendations. Pull down to refresh; a message says how many new items came in, or that nothing changed |
| Search | Songs, albums, artists |
| Downloads | Songs stored on the phone; they play offline; play all or delete one by one |
| History | Play history, with two pages: "This phone" and "YouTube Music" |

### Playing

1. Tap any song. It joins the queue and the next one plays by itself.
2. The full player has the seek bar, previous / next, shuffle and repeat (off / all / one).
3. Playback continues with the screen off, in other apps, and on the lock screen or CarPlay Now Playing.
4. The first song after the app opens needs a few seconds to be looked up.

### Sound

In the player: **Surround** on/off and style, a **5-band equaliser** (150 / 400 / 1500 / 5000 / 10000 Hz) with loudness balancing, and **automatic mixing** between songs. The analysis runs entirely on the phone (the same method the PC used): it finds each song's tempo, beat positions, main part and ending, mixes beat on beat when the tempos agree, and otherwise lets the next song come in as the ending fades. The next song must be downloaded first, so very short songs are not mixed. **Picture and sound alignment** (Settings): if the backdrop light or the lyrics are behind the sound, drag left (earlier); if ahead, drag right (later); headphones and car are remembered separately.

### Downloads

Tap **Download** (下載) in the player to keep a song on the phone; manage them on the Downloads tab.

### Signing in (optional)

Settings > **YouTube Music account** > Sign in. When nobody is signed in, or the sign-in has expired, the app shows a sign-in prompt (you can choose Later; for "not signed in" also Do not remind me). Then the home feed is your own, the heart in the player shows and changes your like, songs can be added to playlists, and songs you heard for 30 seconds (half of a short one) are also written to your YouTube Music history (it may take a few minutes to show). You type your Google credentials only on Google's own page.

### Play history

"This phone" is stored only on the phone (up to 500 songs; a song counts after 30 s). **✕** on a row removes one entry; **Clear history** (清除紀錄) removes all after a second tap to confirm. "YouTube Music" shows your account's history and is read-only.

### Ambient light (optional)

Settings > **Ambient light** (氛圍燈; folded by default, tap to open). Needs a compatible car controller (Bluetooth LE); Bluetooth permission is asked only when you switch it on.

### Diagnostics

Settings > **Diagnostics** (診斷) shows the current state and the latest log. To send the whole log, tap **three times with two fingers** and use **Share** or **Copy**. Read it before posting.

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
