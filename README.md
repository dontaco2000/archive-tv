<p align="center"><img src="docs/branding/banner.png" alt="Archive TV: retro satellite TV from the Internet Archive" width="720"></p>

<p align="center">
<a href="https://github.com/dontaco2000/archive-tv/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/dontaco2000/archive-tv?color=f87d28&label=release"></a>
<a href="LICENSE"><img alt="License: GPL-3.0" src="https://img.shields.io/badge/license-GPL--3.0-3fa7a0"></a>
<img alt="Platforms" src="https://img.shields.io/badge/platforms-Windows%20%7C%20Fire%20TV%20%7C%20Android-5a3a22">
</p>

# Archive TV

A retro "satellite TV" app. It plays video from the [Internet Archive](https://archive.org) as live, clock-synced channels with an on-screen guide, a menu, and a remote control. Turn it on and something is always "on", just like a TV.

- **Windows** (primary) and **Android** (Fire TV, Android TV, phones and tablets).
- Built with Flutter, media_kit and libmpv. A pure-Dart core (`core/`) handles channels, pools and scheduling; the app is in `player/`.

## Features

### Live channels
- **61 channels**, each themed, grouped by number: 2-9 Kids & Animation, 10-19 Movies, 20-28 Comedy & Variety, 30-39 Drama & Classic TV, 40-47 News & Docs, 50-59 Music & Sports, 60-69 World & Lifestyle (Champs 48 and Bowl 49 sit just before the Music & Sports block).
- **Clock-synced**: every channel has a schedule built from Internet Archive items, and what is "on" depends on the time of day, like real TV. Tune in mid-show; it is the same moment for everyone with the same channel data.
- **Programming blocks**: serial blocks (prime-time shows run in order), themed time blocks (for example Saturday-morning cartoons, Friday-night creature features, weekend sports), and rare-item scheduling (a big event airs once a day or as a Sunday marathon).
- A "BUILDING..." notice while a channel's pool is first built, a "STAND BY..." card between programs, and NO SIGNAL when a stream can't be reached. Missing or deleted files are detected, retried weekly, and dropped for good after repeated failures.
- Programme titles are cleaned up (track numbers, release tags and tape ids removed) and filled in from Internet Archive metadata when file names are meaningless.

### Guide, menu and On Demand
- **On-screen guide**: three hours in 15-minute columns, scrollable through the end of the saved week. Select a program to tune in. Repetitive content is grouped into readable blocks ("Marathon", "Shorts", "More Commercials").
- **Menu** with a live clock, organised into Channels & Guide, Picture & Sound, Weather, Remote, Sleep & Tools, About & Credits and Parental controls.
- **On Demand**: browse Genre > Show > Episode, or search by typing. Rated content is shown with an R tag (hidden if parental controls turn adult mode off). There is no channel level.
- **Favorites**, last-channel recall, and resume on the channel you were watching.

### Picture and sound
- **Auto picture crop** (Windows): detects baked-in black bars and crops them. Choose Auto, Fill or Off (P key).
- **Volume leveling** (Windows): off, normal or strong, so loud and quiet programs sit closer together.
- **A/V sync** nudge keys per item, for files whose audio is off.
- **Window**: size, position and fullscreen are remembered; the windowed picture stays 4:3.

### Weather channel
- **Cumulus** (channel 41) shows four WeatherStar-style screens (Now, Hourly, Today, Extended) with weather alerts, over smooth-jazz music from the Archive. Set your location in the menu (the default is Hattiesburg, MS). Data: Open-Meteo and the National Weather Service.
- A WeatherStar 4000+ web view is available as an option on Windows.

### Control and safety
- **Sleep timer** (15 to 120 minutes, with a fade and a "Going to sleep" card; any key cancels).
- **Parental controls (PIN)**: lock channels, and turn the night-only adult mode on or off.
- **Night-only adult mode**: R-rated and similar content (strong language, violence, crude humor, MMA and so on) airs only from 22:00 to 05:00. It is not about explicit content: sexually explicit material is excluded entirely.
- **Wrong channel** key (X): report a program that doesn't belong on a channel; it is blocked on that channel only.
- Crash log and "last error" in the menu, to help bug reports.

### Remotes
- **TV remote / keyboard**:

| Action | Remote | Keyboard (Windows) |
|---|---|---|
| Channel up / down | Up / Down, or FF / Rew | Up / Down |
| Volume | Left / Right | Left / Right |
| Guide (then tune) | Select | Enter |
| Menu | Menu | M |
| Back / close overlay | Back | Esc |
| Mute | Play / Pause | Space or U |
| Fullscreen | | Alt+Enter |
| Last channel | | L |
| Sleep timer | | T |
| Wrong channel | | X |
| Picture mode | | P |
| Remote window | | R |
| A/V sync | | `[` `]` and `\` |

- **Visual remote window** (Windows): a small on-screen remote beside the TV, with Power, Mute, volume, channel, guide and more. Open it with R or from the menu.
- **Phone remote**: scan the QR code in the menu (Remote > Phone remote) and control Archive TV from any phone browser on the same Wi-Fi, no app needed (Windows and Fire TV / Android TV). Off by default, LAN only, protected by a token in the QR code. An optional Wi-Fi remote on Windows can also use a PIN.
- **Gamepad** support on Windows (XInput) and Android.
- **Phone and tablet layout**: a 4:3 video box with a built-in remote; swipe up/down for channels, left/right for volume.

### Plex
- The companion project [archive-tv-server](https://github.com/dontaco2000/archive-tv-server) turns the same channels into a Plex Live TV tuner with a guide, a weather channel and guide music.

## Content disclaimer

**We are not responsible for the content.** All video and audio comes from the Internet Archive (archive.org) and its uploaders. Archive TV only indexes and plays it. Archive TV is **not affiliated with or endorsed by the Internet Archive.** Some channels (such as Headliner, Teaser, Haunt and Bedlam) and the night-time blocks on many others can include mature content (strong language, violence, crude humor, sports like MMA); parental controls can lock them. The weather page is third-party (WeatherStar 4000+ by Matt Walsh, MIT) and weather data comes from Open-Meteo and the National Weather Service.

## Install

**Latest release: [github.com/dontaco2000/archive-tv/releases/latest](https://github.com/dontaco2000/archive-tv/releases/latest)** (always the newest version, with release notes).

**Windows**

1. Download [`ArchiveTV-Setup.exe`](https://github.com/dontaco2000/archive-tv/releases/latest/download/ArchiveTV-Setup.exe) and run it (per-user install, no admin needed).
2. Windows SmartScreen may warn that the installer is unsigned. Click **More info**, then **Run anyway**.
3. The Microsoft WebView2 runtime is downloaded automatically if your PC doesn't have it.
4. An internet connection is required (every channel streams from archive.org). Channels build themselves on first run (a channel shows "BUILDING..." until ready) and refresh automatically every midnight. After an update you can press **Refresh channels** in the menu to pick up new content right away.

**Android**

The APKs are signed with a debug key and must be sideloaded (they are not on any store). Pick the right file:

| Device | APK |
|---|---|
| Fire TV Stick Lite, most Fire TV / Android TV boxes, older phones | [`ArchiveTV-32bit.apk`](https://github.com/dontaco2000/archive-tv/releases/latest/download/ArchiveTV-32bit.apk) |
| Modern phones and tablets (64-bit) | [`ArchiveTV-64bit.apk`](https://github.com/dontaco2000/archive-tv/releases/latest/download/ArchiveTV-64bit.apk) |

On a phone or tablet the video is a 4:3 box with an on-screen remote below or beside it. On a TV, use the remote's D-pad.

## Testing status

- Windows: tested on real hardware.
- Fire Stick Lite: the 32-bit APK, TV layout, tested on a real device.
- Phone remote (QR code, browser page): tested on a real iPhone against the Windows app; the Fire TV side of it is untested on a real network. Windows may ask to allow the app on private networks the first time you turn it on.
- **The phone and tablet version (touch layout, 64-bit APK) was only tested in an emulator (BlueStacks), not on real phones or tablets.** Expect rough edges.

## Known limits

- Android has no automatic black-bar cropping and no volume leveling (both need a fuller libmpv build).
- Content comes and goes on the Internet Archive; Archive TV skips items that can't be reached and re-checks them weekly.

## Build from source

Requires Flutter (see `player/pubspec.yaml` for the SDK version), and Visual Studio C++ build tools for Windows or the Android SDK and JDK 21 for Android.

```
cd core && dart test
cd ../player && flutter test
flutter build windows --release
flutter build apk --release --target-platform android-arm     # 32-bit
flutter build apk --release --target-platform android-arm64   # 64-bit
```

The Windows build downloads a full-featured `libmpv-2.dll` on first build (`player/windows/fetch_libmpv.ps1`, checksum verified). Channels are defined in `player/assets/channels.json`.

## Porting and forks

Archive TV is licensed under the **GNU General Public License v3.0** (see `LICENSE`). If you port it to another platform or modify it, the GPL requires that you share your source under the same license. We ask that you publish your port as a **fork of this project** so improvements stay connected.

## Credits

- [Internet Archive](https://archive.org): all video and audio.
- [WeatherStar 4000+](https://weatherstar.netbymatt.com) by Matt Walsh (MIT): the weather channel page.
- [Open-Meteo](https://open-meteo.com) and the [National Weather Service](https://www.weather.gov): weather data.
- [media_kit](https://github.com/media-kit/media-kit) and [mpv](https://mpv.io) / FFmpeg: playback.
- [Flutter](https://flutter.dev), [flutter_inappwebview](https://inappwebview.dev) and Microsoft WebView2.
