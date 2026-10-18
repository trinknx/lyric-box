import AppKit
import QuartzCore

/* "Constellation" style: every word is a star. When a line starts its stars show
   faintly (you see the shape of the constellation first); as each word is sung its
   star lights up, a thin line is drawn from the previous star, and the letters are
   spelled out beside it. Older constellations dim and drift back over a twinkling sky. */
final class ConstellationCanvas: LyricCanvas {
    private let host = CALayer()
    private let sky = CALayer()
    private var groups: [CALayer] = []
    private let size: CGSize
    private var flip = false

    init(in stage: CALayer, size: CGSize, color: CGColor) {
        self.size = size
        setQuietly {
            host.frame = CGRect(origin: .zero, size: size)
            sky.frame = host.bounds
            host.addSublayer(sky)
            stage.addSublayer(host)
        }
        buildSky(color)
    }

    func remove() { host.removeFromSuperlayer() }

    func fadeOut() {
        let l = host
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.8)
        CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
        l.opacity = 0
        CATransaction.commit()
    }

    /// Faint background stars twinkling on their own (render-server animations only).
    private func buildSky(_ color: CGColor) {
        var r = SeededRandom(99)
        let now = CACurrentMediaTime()
        setQuietly {
            for _ in 0..<140 {
                let d = CGFloat(1 + r.next() * 1.8)
                let dot = CALayer()
                dot.bounds = CGRect(x: 0, y: 0, width: d, height: d)
                dot.cornerRadius = d / 2
                dot.backgroundColor = color
                dot.position = CGPoint(x: r.next() * size.width, y: r.next() * size.height)
                let base = Float(0.08 + r.next() * 0.25)
                dot.opacity = base
                let tw = CABasicAnimation(keyPath: "opacity")
                tw.fromValue = base
                tw.toValue = base * 0.15
                tw.duration = 1.5 + r.next() * 3
                tw.autoreverses = true
                tw.repeatCount = .infinity
                tw.beginTime = now - r.next() * 4
                dot.add(tw, forKey: "twinkle")
                sky.addSublayer(dot)
            }
        }
    }

    func add(line: Line, seed: UInt32, mood: Mood, style: FlowStyle, stageSize: CGSize, instant: Bool) -> Block {
        var r = SeededRandom(seed)
        let b = Block()
        let texts = line.words.map { $0.text }
        let color = style.palette.fg.cgColor

        let avg = Double(texts.reduce(0) { $0 + $1.count }) / Double(max(1, texts.count))
        var big = -1
        if texts.count >= 2 {
            big = texts.indices.max { texts[$0].count + Int(r.next() * 2) < texts[$1].count + Int(r.next() * 2) } ?? -1
        }
        let base = style.base * 0.5
        let sizes: [CGFloat] = texts.indices.map { k in
            k == big ? base * 1.6 : (texts[k].count <= 2 && avg > 3.5) ? base * 0.72 : base
        }

        // lay the stars out along a meandering left-to-right path
        struct Star { let p: CGPoint; let origin: CGPoint; let attrs: [NSAttributedString.Key: Any]; let line: CTLine; let width: CGFloat; let size: CGFloat }
        var stars: [Star] = []
        var x: CGFloat = 0, prevY: CGFloat = 0
        let swing = style.base * 1.1
        for k in texts.indices {
            let s = sizes[k]
            let font = makeFont(.serif, size: s, bold: k == big)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: style.palette.fg, .kern: -0.01 * s]
            let ct = CTLineCreateWithAttributedString(NSAttributedString(string: texts[k], attributes: attrs))
            let w = CGFloat(CTLineGetTypographicBounds(ct, nil, nil, nil))
            var y: CGFloat = 0
            for _ in 0..<8 {
                y = CGFloat(r.next() * 2 - 1) * swing
                if k == 0 || abs(y - prevY) > swing * 0.5 { break }
            }
            let p = CGPoint(x: x, y: y)
            // the star sits at x-height, just before the word
            let origin = CGPoint(x: x + s * 0.3, y: y + s * 0.3)
            stars.append(Star(p: p, origin: origin, attrs: attrs, line: ct, width: w, size: s))
            x = origin.x + w + style.base * (0.45 + 0.35 * CGFloat(r.next()))
            prevY = y
        }
        var minX = CGFloat.infinity, maxX = -CGFloat.infinity, minY = CGFloat.infinity, maxY = -CGFloat.infinity
        for s in stars {
            minX = min(minX, s.p.x - s.size * 0.2); maxX = max(maxX, s.origin.x + s.width)
            minY = min(minY, s.origin.y - s.size * 0.95); maxY = max(maxY, s.origin.y + s.size * 0.3)
        }
        let bw = max(1, maxX - minX), bh = max(1, maxY - minY)
        let shift = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        let fit = min(1.2, size.width * 0.7 / bw, size.height * 0.56 / bh)
        flip.toggle()
        let group = b.layer
        let scale = style.backing * fit
        let lineWidth = max(1, 1.4 / fit)

        var starLayers: [CALayer] = [], halos: [CALayer] = [], links: [CAShapeLayer?] = []
        setQuietly {
            group.position = CGPoint(x: size.width * 0.45, y: size.height * (0.5 + (flip ? -0.07 : 0.07)))
            group.transform = CATransform3DMakeScale(fit, fit, 1)
            group.opacity = instant ? 1 : 0
            let linkHost = CALayer()
            group.addSublayer(linkHost)
            b.glyphs = Array(repeating: [], count: texts.count)
            b.sizes = sizes
            for (k, s) in stars.enumerated() {
                let p = CGPoint(x: s.p.x - shift.x, y: s.p.y - shift.y)
                if k > 0 {
                    let q = CGPoint(x: stars[k - 1].p.x - shift.x, y: stars[k - 1].p.y - shift.y)
                    let path = CGMutablePath()
                    path.move(to: q)
                    path.addLine(to: p)
                    let link = CAShapeLayer()
                    link.path = path
                    link.strokeColor = color
                    link.lineWidth = lineWidth
                    link.lineCap = .round
                    link.opacity = 0.55
                    link.strokeEnd = 0
                    linkHost.addSublayer(link)
                    links.append(link)
                } else {
                    links.append(nil)
                }
                let halo = CAGradientLayer()
                halo.type = .radial
                halo.colors = [style.palette.fg.withAlphaComponent(0.5).cgColor, style.palette.fg.withAlphaComponent(0).cgColor]
                halo.startPoint = CGPoint(x: 0.5, y: 0.5)
                halo.endPoint = CGPoint(x: 1, y: 1)
                let hr = s.size * 0.45
                halo.bounds = CGRect(x: 0, y: 0, width: hr * 2, height: hr * 2)
                halo.position = p
                halo.opacity = 0
                group.addSublayer(halo)
                halos.append(halo)

                let rad = max(2.5 / fit, s.size * 0.06)
                let star = CALayer()
                star.bounds = CGRect(x: 0, y: 0, width: rad * 2, height: rad * 2)
                star.cornerRadius = rad
                star.backgroundColor = color
                star.position = p
                star.opacity = 0.22   // faint preview of the constellation
                group.addSublayer(star)
                starLayers.append(star)

                let gs = makeGlyphs(texts[k], attrs: s.attrs, line: s.line,
                                    at: CGPoint(x: s.origin.x - shift.x, y: s.origin.y - shift.y),
                                    pad: 2 + (style.palette.shadow != nil ? s.size * 0.12 : 0), scale: scale,
                                    shadow: style.palette.shadow, blur: style.palette.shadow != nil ? s.size * 0.08 : 0, opacity: 0)
                gs.forEach { group.addSublayer($0) }
                b.glyphs[k] = gs
            }
            host.addSublayer(group)
        }

        // light a star and draw the line to it when its word is sung
        var tw = SeededRandom(seed &+ 1)
        b.onReveal = { k, instant in
            guard k < starLayers.count else { return }
            let star = starLayers[k], halo = halos[k]
            setQuietly {
                star.opacity = 1
                halo.opacity = 0.35
                links[k]?.strokeEnd = 1
            }
            let twinkle = CAKeyframeAnimation(keyPath: "opacity")
            twinkle.values = [1, 0.55, 1]
            twinkle.duration = 1.6 + tw.next() * 1.8
            twinkle.repeatCount = .infinity
            twinkle.beginTime = CACurrentMediaTime() + (instant ? 0 : 0.6)
            star.add(twinkle, forKey: "twinkle")
            if instant { return }
            let pop = CAKeyframeAnimation(keyPath: "transform.scale")
            pop.values = [0.2, 1.8, 1]
            pop.keyTimes = [0, 0.35, 1]
            pop.duration = 0.6
            star.add(pop, forKey: "pop")
            let flash = CAKeyframeAnimation(keyPath: "opacity")
            flash.values = [0, 1, 0.35]
            flash.keyTimes = [0, 0.3, 1]
            flash.duration = 0.9
            halo.add(flash, forKey: "flash")
            if let link = links[k] {
                let draw = CABasicAnimation(keyPath: "strokeEnd")
                draw.fromValue = 0
                draw.toValue = 1
                draw.duration = 0.45
                draw.timingFunction = timing(0.2, 0.7, 0.2, 1)
                link.add(draw, forKey: "draw")
            }
        }

        // older constellations dim and drift back
        CATransaction.begin()
        CATransaction.setAnimationDuration(1.2)
        // drift away from where the new one appears (up if it is lower, and vice versa)
        let away: CGFloat = flip ? 1 : -1
        for (i, g) in groups.enumerated() {
            g.opacity = i == groups.count - 1 ? 0.12 : 0
            g.transform = CATransform3DScale(g.transform, 0.8, 0.8, 1)
            g.position = CGPoint(x: g.position.x - size.width * 0.04, y: g.position.y + away * size.height * 0.2)
        }
        if !instant { group.opacity = 1 }
        CATransaction.commit()
        groups.append(group)
        while groups.count > 2 {
            let old = groups.removeFirst()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { old.removeFromSuperlayer() }
        }
        return b
    }
}
