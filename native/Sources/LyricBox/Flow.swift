import AppKit
import QuartzCore

/* COTODAMA-like "flow" canvas.
   Every lyric line becomes a text block on one big virtual canvas. A new block is
   placed next to the previous one (sometimes turned 90°) and the camera pans /
   rotates / zooms onto it, so older lines stay on screen, dimmed and sideways.
   Letters are spelled out while they are sung. Mood picks font + motion. */

func timing(_ a: Float, _ b: Float, _ c: Float, _ d: Float) -> CAMediaTimingFunction {
    CAMediaTimingFunction(controlPoints: a, b, c, d)
}

enum FontKind { case serif, sans, impact }

struct Mood {
    let fonts: [FontKind]
    let turn: Double            // chance a new block is turned 90°
    let cam: Double             // camera move duration
    let camEase: CAMediaTimingFunction
    let emph: CGFloat           // size of the emphasised word
    let units: CGFloat          // row width budget
    let maxZoom: CGFloat
    let ghost: Double           // chance upcoming words show faintly first
    let label: Double           // chance of an inverted label box
    let rise: CGFloat?          // letters rise by this many em; nil = pop in
    let dur: Double
    let ease: CAMediaTimingFunction

    static let calm = Mood(fonts: [.serif], turn: 0.3, cam: 1.5, camEase: timing(0.45, 0, 0.15, 1),
                           emph: 1.45, units: 15, maxZoom: 1.25, ghost: 0.45, label: 0.08,
                           rise: 0.12, dur: 0.65, ease: timing(0.2, 0.7, 0.2, 1))
    static let mid = Mood(fonts: [.serif, .sans], turn: 0.4, cam: 0.95, camEase: timing(0.65, 0, 0.2, 1),
                          emph: 1.7, units: 12, maxZoom: 1.45, ghost: 0.3, label: 0.15,
                          rise: 0.35, dur: 0.3, ease: timing(0.16, 1, 0.3, 1))
    static let energetic = Mood(fonts: [.impact, .sans], turn: 0.55, cam: 0.52, camEase: timing(0.3, 1.35, 0.45, 1),
                                emph: 2, units: 9, maxZoom: 1.7, ghost: 0.1, label: 0.25,
                                rise: nil, dur: 0.22, ease: timing(0.34, 1.56, 0.64, 1))

    static func named(_ s: String) -> Mood {
        switch s { case "calm": return .calm; case "energetic": return .energetic; default: return .mid }
    }
}

/// Bundled Noto fonts (OFL), the family COTODAMA uses for Latin / Vietnamese lyrics.
enum Fonts {
    static var useNoto = true
    private static var registered = false

    /// Registers the variable fonts shipped in Contents/Resources/Fonts (or native/Resources/Fonts when run from .build).
    static func register() {
        guard !registered else { return }
        registered = true
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
                          exe.appendingPathComponent("../../../Resources/Fonts").standardizedFileURL]
        guard let dir = candidates.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
        }
    }

    private static let wght = NSNumber(value: 0x7767_6874) // 'wght'
    private static let wdth = NSNumber(value: 0x7764_7468) // 'wdth'

    /// Noto at a given weight / width, falling back to Hiragino for Japanese.
    static func noto(_ family: String, size: CGFloat, weight: Double, width: Double = 100, japanese: String) -> NSFont? {
        let d = NSFontDescriptor(fontAttributes: [
            .family: family,
            .variation: [wght: weight, wdth: width],
            .cascadeList: [NSFontDescriptor(name: japanese, size: size)],
        ])
        guard let f = NSFont(descriptor: d, size: size), f.familyName == family else { return nil }
        return f
    }
}

func makeFont(_ kind: FontKind, size: CGFloat, bold: Bool) -> NSFont {
    if Fonts.useNoto {
        let f: NSFont?
        switch kind {
        case .serif: f = Fonts.noto("Noto Serif", size: size, weight: bold ? 700 : 400, japanese: bold ? "HiraMinProN-W6" : "HiraMinProN-W3")
        case .sans: f = Fonts.noto("Noto Sans", size: size, weight: 800, japanese: "HiraginoSans-W7")
        case .impact: f = Fonts.noto("Noto Sans", size: size, weight: 900, width: 62.5, japanese: "HiraginoSans-W8")
        }
        if let f { return f }
    }
    switch kind {
    case .serif: // New York
        let base = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        if let d = base.fontDescriptor.withDesign(.serif), let f = NSFont(descriptor: d, size: size) { return f }
        return base
    case .sans:
        return NSFont.systemFont(ofSize: size, weight: .heavy)
    case .impact:
        return NSFont.systemFont(ofSize: size, weight: .black, width: .condensed)
    }
}

struct Palette {
    let fg: NSColor
    let labelText: NSColor
    let bg: [CGColor]
    let shadow: NSColor?

    static func of(_ theme: Theme, hue: CGFloat) -> Palette {
        switch theme {
        case .night:
            return Palette(fg: NSColor(white: 0.955, alpha: 1), labelText: NSColor(white: 0.05, alpha: 1),
                           bg: [NSColor(hue: hue, saturation: 0.6, brightness: 0.2, alpha: 1).cgColor,
                                NSColor(red: 0.03, green: 0.035, blue: 0.045, alpha: 1).cgColor],
                           shadow: nil)
        case .clear:
            return Palette(fg: NSColor(red: 0.09, green: 0.094, blue: 0.106, alpha: 1), labelText: NSColor(white: 0.93, alpha: 1),
                           bg: [NSColor(red: 0.945, green: 0.95, blue: 0.94, alpha: 1).cgColor,
                                NSColor(red: 0.79, green: 0.8, blue: 0.79, alpha: 1).cgColor],
                           shadow: nil)
        case .glassLight:
            return Palette(fg: .white, labelText: NSColor(white: 0.07, alpha: 1),
                           bg: [NSColor(white: 0, alpha: 0.38).cgColor, NSColor(white: 0, alpha: 0).cgColor],
                           shadow: NSColor(white: 0, alpha: 0.55))
        case .glassDark:
            return Palette(fg: NSColor(white: 0.07, alpha: 1), labelText: .white,
                           bg: [NSColor(white: 1, alpha: 0.45).cgColor, NSColor(white: 1, alpha: 0).cgColor],
                           shadow: NSColor(white: 1, alpha: 0.7))
        }
    }
}

/// One letter, drawn with Core Text into a bitmap just big enough for its ink.
final class GlyphLayer: CALayer {
    var ctLine: CTLine?
    var textOrigin = CGPoint.zero
    var shadowColor0: NSColor?
    var shadowBlur0: CGFloat = 0

    override func draw(in ctx: CGContext) {
        guard let ctLine else { return }
        if contentsAreFlipped() {
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        if let c = shadowColor0 { ctx.setShadow(offset: CGSize(width: 0, height: -shadowBlur0 * 0.2), blur: shadowBlur0, color: c.cgColor) }
        ctx.textMatrix = .identity
        ctx.textPosition = textOrigin
        CTLineDraw(ctLine, ctx)
    }
}

final class Block {
    let layer = CALayer()
    var onReveal: ((_ word: Int, _ instant: Bool) -> Void)?   // extra effect when a word starts
    var x: CGFloat = 0, y: CGFloat = 0, w: CGFloat = 0, h: CGFloat = 0, rot: CGFloat = 0
    var glyphs: [[GlyphLayer]] = []   // per word
    var sizes: [CGFloat] = []         // font size per word (pt)
    var ghost: Float = 0
}

struct FlowStyle {
    let base: CGFloat        // block font size
    let palette: Palette
    let backing: CGFloat
    let fontSeed: UInt32     // keeps one font per song
}

func setQuietly(_ body: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    body()
    CATransaction.commit()
}

/// Animate a key path from its current on-screen value to `value`.
func animate(_ layer: CALayer, _ keyPath: String, to value: Any, duration: Double, timing: CAMediaTimingFunction) {
    let from = layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)
    setQuietly { layer.setValue(value, forKeyPath: keyPath) }
    let a = CABasicAnimation(keyPath: keyPath)
    a.fromValue = from
    a.toValue = value
    a.duration = duration
    a.timingFunction = timing
    layer.add(a, forKey: keyPath)
}

/// A lyric renderer the scene can switch between (flow canvas, constellation…).
protocol LyricCanvas: AnyObject {
    func add(line: Line, seed: UInt32, mood: Mood, style: FlowStyle, stageSize: CGSize, instant: Bool) -> Block
    func remove()
    func fadeOut()
}

/// One layer per letter of `text`, placed at the word's kerned positions.
/// `origin` is where the word starts on its baseline.
func makeGlyphs(_ text: String, attrs: [NSAttributedString.Key: Any], line: CTLine, at origin: CGPoint,
                pad: CGFloat, scale: CGFloat, shadow: NSColor?, blur: CGFloat, opacity: Float) -> [GlyphLayer] {
    var out: [GlyphLayer] = []
    var u16 = 0
    for ch in text {
        let s = String(ch)
        defer { u16 += s.utf16.count }
        let ct = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        let gb = CTLineGetBoundsWithOptions(ct, .useGlyphPathBounds)
        if gb.isEmpty || gb.width <= 0 { continue }
        let off = CTLineGetOffsetForStringIndex(line, u16, nil)
        let g = GlyphLayer()
        g.ctLine = ct
        g.contentsScale = scale
        g.frame = CGRect(x: origin.x + off + gb.minX - pad, y: origin.y - gb.maxY - pad,
                         width: gb.width + pad * 2, height: gb.height + pad * 2)
        g.textOrigin = CGPoint(x: pad - gb.minX, y: pad - gb.minY)
        g.shadowColor0 = shadow
        g.shadowBlur0 = blur
        g.opacity = opacity
        g.setNeedsDisplay()
        out.append(g)
    }
    return out
}

final class FlowCanvas: LyricCanvas {
    // camera = position → rotation → scale → world offset (separate layers so a 90°
    // turn interpolates as a real rotation instead of a squashed matrix)
    private let camPos = CALayer(), camRot = CALayer(), camScale = CALayer(), world = CALayer()
    private(set) var blocks: [Block] = []
    private var angle: CGFloat = 0   // cumulative camera angle (CA reads rotation back wrapped to ±π)

    init(in stage: CALayer, focus: CGPoint) {
        setQuietly {
            camPos.position = focus
            camPos.addSublayer(camRot)
            camRot.addSublayer(camScale)
            camScale.addSublayer(world)
            stage.addSublayer(camPos)
        }
    }

    func remove() { camPos.removeFromSuperlayer() }

    func fadeOut() {
        let l = camPos
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.7)
        CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
        l.opacity = 0
        CATransaction.commit()
    }

    func add(line: Line, seed: UInt32, mood: Mood, style: FlowStyle, stageSize: CGSize, instant: Bool) -> Block {
        var r = SeededRandom(seed)
        var fr = SeededRandom(style.fontSeed)
        let kind = mood.fonts[min(mood.fonts.count - 1, Int(fr.next() * Double(mood.fonts.count)))]
        let texts = line.words.map { kind == .impact ? $0.text.uppercased() : $0.text }
        let b = Block()

        // hierarchy: one emphasised word, tiny function words, left-aligned rows
        let avg = Double(texts.reduce(0) { $0 + $1.count }) / Double(max(1, texts.count))
        var big = -1
        if texts.count >= 2 && r.next() < 0.85 {
            let cands = texts.indices.filter { Double(texts[$0].count) >= min(4, avg) }
            if let first = cands.first {
                big = cands.reduce(first) { a, k in Double(texts[k].count) + r.next() * 2 > Double(texts[a].count) ? k : a }
            }
        }
        let rel: [CGFloat] = texts.indices.map { k in
            k == big ? mood.emph : (texts[k].count <= 2 && avg > 3.5) ? 0.62 : (r.next() < 0.15 ? 1.18 : 1)
        }
        var rows: [[Int]] = []
        var units: CGFloat = 0
        for k in texts.indices {
            let u = CGFloat(texts[k].count + 1) * rel[k]
            let isolate = (k == big || k - 1 == big) && r.next() < 0.6
            if rows.isEmpty || (units + u > mood.units && units > 0) || (isolate && units > 0) {
                rows.append([])
                units = 0
            }
            rows[rows.count - 1].append(k)
            units += u
        }
        let label = texts.count <= 4 && r.next() < mood.label
        b.ghost = r.next() < mood.ghost ? 0.16 : 0

        // measure with Core Text
        let lineHeight: CGFloat = kind == .impact ? 1.02 : 1.12
        let kern: CGFloat = kind == .impact ? 0.01 : kind == .sans ? -0.02 : -0.01
        let textColor = label ? style.palette.labelText : style.palette.fg
        struct Measured { let line: CTLine; let attrs: [NSAttributedString.Key: Any]; let width: CGFloat; let size: CGFloat }
        var measured: [Measured] = []
        for k in texts.indices {
            let size = style.base * rel[k]
            let font = makeFont(kind, size: size, bold: k == big && kind == .serif)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor, .kern: kern * size]
            let ct = CTLineCreateWithAttributedString(NSAttributedString(string: texts[k], attributes: attrs))
            measured.append(Measured(line: ct, attrs: attrs, width: CGFloat(CTLineGetTypographicBounds(ct, nil, nil, nil)), size: size))
        }
        var placed: [(k: Int, x: CGFloat, baseline: CGFloat)] = []
        var y: CGFloat = 0, blockW: CGFloat = 0
        for row in rows {
            let maxSize = row.map { measured[$0].size }.max() ?? style.base
            var asc: CGFloat = 0, desc: CGFloat = 0
            for k in row {
                let f = measured[k].attrs[.font] as! NSFont
                asc = max(asc, f.ascender); desc = max(desc, -f.descender)
            }
            let rowH = maxSize * lineHeight
            let baseline = y + rowH / 2 + (asc - desc) / 2
            var x: CGFloat = 0
            for (i, k) in row.enumerated() {
                placed.append((k, x, baseline))
                x += measured[k].width + (i < row.count - 1 ? measured[k].size * 0.22 : 0)
            }
            blockW = max(blockW, x)
            y += rowH
        }
        let padX = label ? style.base * 0.3 : 0, padT = label ? style.base * 0.08 : 0, padB = label ? style.base * 0.12 : 0
        b.w = blockW + padX * 2
        b.h = y + padT + padB

        // place next to the previous block, sometimes turned 90°
        if let prev = blocks.last {
            let dr: CGFloat = r.next() < mood.turn ? (r.next() < 0.5 ? 90 : -90) : 0
            let ex = dr != 0 ? b.h : b.w, ey = dr != 0 ? b.w : b.h
            let gap = style.base * 0.3
            let off: CGPoint
            if dr == 0 && r.next() < 0.65 { off = CGPoint(x: -prev.w / 2 + ex / 2, y: prev.h / 2 + gap + ey / 2) }      // below, left-aligned
            else if r.next() < 0.5 { off = CGPoint(x: prev.w / 2 + gap + ex / 2, y: -prev.h / 2 + ey / 2) }            // right, top-aligned
            else { off = CGPoint(x: -prev.w / 2 - gap - ex / 2, y: prev.h / 2 - ey / 2) }                               // left, bottom-aligned
            let a = prev.rot * .pi / 180
            b.x = prev.x + off.x * cos(a) - off.y * sin(a)
            b.y = prev.y + off.x * sin(a) + off.y * cos(a)
            b.rot = prev.rot + dr
        }
        let zoom = min(mood.maxZoom, stageSize.width * 0.7 / b.w, stageSize.height * 0.76 / b.h)

        // build layers: one per letter so each can be spelled out on its own
        let shadowBlur: CGFloat = style.palette.shadow != nil ? style.base * 0.09 : 0
        let pad: CGFloat = 2 + shadowBlur * 1.5
        let scale = style.backing * max(0.6, zoom)
        setQuietly {
            b.layer.bounds = CGRect(x: 0, y: 0, width: b.w, height: b.h)
            b.layer.position = CGPoint(x: b.x, y: b.y)
            b.layer.transform = CATransform3DMakeRotation(b.rot * .pi / 180, 0, 0, 1)
            if label {
                b.layer.backgroundColor = style.palette.fg.cgColor
            }
            b.glyphs = Array(repeating: [], count: texts.count)
            b.sizes = measured.map { $0.size }
            for p in placed {
                let m = measured[p.k]
                let gs = makeGlyphs(texts[p.k], attrs: m.attrs, line: m.line,
                                    at: CGPoint(x: padX + p.x, y: padT + p.baseline), pad: pad, scale: scale,
                                    shadow: label ? nil : style.palette.shadow, blur: shadowBlur, opacity: b.ghost)
                gs.forEach { b.layer.addSublayer($0) }
                b.glyphs[p.k] = gs
            }
            world.addSublayer(b.layer)
        }
        blocks.append(b)

        // older lines stay, dimmed, then fade away
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.9)
        let n = blocks.count
        for (i, o) in blocks.enumerated() where i < n - 1 {
            o.layer.opacity = i == n - 2 ? 0.26 : 0.1
        }
        CATransaction.commit()
        while blocks.count > 3 {
            let old = blocks.removeFirst()
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.8)
            CATransaction.setCompletionBlock { old.layer.removeFromSuperlayer() }
            old.layer.opacity = 0
            CATransaction.commit()
        }

        focus(b, zoom: zoom, mood: mood, instant: instant)
        return b
    }

    private func focus(_ b: Block, zoom: CGFloat, mood: Mood, instant: Bool) {
        let rot = -b.rot * .pi / 180
        let pos = NSValue(point: CGPoint(x: -b.x, y: -b.y))
        let fromAngle = angle
        angle = rot
        if instant {
            setQuietly {
                camRot.setValue(rot, forKeyPath: "transform.rotation.z")
                camScale.setValue(zoom, forKeyPath: "transform.scale")
                world.position = CGPoint(x: -b.x, y: -b.y)
            }
            return
        }
        setQuietly { camRot.setValue(rot, forKeyPath: "transform.rotation.z") }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = fromAngle
        turn.toValue = rot
        turn.duration = mood.cam
        turn.timingFunction = mood.camEase
        camRot.add(turn, forKey: "turn")
        animate(camScale, "transform.scale", to: zoom, duration: mood.cam, timing: mood.camEase)
        animate(world, "position", to: pos, duration: mood.cam, timing: mood.camEase)
    }

    /// Spell one word: letters appear across the time it is sung.
    static func reveal(_ glyphs: [GlyphLayer], size: CGFloat, span: Double, mood: Mood, ghost: Float, instant: Bool) {
        setQuietly {
            for g in glyphs {
                g.opacity = 1
                g.transform = CATransform3DIdentity
            }
        }
        if instant { return }
        let step = span / Double(max(1, glyphs.count))
        let now = CACurrentMediaTime()
        for (i, g) in glyphs.enumerated() {
            let op = CABasicAnimation(keyPath: "opacity")
            op.fromValue = ghost
            op.toValue = 1
            let tr = CABasicAnimation(keyPath: "transform")
            tr.fromValue = mood.rise.map { CATransform3DMakeTranslation(0, $0 * size, 0) } ?? CATransform3DMakeScale(1.7, 1.7, 1)
            tr.toValue = CATransform3DIdentity
            for a in [op, tr] {
                a.beginTime = now + Double(i) * step
                a.duration = mood.dur
                a.timingFunction = mood.ease
                a.fillMode = .backwards
                g.add(a, forKey: a.keyPath)
            }
        }
    }
}
