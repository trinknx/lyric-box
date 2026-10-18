import AppKit
import QuartzCore

/* "Rap" style: one huge word at a time in the middle of the screen, punching in on
   each sung word while the previous one zooms past, with the whole line in small
   type underneath for context. Made for fast flows. */
final class WordZoomCanvas: LyricCanvas {
    private let host = CALayer()
    private let size: CGSize
    private var last: Block?

    init(in stage: CALayer, size: CGSize) {
        self.size = size
        setQuietly {
            host.frame = CGRect(origin: .zero, size: size)
            stage.addSublayer(host)
        }
    }

    func remove() { host.removeFromSuperlayer() }

    func fadeOut() {
        let l = host
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.4)
        CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
        l.opacity = 0
        CATransaction.commit()
    }

    func add(line: Line, seed: UInt32, mood: Mood, style: FlowStyle, stageSize: CGSize, instant: Bool) -> Block {
        if let prev = last {
            let l = prev.layer
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.18)
            CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
            l.opacity = 0
            CATransaction.commit()
        }
        let b = Block()
        let center = CGPoint(x: size.width * 0.45, y: size.height * 0.46)
        let texts = line.words.map { $0.text.uppercased() }
        var holders: [CALayer] = []
        setQuietly {
            b.layer.frame = host.bounds
            b.glyphs = Array(repeating: [], count: texts.count)
            b.sizes = Array(repeating: style.base, count: texts.count)
            for (k, t) in texts.enumerated() {
                var sz = style.base * 2.3 * style.intensity
                var font = makeFont(.impact, size: sz, bold: true)
                var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: style.palette.fg]
                var ct = CTLineCreateWithAttributedString(NSAttributedString(string: t, attributes: attrs))
                let w0 = CGFloat(CTLineGetTypographicBounds(ct, nil, nil, nil))
                if w0 > size.width * 0.8 {   // long words shrink to fit
                    sz *= size.width * 0.8 / w0
                    font = makeFont(.impact, size: sz, bold: true)
                    attrs[.font] = font
                    ct = CTLineCreateWithAttributedString(NSAttributedString(string: t, attributes: attrs))
                }
                let w = CGFloat(CTLineGetTypographicBounds(ct, nil, nil, nil))
                let holder = CALayer()
                holder.position = center
                holder.opacity = 0
                let gs = makeGlyphs(t, attrs: attrs, line: ct, at: CGPoint(x: -w / 2, y: (font.ascender + font.descender) / 2),
                                    pad: 2, scale: style.backing * 1.2, shadow: style.palette.shadow,
                                    blur: style.palette.shadow != nil ? sz * 0.06 : 0, opacity: 0)
                gs.forEach { holder.addSublayer($0) }
                b.layer.addSublayer(holder)
                b.glyphs[k] = gs
                b.sizes[k] = sz
                holders.append(holder)
            }
            // the whole line, small, underneath
            let cap = CATextLayer()
            cap.string = NSAttributedString(string: line.text, attributes: [
                .font: makeFont(.sans, size: style.base * 0.24, bold: false),
                .foregroundColor: style.palette.fg.withAlphaComponent(0.45),
            ])
            cap.alignmentMode = .center
            cap.contentsScale = style.backing
            cap.frame = CGRect(x: size.width * 0.05, y: size.height * 0.74, width: size.width * 0.8, height: style.base * 0.4)
            b.layer.addSublayer(cap)
            host.addSublayer(b.layer)
        }

        b.onReveal = { k, instant in
            guard k < holders.count else { return }
            // earlier words zoom past
            for (i, h) in holders.enumerated() where i < k && h.opacity > 0 {
                setQuietly { h.opacity = 0 }
                if !instant && i == k - 1 {
                    let out = CABasicAnimation(keyPath: "transform.scale")
                    out.fromValue = 1
                    out.toValue = 1.8
                    let fade = CABasicAnimation(keyPath: "opacity")
                    fade.fromValue = 1
                    fade.toValue = 0
                    let g = CAAnimationGroup()
                    g.animations = [out, fade]
                    g.duration = 0.16
                    g.timingFunction = timing(0.5, 0, 1, 1)
                    h.add(g, forKey: "out")
                }
            }
            let h = holders[k]
            setQuietly { h.opacity = 1 }
            if instant { return }
            let punch = CAKeyframeAnimation(keyPath: "transform.scale")
            punch.values = [0.3, 1.1, 1]
            punch.keyTimes = [0, 0.6, 1]
            punch.duration = 0.22
            punch.timingFunctions = [timing(0.2, 0.9, 0.3, 1), timing(0.4, 0, 0.6, 1)]
            h.add(punch, forKey: "punch")
        }
        last = b
        return b
    }
}
