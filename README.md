# Lyric Box

**English** · [Tiếng Việt](README.vi.md)

A macOS app that turns your desktop into a **COTODAMA Lyric Speaker**-style lyric display: when you play music in **Spotify** (the desktop app), synced lyrics appear as kinetic typography right on your desktop, behind all your windows.

- No Spotify login: the app reads what's playing from the Spotify app on your Mac.
- Synced lyrics come from [LRCLIB](https://lrclib.net) and are cached.
- Lives in the menu bar only, with no on-screen controls.
- Playing → lyrics fade in. Paused or stopped → they fade out and your normal wallpaper comes back.

Written in Swift + Core Animation: 4.8 MB app (2.9 MB dmg, mostly the bundled fonts), ~50 MB RAM, a few % CPU at most for the app itself, runs on Apple Silicon and Intel (macOS 13+).

## Install

Download **[Lyric-Box-0.2.0.dmg](https://github.com/trinknx/lyric-box/releases/latest)** from Releases.

1. Open the `.dmg` and drag **Lyric Box** into **Applications**.
2. First launch: macOS blocks it because the app isn't signed by Apple. Go to **System Settings → Privacy & Security** and click **Open Anyway**. (Or: `xattr -dr com.apple.quarantine "/Applications/Lyric Box.app"`)
3. Play music in the **Spotify app** (Free or Premium both work). When macOS asks *"Lyric Box wants to control Spotify"*, click **OK**.
4. Done: lyrics show up on your desktop. The crescent icon in the menu bar is the settings menu.

## Build

```bash
cd native
./scripts/build.sh          # → native/build/Lyric Box.app
./scripts/build.sh --dmg    # + native/build/Lyric Box.dmg
open "build/Lyric Box.app"
```

Requires Xcode (or the Command Line Tools) with Swift 6.

The first time music plays, macOS asks *"Lyric Box wants to control Spotify"*; click **OK**.
If you clicked Don't Allow: **System Settings → Privacy & Security → Automation → Lyric Box**, turn on Spotify. If Lyric Box isn't in that list:

```bash
tccutil reset AppleEvents io.bamboosoft.lyricbox
```

Try it without Spotify:

```bash
LYRICBOX_PREVIEW=1 "native/build/Lyric Box.app/Contents/MacOS/LyricBox"          # fake song with lyrics
LYRICBOX_PREVIEW=nolyrics "native/build/Lyric Box.app/Contents/MacOS/LyricBox"   # fake song without lyrics
```

Add `LYRICBOX_SNAPSHOT=/some/dir` and the app renders 10 PNG snapshots of the lyric screen offscreen (CARenderer, so 3D is included) over ~40 seconds, then quits. Handy for checking the look without screen-recording permission.

**Sharing it:** the build is only ad-hoc signed, so the first launch needs **System Settings → Privacy & Security → Open Anyway** (or the `xattr` command above). To open without any warning, the app has to be signed and notarized with an Apple Developer ID.

### How it works

- **Reading Spotify:** listens for the `com.spotify.client.PlaybackStateChanged` notification Spotify broadcasts on track change / play / pause, and re-reads the position every 1.5 s with an in-process AppleScript (no `osascript` process).
- **Drawing:** every letter is a `CALayer` drawn with Core Text. The camera is 3 nested layers (rotate → zoom → pan). All motion, including the background graphics, is Core Animation run by macOS's render server; the app's own code only checks lyric timing ~20 times a second.
- **Fonts:** bundled Noto Serif and Noto Sans variable fonts (SIL Open Font License, `native/Resources/Fonts/OFL.txt`); weight and width axes give the regular, bold and condensed-black looks. Japanese falls back to Hiragino Mincho / Hiragino Sans. The system fonts (New York / SF Pro) are an alternative in the menu.
- **Window:** one level below the desktop (`desktopWindow − 1`), on every Space, click-through.

### Layout

```
native/Sources/LyricBox/
  AppDelegate.swift     wallpaper windows, menu bar, settings, hotkeys, snapshots
  SpotifyMonitor.swift  reads Spotify (notifications + AppleScript)
  LyricsStore.swift     fetches + caches lyrics from LRCLIB
  LRC.swift             parses LRC files, estimates per-word timing
  Scene.swift           background, picks the line for the current time, poster, fade in/out
  Flow.swift            COTODAMA canvas: block layout, camera, letter-by-letter reveal
  Constellation.swift   constellation style: stars, connecting lines, twinkling sky
  Ambient.swift         4 graphics (rings, waves, dot grid, sunburst)
  HotKeys.swift         ⌥⌘[ / ⌥⌘]
```

## Menu bar menu

The app's menus are in Vietnamese; the original labels are shown in brackets.

- **Show lyrics on the desktop** (*Hiện lời trên màn hình nền*): on/off
- **Text style** (*Kiểu chữ*): COTODAMA automatic per song / calm / medium / energetic / constellation (*Chòm sao*)
- **Font** (*Phông chữ*): Noto Serif / Sans (as COTODAMA uses for Latin and Vietnamese) or the system fonts
- **Background** (*Nền*): Dark · Light (clear acrylic) · Transparent with white text · Transparent with black text (keeps your own wallpaper)
- **Screen** (*Màn hình*): main screen, a specific screen, or all screens
- **Lyric offset** (*Lệch lời*): `⌥⌘]` earlier · `⌥⌘[` later (0.25 s per step)
- **Search lyrics again** (*Tìm lại lời bài này*) / **Pick an .lrc file for this song…** (*Chọn file .lrc cho bài này…*) when LRCLIB has wrong lyrics or none
- **Open at login** (*Mở cùng macOS*)

## Effects (COTODAMA-style)

- Lyrics are **spelled out letter by letter** as they're sung, left-aligned, in mixed sizes.
- **Continuous canvas:** the previous line stays, dimmed; the camera pans, zooms and **turns 90°** to the new line.
- Upcoming words sometimes appear faintly first, and short phrases sometimes sit in an inverted label box.
- Mood from how fast the words come: calm (thin serif, slow) · medium · energetic (bold uppercase, fast).
- **Constellation** (*Chòm sao*), in 3D: every word is a star at its own depth, so near words look bigger. The line's stars first show faintly so you see the shape; as each word is sung its star lights up, a line grows to it through 3D space from the previous star, and the letters are spelled out beside it. The whole sky slowly sways as if dragged by a finger, so near words move more than far ones (parallax), while every word keeps facing you. New constellations come out of the distance; older ones recede and dim. In automatic mode about half of the calm songs use it.
- Songs without lyrics: a typographic "poster" of title → artist → album (changing every 8 s) over moving graphics (rings, waves, dot grid, sunburst; one per song). Instrumental breaks in songs with lyrics show these graphics too.

Limitation: Spotify doesn't expose its audio stream, so the graphics don't follow the actual beat.

`legacy-web/` is the first browser-based player (with playback controls, audio/LRC file loading and 7 text styles), kept for reference.
