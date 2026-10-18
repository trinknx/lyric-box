import AppKit
import QuartzCore

/* Abstract graphics for songs without lyrics and for instrumental breaks
   (COTODAMA shows beat graphics there). Everything is built once as repeating
   Core Animation animations, so the render server animates it and the app does no
   per-frame work. One pattern per song, monochrome in the theme colour. */
enum Ambient {
    static let kinds = ["rings", "waves", "dots", "burst"]

    static func make(kind: String, size: CGSize, color: CGColor) -> CALayer {
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: size)
        switch kind {
        case "rings": rings(root, size, color)
        case "waves": waves(root, size, color)
        case "dots": dots(root, size, color)
        default: burst(root, size, color)
        }
        return root
    }

    private static func forever(_ a: CAAnimation, phase: Double = 0) -> CAAnimation {
        a.repeatCount = .infinity
        a.beginTime = CACurrentMediaTime() - phase
        a.isRemovedOnCompletion = false
        return a
    }

    private static func circle(_ r: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2), transform: nil)
    }

    private static func arc(_ r: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.addArc(center: .zero, radius: r, startAngle: 0, endAngle: 0.55, clockwise: false)
        return p
    }

    // ripples travelling outward, each ring carrying a rotating arc
    private static func rings(_ root: CALayer, _ size: CGSize, _ color: CGColor) {
        let R = hypot(size.width, size.height) * 0.48
        let period = 20.0
        for i in 0..<10 {
            let holder = CALayer()
            holder.position = CGPoint(x: size.width / 2, y: size.height / 2)
            root.addSublayer(holder)

            let ring = CAShapeLayer()
            ring.fillColor = nil
            ring.strokeColor = color
            ring.lineWidth = 1.2
            let arcL = CAShapeLayer()
            arcL.fillColor = nil
            arcL.strokeColor = color
            arcL.lineWidth = 3
            arcL.lineCap = .round
            holder.addSublayer(ring)
            holder.addSublayer(arcL)

            let phase = Double(i) / 10 * period
            for (layer, path, alpha) in [(ring, circle, 0.45), (arcL, arc, 0.9)] as [(CAShapeLayer, (CGFloat) -> CGPath, Double)] {
                let grow = CABasicAnimation(keyPath: "path")
                grow.fromValue = path(12)
                grow.toValue = path(R)
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = alpha
                fade.toValue = 0
                fade.timingFunction = timing(0.3, 0.5, 0.6, 1)
                let g = CAAnimationGroup()
                g.animations = [grow, fade]
                g.duration = period
                layer.add(forever(g, phase: phase), forKey: "life")
            }
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = (i % 2 == 0 ? 1 : -1) * 2 * Double.pi
            spin.duration = 2 * .pi / (0.25 + Double(i) * 0.04)
            holder.transform = CATransform3DMakeRotation(CGFloat(i) * 1.7, 0, 0, 1)
            spin.isAdditive = true
            holder.add(forever(spin), forKey: "spin")
        }
    }

    // stacked ridge lines, like a mountain range of sound
    private static func waves(_ root: CALayer, _ size: CGSize, _ color: CGColor) {
        let n = 24, pts = 72, frames = 13
        let W = size.width, H = size.height
        let x0 = W * 0.16, x1 = W * 0.84, y0 = H * 0.24, y1 = H * 0.8
        for i in 0..<n {
            let y = y0 + (y1 - y0) * CGFloat(i) / CGFloat(n - 1)
            var paths: [CGPath] = []
            for f in 0..<frames {
                let t = Double(f) * 0.5
                let p = CGMutablePath()
                for j in 0...pts {
                    let u = Double(j) / Double(pts)
                    let x = x0 + (x1 - x0) * CGFloat(u)
                    let env = exp(-pow((u - 0.5) / 0.2, 2))
                    let fi = Double(i)
                    let v = sin(u * 13 + t * 1.2 + fi * 0.6) * 0.5 + sin(u * 29 - t * 0.8 + fi * 1.7) * 0.3 + sin(u * 6 + t * 0.35 + fi) * 0.2
                    let yy = y - CGFloat(abs(v) * Double(H) * 0.07 * env * (0.65 + 0.35 * sin(t * 0.6 + fi * 0.9)))
                    if j == 0 { p.move(to: CGPoint(x: x, y: yy)) } else { p.addLine(to: CGPoint(x: x, y: yy)) }
                }
                paths.append(p)
            }
            let l = CAShapeLayer()
            l.fillColor = nil
            l.strokeColor = color
            l.lineWidth = 1.5
            l.lineJoin = .round
            l.opacity = Float(0.2 + 0.6 * Double(i) / Double(n))
            l.path = paths[0]
            root.addSublayer(l)
            let a = CAKeyframeAnimation(keyPath: "path")
            a.values = paths
            a.duration = Double(frames - 1) * 0.5
            a.autoreverses = true
            l.add(forever(a), forKey: "wave")
        }
    }

    // dot grid with a ripple running out from the centre
    private static func dots(_ root: CALayer, _ size: CGSize, _ color: CGColor) {
        let cols = 30
        let gap = size.width / CGFloat(cols)
        let rows = max(1, Int((size.height / gap).rounded()))
        let rowGap = size.height / CGFloat(rows)
        let maxR = gap * 0.18
        let period = Double.pi          // sin(d·0.55 − 2t)
        let samples = 16
        var scales: [Double] = [], alphas: [Double] = []
        for s in 0...samples {
            let w = max(0, sin(-2 * period * Double(s) / Double(samples)))
            scales.append((0.05 + 0.13 * w) / 0.18)
            alphas.append(0.12 + 0.6 * w)
        }
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        for y in 0..<rows {
            for x in 0..<cols {
                let p = CGPoint(x: (CGFloat(x) + 0.5) * gap, y: (CGFloat(y) + 0.5) * rowGap)
                let dot = CALayer()
                dot.bounds = CGRect(x: 0, y: 0, width: maxR * 2, height: maxR * 2)
                dot.cornerRadius = maxR
                dot.backgroundColor = color
                dot.position = p
                dot.transform = CATransform3DMakeScale(0.28, 0.28, 1)
                dot.opacity = 0.12
                root.addSublayer(dot)
                let sc = CAKeyframeAnimation(keyPath: "transform.scale")
                sc.values = scales
                let op = CAKeyframeAnimation(keyPath: "opacity")
                op.values = alphas
                let g = CAAnimationGroup()
                g.animations = [sc, op]
                g.duration = period
                // further from the centre = later in the wave
                let d = Double(hypot(p.x - c.x, p.y - c.y) / gap) * 0.55 / 2
                dot.add(forever(g, phase: period - d.truncatingRemainder(dividingBy: period)), forKey: "ripple")
            }
        }
    }

    // slowly turning sunburst of rays
    private static func burst(_ root: CALayer, _ size: CGSize, _ color: CGColor) {
        let n = 80
        let R = min(size.width, size.height) * 0.44
        let holder = CALayer()
        holder.position = CGPoint(x: size.width / 2, y: size.height / 2)
        root.addSublayer(holder)
        var r = SeededRandom(7)
        for i in 0..<n {
            let arm = CALayer()
            arm.transform = CATransform3DMakeRotation(CGFloat(i) / CGFloat(n) * 2 * .pi, 0, 0, 1)
            holder.addSublayer(arm)
            let ray = CALayer()
            ray.anchorPoint = CGPoint(x: 0, y: 0.5)
            ray.bounds = CGRect(x: 0, y: 0, width: R * 0.78, height: 2)
            ray.cornerRadius = 1
            ray.backgroundColor = color
            ray.position = CGPoint(x: R * 0.22, y: 0)
            arm.addSublayer(ray)
            let lo = 0.1 + r.next() * 0.3, hi = 0.6 + r.next() * 0.4
            let sc = CABasicAnimation(keyPath: "transform.scale.x")
            sc.fromValue = lo
            sc.toValue = hi
            let op = CABasicAnimation(keyPath: "opacity")
            op.fromValue = 0.15 + 0.65 * lo
            op.toValue = 0.15 + 0.65 * hi
            let g = CAAnimationGroup()
            g.animations = [sc, op]
            g.duration = 1.6 + r.next() * 2
            g.autoreverses = true
            g.timingFunction = timing(0.45, 0, 0.55, 1)
            ray.transform = CATransform3DMakeScale(CGFloat(lo), 1, 1)
            ray.add(forever(g, phase: r.next() * 4), forKey: "pulse")
        }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = 2 * .pi / 0.06
        holder.add(forever(spin), forKey: "spin")
    }
}
