import AppKit
import QuartzCore

/// Everything drawn on one screen: background, lyric canvas, abstract graphics, caption.
final class LyricScene {
    let root = CALayer()
    private let bg = CAGradientLayer()
    private let glow = CAGradientLayer()     // beat glow behind the text
    private let strobeLayer = CALayer()      // beat flash in front
    private let content = CALayer()
    private let ambientHost = CALayer()
    private let stage = CALayer()
    private let capTitle = CATextLayer()
    private let capArtist = CATextLayer()

    private var size: CGSize
    private var backing: CGFloat

    // song
    private var lines: [Line] = []
    private var title = "", artist = "", album = "", trackId = ""
    private var noLyrics = false
    private var trackStart = CACurrentMediaTime()
    private var autoMood = "mid"

    // settings
    var moodSetting: MoodSetting = .auto { didSet { reset() } }
    var theme: Theme = .night { didSet { applyTheme() } }
    var showCaption = true { didSet { updateCaption() } }
    var beatSync: BeatSync = .strong
    var strobe = false
    private var moodName = "mid"
    private var lastStrobe = 0.0

    private enum Key: Equatable { case title, none, line(Int), meta(Int) }
    private var key: Key?
    private var jumped = true
    private var canvas: LyricCanvas?
    private var current: (block: Block, line: Line, mood: Mood, shown: [Bool])?
    private var ambient: CALayer?
    private var ambientKind = ""
    private var ambientTarget: Float = 0
    private var active = false
    private var inactiveSince = CACurrentMediaTime()

    private let metaSeconds = 8.0

    init(size: CGSize, backing: CGFloat) {
        self.size = size
        self.backing = backing
        setQuietly {
            root.isGeometryFlipped = true
            bg.type = .radial
            bg.startPoint = CGPoint(x: 0.43, y: 0.5)
            bg.endPoint = CGPoint(x: 1.13, y: 1.1)
            bg.opacity = 0
            content.opacity = 0
            glow.type = .radial
            glow.startPoint = CGPoint(x: 0.43, y: 0.5)
            glow.endPoint = CGPoint(x: 0.95, y: 1.05)
            glow.opacity = 0
            strobeLayer.opacity = 0
            root.addSublayer(bg)
            root.addSublayer(glow)
            root.addSublayer(content)
            root.addSublayer(strobeLayer)
            content.addSublayer(ambientHost)
            content.addSublayer(stage)
            ambientHost.opacity = 0
            for (l, weight) in [(capTitle, NSFont.Weight.heavy), (capArtist, .regular)] {
                l.font = NSFont.systemFont(ofSize: 13, weight: weight)
                l.fontSize = 13
                l.contentsScale = backing
                l.opacity = 0
                root.addSublayer(l)
            }
        }
        layout(size: size, backing: backing)
        applyTheme()
    }

    private var palette: Palette {
        Palette.of(theme, hue: CGFloat(hashString(title + artist) % 360) / 360)
    }

    private var baseFont: CGFloat { min(size.height * 0.13, size.width * 0.075) }

    func layout(size: CGSize, backing: CGFloat) {
        self.size = size
        self.backing = backing
        setQuietly {
            let r = CGRect(origin: .zero, size: size)
            root.frame = r
            bg.frame = r
            glow.frame = r
            strobeLayer.frame = r
            content.frame = r
            ambientHost.frame = r
            stage.frame = r
            capArtist.frame = CGRect(x: 48, y: size.height - 44 - 18, width: size.width * 0.5, height: 18)
            capTitle.frame = CGRect(x: 48, y: size.height - 44 - 37, width: size.width * 0.5, height: 18)
        }
        dropAmbient()
        reset()
    }

    private func applyTheme() {
        let p = palette
        setQuietly {
            bg.colors = p.bg
            glow.colors = [p.fg.withAlphaComponent(0.35).cgColor, p.fg.withAlphaComponent(0).cgColor]
            strobeLayer.backgroundColor = p.fg.cgColor
            bg.locations = theme == .night || theme == .clear ? [0, 0.8] : [0, 0.75]
            capTitle.foregroundColor = p.fg.cgColor
            capArtist.foregroundColor = p.fg.cgColor
        }
        dropAmbient()
        reset()
    }

    private func updateCaption() {
        setQuietly {
            capTitle.string = title
            capArtist.string = artist
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(1.2)
        let o: Float = active && showCaption ? 0.55 : 0
        capTitle.opacity = o
        capArtist.opacity = o
        CATransaction.commit()
    }

    // MARK: song data

    func setTrack(_ t: Track?) {
        title = t?.name ?? ""
        artist = t?.artist ?? ""
        album = t?.album ?? ""
        trackId = t?.id ?? ""
        lines = []
        noLyrics = false
        trackStart = CACurrentMediaTime()
        pickMood()
        applyTheme()   // hue follows the song
        updateCaption()
    }

    func setLyrics(_ lrc: String?, for id: String, duration: Double) {
        guard id == trackId else { return }
        lines = lrc.map { LRC.lines(from: $0, duration: duration) } ?? []
        noLyrics = lines.isEmpty
        pickMood()
        reset()
    }

    /// Mood from singing density, like the web version.
    private func pickMood() {
        var words = 0, secs = 0.0
        for l in lines where !l.words.isEmpty {
            words += l.words.count
            secs += min(l.end - l.time, 8)
        }
        let wps = secs > 0 ? Double(words) / secs : 1.5
        autoMood = wps > 2.6 ? "energetic" : wps > 1.5 ? "mid" : "calm"
    }

    // MARK: activity

    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        if on { reset() } else { inactiveSince = CACurrentMediaTime() }
        CATransaction.begin()
        CATransaction.setAnimationDuration(1.2)
        bg.opacity = on ? 1 : 0
        content.opacity = on ? 1 : 0
        CATransaction.commit()
        updateCaption()
    }

    func reset() {
        jumped = true
        key = nil
    }

    // MARK: per tick

    func tick(time t: Double, playing: Bool) {
        if !active && CACurrentMediaTime() - inactiveSince > 1.5 {
            if ambient != nil { dropAmbient() }
            return
        }
        let k = keyAt(t)
        if k != key { show(k, t) }
        updateCurrent(t)
        updateAmbient(playing)
    }

    private func lineIndex(at t: Double) -> Int {
        var lo = 0, hi = lines.count - 1, ans = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= t { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return ans
    }

    private func keyAt(_ t: Double) -> Key {
        if lines.isEmpty {
            if noLyrics { return .meta(Int(max(0, t) / metaSeconds)) }
            return CACurrentMediaTime() - trackStart < 6 ? .title : .none
        }
        let i = lineIndex(at: t)
        if i < 0 { return t < lines[0].time - 0.6 ? .title : .none }
        let l = lines[i]
        if l.words.isEmpty || t >= l.end { return .none }
        return .line(i)
    }

    private func titleLine(_ t: Double) -> Line {
        var l = LRC.build(time: 0, body: title, next: nil)
        for k in l.words.indices { l.words[k].time = t + 0.15 + Double(k) * 0.22 }
        return l
    }

    /// Song-info "poster" for tracks without lyrics: title → artist → album.
    private func metaLine(_ n: Int) -> Line {
        var seen = Set<String>()
        let items = [title, artist, album].filter { !$0.isEmpty && seen.insert($0).inserted }
        let text = items.isEmpty ? "♪" : items[n % items.count]
        let start = Double(n) * metaSeconds
        return LRC.build(time: start + 0.3, body: text, next: start + metaSeconds)
    }

    private func show(_ k: Key, _ t: Double) {
        let wasJumped = jumped
        jumped = false
        if wasJumped {
            canvas?.remove()
            canvas = nil
        }
        current = nil
        key = k

        let line: Line?
        var salt: UInt32 = 0
        switch k {
        case .none: line = nil
        case .title: line = titleLine(t)
        case .meta(let n): line = metaLine(n); salt = UInt32(n)
        case .line(let i): line = lines[i]; salt = UInt32(i)
        }
        guard let line, !line.words.isEmpty else {
            canvas?.fadeOut()
            canvas = nil
            return
        }
        // constellation when chosen, and for half of the calm songs in automatic mode
        let stars = moodSetting == .constellation
            || (moodSetting == .auto && autoMood == "calm" && hashString(title) % 2 == 0)
        if let c = canvas, (c is ConstellationCanvas) != stars {
            c.fadeOut()
            canvas = nil
        }
        if canvas == nil {
            canvas = stars
                ? ConstellationCanvas(in: stage, size: size, color: palette.fg.cgColor)
                : FlowCanvas(in: stage, focus: CGPoint(x: size.width * 0.43, y: size.height / 2))
        }
        moodName = stars ? "calm" : (moodSetting == .auto ? autoMood : moodSetting.rawValue)
        let mood = Mood.named(moodName)
        let style = FlowStyle(base: baseFont, palette: palette, backing: backing, fontSeed: hashString(title))
        let block = canvas!.add(line: line, seed: hashString(line.text) &+ salt, mood: mood, style: style,
                                stageSize: size, instant: wasJumped)
        current = (block, line, mood, Array(repeating: false, count: line.words.count))
    }

    private func updateCurrent(_ t: Double) {
        guard var c = current else { return }
        var changed = false
        for (k, w) in c.line.words.enumerated() where !c.shown[k] && w.time <= t {
            c.shown[k] = true
            changed = true
            let next = k + 1 < c.line.words.count ? c.line.words[k + 1].time : w.time + 0.6
            let span = max(0.12, min(next - w.time, 0.8)) * 0.8
            c.block.onReveal?(k, t - w.time > 0.5)
            FlowCanvas.reveal(c.block.glyphs[k], size: c.block.sizes[k], span: span, mood: c.mood,
                              ghost: c.block.ghost, instant: t - w.time > 0.5)
        }
        if changed { current = c }
    }

    // MARK: beat

    /// Called on each detected beat (strength 0…1), already delayed to match what you hear.
    func beat(_ strength: Double) {
        guard active, beatSync != .off else { return }
        let energetic = moodName == "energetic"
        let k = CGFloat(strength) * (energetic ? 1.35 : moodName == "calm" ? 0.7 : 1)

        func pulse(_ layer: CALayer, _ key: String, _ peak: Any, rest: Any, duration: Double, additive: Bool = false) {
            let a = CAKeyframeAnimation(keyPath: key)
            a.values = [rest, peak, rest]
            a.keyTimes = [0, 0.22, 1]
            a.duration = duration
            a.timingFunctions = [timing(0.2, 0.8, 0.3, 1), timing(0.4, 0, 0.6, 1)]
            a.isAdditive = additive
            layer.add(a, forKey: "beat-" + key)
        }
        // Pulse: the text breathes and a soft glow blooms behind it
        pulse(stage, "transform.scale", 1 + 0.022 * k, rest: 1, duration: 0.34)
        pulse(glow, "opacity", Float(0.55 * k), rest: Float(0), duration: 0.5)
        pulse(ambientHost, "transform.scale", 1 + 0.05 * k, rest: 1, duration: 0.4)
        // Bounce: the current line hops
        if beatSync == .strong, let c = current {
            pulse(c.block.layer, "transform.translation.y", -baseFont * 0.06 * k, rest: CGFloat(0), duration: 0.3, additive: true)
        }
        // Strobe: brief flash on strong beats of energetic songs, at most ~3 per second
        let now = CACurrentMediaTime()
        if strobe && energetic && strength > 0.7 && now - lastStrobe > 0.33 {
            lastStrobe = now
            let a = CAKeyframeAnimation(keyPath: "opacity")
            a.values = [Float(0.22 * strength), Float(0)]
            a.duration = 0.12
            strobeLayer.add(a, forKey: "strobe")
        }
    }

    // MARK: abstract graphics

    private func updateAmbient(_ playing: Bool) {
        var target: Float = 0
        if playing && active {
            if key == Key.none { target = 0.8 } else if case .meta = key { target = 0.38 }
        }
        let kind = Ambient.kinds[Int(hashString(trackId.isEmpty ? title : trackId) % UInt32(Ambient.kinds.count))]
        if target > 0 && (ambient == nil || kind != ambientKind) {
            ambient?.removeFromSuperlayer()
            let a = Ambient.make(kind: kind, size: size, color: palette.fg.cgColor)
            setQuietly { ambientHost.addSublayer(a) }
            ambient = a
            ambientKind = kind
        }
        guard target != ambientTarget else { return }
        ambientTarget = target
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.9)
        if target == 0 {
            // stop the animations once faded so the render server can rest
            CATransaction.setCompletionBlock { [weak self] in
                if self?.ambientTarget == 0 { self?.dropAmbient() }
            }
        }
        ambientHost.opacity = target
        CATransaction.commit()
    }

    private func dropAmbient() {
        ambient?.removeFromSuperlayer()
        ambient = nil
        ambientTarget = 0
        setQuietly { ambientHost.opacity = 0 }
    }
}
