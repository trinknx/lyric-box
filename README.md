# Lyric Box

**English** · [Tiếng Việt](README.vi.md)

A macOS app that turns your desktop into a **COTODAMA Lyric Speaker**-style lyric display: when you play music in **Spotify** (the desktop app), synced lyrics appear as kinetic typography right on your desktop, behind all your windows.

- No Spotify login: the app reads what's playing from the Spotify app on your Mac.
- Synced lyrics come from [LRCLIB](https://lrclib.net) and are cached; they follow Spotify's playback automatically. Songs without synced lyrics on LRCLIB show the song title and moving graphics instead. (Spotify's own lyrics come from Musixmatch and aren't freely available, so some songs have lyrics in Spotify but not here.)
- Lives in the menu bar only, with no on-screen controls.
- Playing → lyrics fade in. Paused or stopped → they fade out and your normal wallpaper comes back.

Written in Swift + Core Animation: 4.8 MB app (2.9 MB dmg, mostly the bundled fonts), ~50 MB RAM, a few % CPU at most for the app itself, runs on Apple Silicon and Intel (macOS 13+).

## Install

Download **[Lyric-Box-0.4.0.dmg](https://github.com/trinknx/lyric-box/releases/latest)** from Releases.

1. Open the `.dmg` and drag **Lyric Box** into **Applications**.
2. First launch: macOS blocks it because the app isn't signed by Apple. Go to **System Settings → Privacy & Security** and click **Open Anyway**. (Or: `xattr -dr com.apple.quarantine "/Applications/Lyric Box.app"`)
3. Play music in the **Spotify app** (Free or Premium both work). When macOS asks *"Lyric Box wants to control Spotify"*, click **OK**, and allow *audio from other apps* if you want the effects to follow the beat.
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
- **Window:** one level below the desktop (`desktopWindow − 1`), on every Space, click-through. Screen-saver mode uses separate windows at the screen-saver level. The real macOS screen saver (`Lyric Box.saver`) runs inside Apple's sandboxed screen-saver host, which can't talk to Spotify, so the app sends it the song, position, lyrics, beats and settings as distributed notifications (JSON in the notification object) while it's running.
- **Beat sync** (macOS 14.2+): a Core Audio process tap listens to Spotify's processes only, through a private aggregate device. The samples are reduced on the audio thread to a bass-energy envelope; a beat is a sharp jump above its recent average, and the tempo comes from autocorrelating the onset envelope over the last ~6 s (shown only once it's stable). Beats are delivered delayed by the output device latency, so the effect lands when you hear it. Nothing is recorded or stored. This needs the "audio from other apps" permission, which macOS asks for the first time.

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
  WordZoom.swift        rap style: one word at a time
  AudioTap.swift        Spotify audio tap + beat / tempo detection
  Saver.swift           screen-saver mode
  SaverBridge.swift     app → Lyric Box.saver messages
native/Saver/           the macOS screen saver bundle (LyricBoxSaverView, same engine)
  HotKeys.swift         ⌥⌘[ / ⌥⌘]
```

## Menu bar menu

- **Show Lyrics on Desktop**: on/off
- **Style**: Automatic (per song) / Calm / Medium / Energetic / Constellation (3D) / Rap / Glitch
- **Font**: Noto Serif / Sans (what COTODAMA uses for Latin and Vietnamese) or the system fonts
- **Beat Sync**: Off / Soft (text and glow pulse on the beat) / Strong (the line also bounces); optional *Flash on Strong Beats* for energetic songs; shows the detected BPM
- **Screen Saver**:
  - Lyric Box's own mode: Off / after 2, 5 or 10 minutes idle, *Only While Spotify Plays* (on by default), *Preview Now*. The lyrics cover every screen in front of all windows; moving the mouse or pressing a key brings the desktop back (the key isn't passed to the app underneath). The display is kept awake while it shows and music plays. Transparent backgrounds switch to the dark one here.
  - **Install as Mac Screen Saver…**: copies `Lyric Box.saver` to `~/Library/Screen Savers` and opens Screen Saver settings; pick **Lyric Box** there. The lyrics then also show when macOS's own screen saver runs, including while the Mac is locked. Keep the Lyric Box app running: it feeds the saver what's playing. Run it again after updating the app.
  - **Start Screen Saver When Mac Locks** (on by default, needs the Mac screen saver installed): when you lock the Mac (`⌃⌘Q`) while Spotify plays, the screen saver starts right away instead of after macOS's idle timeout, so the lyrics keep going on the locked screen. Apps can't draw on the unlock prompt itself.
- **Background**: Dark · Light (clear acrylic) · Transparent — white text · Transparent — black text (the transparent ones keep your own wallpaper)
- **Display**: Main Display, a specific display, or All Displays
- **Show Song Title**
- **Lyrics Offset**: `⌥⌘]` earlier · `⌥⌘[` later (0.25 s per step)
- **Search Lyrics Again**: when the lyrics were wrong or LRCLIB was busy (busy lookups are also retried automatically every 30 s, up to 3 times)
- **Open at Login**

## Effects (COTODAMA-style)

- Lyrics are **spelled out letter by letter** as they're sung, left-aligned, in mixed sizes.
- **Continuous canvas:** the previous line stays, dimmed; the camera pans, zooms and **turns 90°** to the new line.
- Upcoming words sometimes appear faintly first, and short phrases sometimes sit in an inverted label box.
- Mood from how fast the words come: calm (thin serif, slow) · medium · energetic (bold uppercase, fast).
- **Constellation**, in 3D: every word is a star at its own depth, so near words look bigger. The line's stars first show faintly so you see the shape; as each word is sung its star lights up, a line grows to it through 3D space from the previous star, and the letters are spelled out beside it. The whole sky slowly sways as if dragged by a finger, so near words move more than far ones (parallax), while every word keeps facing you. New constellations come out of the distance; older ones recede and dim. In automatic mode about half of the calm songs use it.
- Songs without lyrics: a typographic "poster" of title → artist → album (changing every 8 s) over moving graphics (rings, waves, dot grid, sunburst; one per song). Instrumental breaks in songs with lyrics show these graphics too.

- **Rap:** one huge word at a time in the middle, punching in as it's sung while the previous one zooms past, with the whole line in small type underneath. Automatic mode uses it when the singing is very dense.
- **Glitch** (rock / electronic): words twitch, flicker and split into a coloured ghost as they appear and on strong beats.
- **Energetic extras:** blocks tilt and spin in; when a line ends it bursts into glowing particles.
- **Medium:** a new line appears blurred and snaps into focus on the next beat.
- **Chorus:** lines that come back during the song are treated as the chorus: bigger emphasis, more zoom, stronger beat effects, and a hit (flash + pulse) when it starts.
- **Mood from the audio:** once the tempo is stable, fast songs (≥128 BPM) move one mood up and slow ones (≤82 BPM) one down. Automatic mode also uses the constellation for half of the calm songs and glitch for a third of the energetic ones.
- **On the beat:** the text and a soft glow pulse, the current line hops with a squash-and-stretch (strong mode), the background graphics swell, and energetic songs can flash on strong beats (off by default).

`legacy-web/` is the first browser-based player (with playback controls, audio/LRC file loading and 7 text styles), kept for reference.
