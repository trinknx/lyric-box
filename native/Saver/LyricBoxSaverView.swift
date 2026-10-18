import AppKit
import QuartzCore
import ScreenSaver

/* Lyric Box as a real macOS screen saver, so the lyrics keep going when the Mac's own
   screen saver starts and while it is locked. It draws with the same engine as the app;
   what's playing, the lyrics, beats and settings come from the running Lyric Box app
   (see Bridge). Without the app it shows a short hint. */
@objc(LyricBoxSaverView)
final class LyricBoxSaverView: ScreenSaverView {
    private var scene: LyricScene?
    private var state: Bridge.State?
    private var observers: [NSObjectProtocol] = []
    private var lastHello = 0.0
    private var idleStart = CACurrentMediaTime()
    private var idle = true

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        animationTimeInterval = 1.0 / 20
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }

    override func startAnimation() {
        super.startAnimation()
        Fonts.register(from: Bundle(for: LyricBoxSaverView.self))
        let s = LyricScene(size: bounds.size, backing: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        layer?.addSublayer(s.root)
        scene = s
        showHint()
        s.setActive(true)

        let c = DistributedNotificationCenter.default()
        observers = [
            c.addObserver(forName: Bridge.state, object: nil, queue: .main) { [weak self] n in self?.receive(state: n.object) },
            c.addObserver(forName: Bridge.lyrics, object: nil, queue: .main) { [weak self] n in self?.receive(lyrics: n.object) },
            c.addObserver(forName: Bridge.beat, object: nil, queue: .main) { [weak self] n in
                if let s = (n.object as? String).flatMap(Double.init) { self?.scene?.beat(s) }
            },
        ]
        hello()
    }

    override func stopAnimation() {
        super.stopAnimation()
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        observers = []
        scene?.root.removeFromSuperlayer()
        scene = nil
        state = nil
    }

    private func hello() {
        lastHello = CACurrentMediaTime()
        Bridge.post(Bridge.hello)
    }

    /// No app (or no song yet): a calm poster telling what to do.
    private func showHint() {
        guard let scene else { return }
        idle = true
        idleStart = CACurrentMediaTime()
        let hint = Track(id: "lyricbox-hint", name: "Lyric Box", artist: "Mở app Lyric Box và phát nhạc trên Spotify", album: "", duration: 0)
        scene.moodSetting = .calm
        scene.setTrack(hint)
        scene.setLyrics(nil, for: hint.id, duration: 0)
    }

    private func receive(state object: Any?) {
        guard let scene, let s = Bridge.decode(object, as: Bridge.State.self) else { return }
        let old = state
        state = s
        if old?.theme != s.theme {
            let t = Theme(rawValue: s.theme) ?? .night
            scene.theme = (t == .glassLight || t == .glassDark) ? .night : t   // nothing behind a screen saver
        }
        if old?.mood != s.mood || idle { scene.moodSetting = MoodSetting(rawValue: s.mood) ?? .auto }
        if old?.fontSet != s.fontSet {
            Fonts.useNoto = s.fontSet != "system"
            scene.reset()
        }
        scene.beatSync = BeatSync(rawValue: s.beatSync) ?? .strong
        scene.strobe = s.strobe
        scene.showCaption = s.caption
        if s.id.isEmpty {
            if !idle { showHint() }
        } else if idle || old?.id != s.id {
            idle = false
            scene.setTrack(Track(id: s.id, name: s.name, artist: s.artist, album: s.album, duration: s.duration))
            hello()   // ask for this song's lyrics
        }
    }

    private func receive(lyrics object: Any?) {
        guard let scene, let l = Bridge.decode(object, as: Bridge.Lyrics.self), let s = state, l.id == s.id else { return }
        scene.setLyrics(l.lrc, for: l.id, duration: s.duration)
    }

    override func animateOneFrame() {
        guard let scene else { return }
        let now = CACurrentMediaTime()
        if now - lastHello > 4 { hello() }
        let wall = Date().timeIntervalSince1970
        if let s = state, !idle, wall - s.ts < 10 {
            let pos = s.playing ? s.position + (wall - s.ts) : s.position
            scene.tick(time: min(pos, max(s.duration, pos)) + s.offset, playing: s.playing)
        } else {
            if !idle { showHint() }   // the app went quiet
            scene.tick(time: now - idleStart, playing: true)
        }
    }
}
