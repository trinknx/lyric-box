import AppKit
import QuartzCore

/* "Constellation" style, in 3D. Every word is a star placed at its own depth.
   A line's stars show faintly first (you see the shape); as each word is sung its
   star lights up, a line grows from the previous star through 3D space, and the
   letters are spelled out beside it. The whole sky slowly sways as if dragged by a
   finger, so near words move more than far ones (parallax), while every word keeps
   facing the viewer. Older constellations recede into the distance.

   Layer tree:
     host ─ lens (perspective) ─ orbitX ─ orbitY ─┬─ sky dots (3D)
                                                  └─ group per line ─┬─ line segments (3D)
                                                                     └─ word item ─ counterY ─ counterX ─ star + letters
   counterY/counterX play the orbit animations backwards so the words stay flat to the viewer. */
final class ConstellationCanvas: LyricCanvas {
    private let host = CALayer()
    private let lens = CALayer()
    private let orbitX = CATransformLayer()
    private let orbitY = CATransformLayer()
    private var groups: [CATransformLayer] = []
    private let size: CGSize
    private let t0 = CACurrentMediaTime()

    // the "hand" sway
    private let swayY = 0.36, swayYPeriod = 15.0
    private let swayX = 0.12, swayXPeriod = 10.5

    init(in stage: CALayer, size: CGSize, color: CGColor) {
        self.size = size
        setQuietly {
            host.frame = CGRect(origin: .zero, size: size)
            lens.position = CGPoint(x: size.width * 0.45, y: size.height * 0.5)
            var p = CATransform3DIdentity
            p.m34 = -1 / (size.height * 1.15)
            lens.sublayerTransform = p
            host.addSublayer(lens)
            lens.addSublayer(orbitX)
            orbitX.addSublayer(orbitY)
            stage.addSublayer(host)
        }
        orbitX.add(sway("transform.rotation.x", swayX, swayXPeriod), forKey: "sway")
        orbitY.add(sway("transform.rotation.y", swayY, swayYPeriod), forKey: "sway")
        buildSky(color)
    }

    private func sway(_ key: String, _ amount: Double, _ period: Double, reverse: Bool = false) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: key)
        a.fromValue = reverse ? amount : -amount
        a.toValue = reverse ? -amount : amount
        a.duration = period / 2
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = timing(0.45, 0, 0.55, 1)
        a.beginTime = t0
        return a
    }

    /// A layer that always faces the viewer: inside, put flat content.
    private func billboard(at p: CGPoint, z: CGFloat) -> (item: CATransformLayer, content: CALayer) {
        let item = CATransformLayer()
        item.position = p
        item.zPosition = z
        let cy = CATransformLayer()
        let cx = CALayer()
        item.addSublayer(cy)
        cy.addSublayer(cx)
        cy.add(sway("transform.rotation.y", swayY, swayYPeriod, reverse: true), forKey: "face")
        cx.add(sway("transform.rotation.x", swayX, swayXPeriod, reverse: true), forKey: "face")
        return (item, cx)
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

    /// Background stars spread through depth, twinkling on their own.
    private func buildSky(_ color: CGColor) {
        var r = SeededRandom(99)
        let now = CACurrentMediaTime()
        setQuietly {
            for _ in 0..<170 {
                let d = CGFloat(1.2 + r.next() * 2)
                let dot = CALayer()
                dot.bounds = CGRect(x: 0, y: 0, width: d, height: d)
                dot.cornerRadius = d / 2
                dot.backgroundColor = color
                dot.position = CGPoint(x: CGFloat(r.next() * 2 - 1) * size.width * 0.75,
                                       y: CGFloat(r.next() * 2 - 1) * size.height * 0.7)
                dot.zPosition = CGFloat(-1800 + r.next() * 2200)
                let base = Float(0.1 + r.next() * 0.35)
                dot.opacity = base
                let tw = CABasicAnimation(keyPath: "opacity")
                tw.fromValue = base
                tw.toValue = base * 0.15
                tw.duration = 1.5 + r.next() * 3
                tw.autoreverses = true
                tw.repeatCount = .infinity
                tw.beginTime = now - r.next() * 4
                dot.add(tw, forKey: "twinkle")
                orbitY.addSublayer(dot)
            }
        }
    }

    /// Flat bar from `a` to `b` through 3D space, growing from `a` when drawn.
    private func segment(from a: (CGPoint, CGFloat), to b: (CGPoint, CGFloat), width: CGFloat, color: CGColor) -> (holder: CALayer, bar: CALayer, length: CGFloat) {
        let dx = b.0.x - a.0.x, dy = b.0.y - a.0.y, dz = b.1 - a.1
        let h = hypot(dx, dy)
        let len = sqrt(h * h + dz * dz)
        let holder = CALayer()
        holder.position = a.0
        holder.zPosition = a.1
        // turn the bar's x-axis toward b: first lift out of the plane, then spin around z
        var t = CATransform3DMakeRotation(atan2(dy, dx), 0, 0, 1)
        t = CATransform3DRotate(t, -atan2(dz, h), 0, 1, 0)
        holder.transform = t
        let bar = CALayer()
        bar.anchorPoint = CGPoint(x: 0, y: 0.5)
        bar.bounds = CGRect(x: 0, y: 0, width: len, height: width)
        bar.position = .zero
        bar.backgroundColor = color
        bar.cornerRadius = width / 2
        holder.addSublayer(bar)
        return (holder, bar, len)
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

        // meandering path left → right, each star at its own depth. Spacing is worked out
        // on screen: perspective makes near words bigger, so they get more room.
        struct Star { let p: CGPoint; let z: CGFloat; let attrs: [NSAttributedString.Key: Any]; let line: CTLine; let width: CGFloat; let size: CGFloat; let pf: CGFloat }
        var stars: [Star] = []
        var X: CGFloat = 0, prevY: CGFloat = 0, prevZ: CGFloat = 0
        let swing = style.base * 1.1
        let depth = size.height * 0.32
        let eye = size.height * 1.15
        var minX = CGFloat.infinity, maxX = -CGFloat.infinity, minY = CGFloat.infinity, maxY = -CGFloat.infinity
        for k in texts.indices {
            let s = sizes[k]
            let font = makeFont(.serif, size: s, bold: k == big)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: style.palette.fg, .kern: -0.01 * s]
            let ct = CTLineCreateWithAttributedString(NSAttributedString(string: texts[k], attributes: attrs))
            let w = CGFloat(CTLineGetTypographicBounds(ct, nil, nil, nil))
            var Y: CGFloat = 0
            for _ in 0..<8 {
                Y = CGFloat(r.next() * 2 - 1) * swing
                if k == 0 || abs(Y - prevY) > swing * 0.5 { break }
            }
            var z: CGFloat = 0
            for _ in 0..<8 {
                z = CGFloat(r.next() * 2 - 1) * depth
                if k == 0 || abs(z - prevZ) > depth * 0.4 { break }
            }
            if k == big { z = abs(z) * 0.6 + depth * 0.3 }   // the emphasised word comes forward
            let pf = eye / (eye - z)                         // on-screen magnification at this depth
            stars.append(Star(p: CGPoint(x: X / pf, y: Y / pf), z: z, attrs: attrs, line: ct, width: w, size: s, pf: pf))
            minX = min(minX, X); maxX = max(maxX, X + (s * 0.3 + w) * pf)
            minY = min(minY, Y - s * pf); maxY = max(maxY, Y + s * 0.4 * pf)
            X += (s * 0.3 + w) * pf + style.base * (0.65 + 0.3 * CGFloat(r.next()))
            prevY = Y
            prevZ = z
        }
        let shift = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        let fit = min(1.1, size.width * 0.6 / max(1, maxX - minX), size.height * 0.5 / max(1, maxY - minY))
        let scale = style.backing * fit * 1.35   // near words get magnified by perspective
        let lineWidth = max(1, 1.5 / fit)

        let group = CATransformLayer()
        var starLayers: [CALayer] = [], halos: [CALayer] = []
        var bars: [(bar: CALayer, length: CGFloat)?] = []
        let shadowBlur: (CGFloat) -> CGFloat = { style.palette.shadow != nil ? $0 * 0.08 : 0 }
        setQuietly {
            group.transform = CATransform3DMakeScale(fit, fit, fit)
            b.glyphs = Array(repeating: [], count: texts.count)
            b.sizes = sizes
            for (k, s) in stars.enumerated() {
                let p = CGPoint(x: s.p.x - shift.x / s.pf, y: s.p.y - shift.y / s.pf)
                if k > 0 {
                    let o = stars[k - 1]
                    let q = CGPoint(x: o.p.x - shift.x / o.pf, y: o.p.y - shift.y / o.pf)
                    let seg = segment(from: (q, stars[k - 1].z), to: (p, s.z), width: lineWidth,
                                      color: style.palette.fg.withAlphaComponent(0.5).cgColor)
                    seg.bar.bounds.size.width = 0
                    group.addSublayer(seg.holder)
                    bars.append((seg.bar, seg.length))
                } else {
                    bars.append(nil)
                }

                let (item, content) = billboard(at: p, z: s.z)
                let hr = s.size * 0.5
                let halo = CAGradientLayer()
                halo.type = .radial
                halo.colors = [style.palette.fg.withAlphaComponent(0.55).cgColor, style.palette.fg.withAlphaComponent(0).cgColor]
                halo.startPoint = CGPoint(x: 0.5, y: 0.5)
                halo.endPoint = CGPoint(x: 1, y: 1)
                halo.bounds = CGRect(x: 0, y: 0, width: hr * 2, height: hr * 2)
                halo.position = .zero
                halo.opacity = 0
                content.addSublayer(halo)
                halos.append(halo)

                let rad = max(2.5 / fit, s.size * 0.06)
                let star = CALayer()
                star.bounds = CGRect(x: 0, y: 0, width: rad * 2, height: rad * 2)
                star.cornerRadius = rad
                star.backgroundColor = color
                star.position = .zero
                star.opacity = 0.25   // faint preview of the constellation
                content.addSublayer(star)
                starLayers.append(star)

                let gs = makeGlyphs(texts[k], attrs: s.attrs, line: s.line, at: CGPoint(x: s.size * 0.3, y: s.size * 0.3),
                                    pad: 2 + shadowBlur(s.size) * 1.5, scale: scale,
                                    shadow: style.palette.shadow, blur: shadowBlur(s.size), opacity: 0)
                gs.forEach { content.addSublayer($0) }
                b.glyphs[k] = gs
                group.addSublayer(item)
            }
            orbitY.addSublayer(group)
        }

        // light a star and grow the line to it when its word is sung
        var tw = SeededRandom(seed &+ 1)
        b.onReveal = { k, instant in
            guard k < starLayers.count else { return }
            let star = starLayers[k], halo = halos[k]
            setQuietly {
                star.opacity = 1
                halo.opacity = 0.35
                if let s = bars[k] { s.bar.bounds.size.width = s.length }
            }
            let twinkle = CAKeyframeAnimation(keyPath: "opacity")
            twinkle.values = [1, 0.55, 1]
            twinkle.duration = 1.6 + tw.next() * 1.8
            twinkle.repeatCount = .infinity
            twinkle.beginTime = CACurrentMediaTime() + (instant ? 0 : 0.6)
            star.add(twinkle, forKey: "twinkle")
            if instant { return }
            let pop = CAKeyframeAnimation(keyPath: "transform.scale")
            pop.values = [0.2, 1.9, 1]
            pop.keyTimes = [0, 0.35, 1]
            pop.duration = 0.6
            star.add(pop, forKey: "pop")
            let flash = CAKeyframeAnimation(keyPath: "opacity")
            flash.values = [0, 1, 0.35]
            flash.keyTimes = [0, 0.3, 1]
            flash.duration = 0.9
            halo.add(flash, forKey: "flash")
            if let s = bars[k] {
                let grow = CABasicAnimation(keyPath: "bounds.size.width")
                grow.fromValue = 0
                grow.toValue = s.length
                grow.duration = 0.5
                grow.timingFunction = timing(0.2, 0.7, 0.2, 1)
                s.bar.add(grow, forKey: "grow")
            }
        }

        // new constellation comes out of the distance, older ones recede and dim
        let arrive = CATransform3DMakeScale(fit, fit, fit)
        if !instant {
            let a = CABasicAnimation(keyPath: "transform")
            a.fromValue = CATransform3DTranslate(arrive, 0, 0, -size.height * 0.9 / fit)
            a.toValue = arrive
            a.duration = 1.4
            a.timingFunction = timing(0.2, 0.8, 0.2, 1)
            group.add(a, forKey: "arrive")
            let f = CABasicAnimation(keyPath: "opacity")
            f.fromValue = 0
            f.toValue = 1
            f.duration = 0.9
            group.add(f, forKey: "fade")
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(1.4)
        CATransaction.setAnimationTimingFunction(timing(0.4, 0, 0.2, 1))
        let away: CGFloat = groups.count % 2 == 0 ? 1 : -1
        for (i, g) in groups.enumerated() {
            let back = groups.count - i   // 1 = previous line
            g.opacity = back == 1 ? 0.22 : 0
            g.transform = CATransform3DTranslate(g.transform, 0, away * size.height * 0.3 / max(0.01, fit),
                                                 -size.height * 0.8 / max(0.01, fit))
        }
        CATransaction.commit()
        groups.append(group)
        while groups.count > 2 {
            let old = groups.removeFirst()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { old.removeFromSuperlayer() }
        }
        return b
    }
}
