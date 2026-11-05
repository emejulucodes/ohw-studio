import AppKit
import CoreGraphics
import CoreImage

// MARK: - Rendering engine for Face Composer documents
//
// Artwork layers render once into cached images and are composited at their position / rotation.
// Live layers render glyph sets (cached) and are laid out with the preview sample each frame.
// `build()` turns the same document into the watch container.

enum Ink {
    static let ci = CIContext(options: [.useSoftwareRenderer: false])

    static func gradient(_ f: Fill) -> CGGradient {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [f.c1.cg, f.c2.cg] as CFArray, locations: [0, 1])!
    }

    /// Build an image pixel by pixel (no dithering, so the watch's RLE stays efficient).
    /// `f` returns straight (r, g, b, a) in 0...1 for pixel centre (x, y), y-down.
    static func pixels(_ w: Int, _ h: Int, _ f: (Double, Double) -> (Double, Double, Double, Double)) -> CGImage {
        var px = [UInt8](repeating: 0, count: max(1, w * h * 4))
        for y in 0..<h {
            for x in 0..<w {
                let (r, g, b, a) = f(Double(x) + 0.5, Double(y) + 0.5)
                let o = (y * w + x) * 4, aa = max(0, min(1, a))
                px[o] = UInt8(max(0, min(1, r)) * aa * 255 + 0.5); px[o + 1] = UInt8(max(0, min(1, g)) * aa * 255 + 0.5)
                px[o + 2] = UInt8(max(0, min(1, b)) * aa * 255 + 0.5); px[o + 3] = UInt8(aa * 255 + 0.5)
            }
        }
        let prov = CGDataProvider(data: Data(px) as CFData)!
        return CGImage(width: max(1, w), height: max(1, h), bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: max(1, w) * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// Gradient parameter t (0...1) at a point, for a fill laid out over `box`.
    static func gradientT(_ f: Fill, box: CGRect) -> (Double, Double) -> Double {
        let cx = Double(box.midX), cy = Double(box.midY)
        switch f.kind {
        case .linear:
            let a = f.angle * .pi / 180, dx = cos(a), dy = sin(a)
            let half = max(0.5, (abs(Double(box.width) * dx) + abs(Double(box.height) * dy)) / 2)
            return { x, y in ((x - cx) * dx + (y - cy) * dy) / (2 * half) + 0.5 }
        case .radial:
            let r = max(1, Double(max(box.width, box.height)) / 2)
            return { x, y in hypot(x - cx, y - cy) / r }
        case .angular:
            let a0 = (f.angle - 90) * .pi / 180
            return { x, y in
                var t = (atan2(y - cy, x - cx) - a0) / (2 * .pi)
                t -= floor(t)
                return t < 0.5 ? t * 2 : (1 - t) * 2
            }
        default:
            return { _, _ in 0 }
        }
    }

    static func gradientImage(_ f: Fill, size: CGSize, box: CGRect) -> CGImage {
        let tf = gradientT(f, box: box), a = f.c1, b = f.c2
        return pixels(Int(ceil(size.width)), Int(ceil(size.height))) { x, y in
            let t = max(0, min(1, tf(x, y)))
            return (a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t)
        }
    }

    /// Draw a y-down CGImage into a y-down context at `r`.
    static func drawImage(_ img: CGImage, _ ctx: CGContext, _ r: CGRect) {
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.minY + r.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        ctx.restoreGState()
    }

    /// Paint `fill` across `canvas` (respecting the current clip / blend), gradient geometry from `box` (y-down).
    static func paint(_ f: Fill, _ ctx: CGContext, box: CGRect, canvas: CGRect) {
        switch f.kind {
        case .none:
            ctx.clear(canvas)
        case .solid:
            ctx.setFillColor(f.c1.cg); ctx.fill(canvas)
        case .linear, .radial, .angular:
            let local = box.offsetBy(dx: -canvas.minX, dy: -canvas.minY)
            drawImage(gradientImage(f, size: canvas.size, box: local), ctx, canvas)
        }
    }

    /// Replace the colour of `mask` (keeping its alpha) with `fill`.
    static func colorize(_ mask: Canvas, _ f: Fill, box: CGRect? = nil) -> Canvas {
        let out = Canvas(mask.w, mask.h)
        let full = CGRect(x: 0, y: 0, width: mask.w, height: mask.h)
        out.put(mask.cgImage, 0, 0)
        out.ctx.setBlendMode(.sourceIn)
        paint(f, out.ctx, box: box ?? full, canvas: full)
        out.ctx.setBlendMode(.normal)
        return out
    }

    static func shadowed(_ src: Canvas, _ sh: Shadow, alpha: Double = 1) -> Canvas {
        let out = Canvas(src.w, src.h)
        let img = src.cgImage
        out.ctx.setAlpha(CGFloat(alpha))
        if sh.on {
            out.ctx.saveGState()
            out.ctx.setShadow(offset: CGSize(width: sh.dx, height: -sh.dy), blur: CGFloat(sh.radius), color: sh.color.cg)
            for _ in 0..<max(1, sh.passes) { out.put(img, 0, 0) }
            out.ctx.restoreGState()
        }
        out.put(img, 0, 0)
        return out
    }

    static func shadowPad(_ sh: Shadow) -> Int {
        sh.on ? Int(ceil(sh.radius * 1.3 + max(abs(sh.dx), abs(sh.dy)))) + 2 : 0
    }

    static func blurred(_ img: CGImage, _ sigma: Double) -> CGImage {
        guard sigma > 0.3 else { return img }
        let ex = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        let out = CIImage(cgImage: img).clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: ex)
        return ci.createCGImage(out, from: ex) ?? img
    }

    static func decode(_ data: Data, maxPixel: Int = 1600) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let o: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                  kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, o as CFDictionary)
    }

    // MARK: fonts & text

    static func font(_ s: FontSpec) -> NSFont {
        let sz = CGFloat(max(4, s.size))
        var f: NSFont
        if s.design == .custom,
           let c = NSFontManager.shared.font(withFamily: s.family, traits: s.italic ? .italicFontMask : [], weight: s.weight.fm, size: sz) {
            f = c
        } else {
            f = NSFont.systemFont(ofSize: sz, weight: s.weight.ns)
            let d: NSFontDescriptor.SystemDesign? = s.design == .rounded ? .rounded : s.design == .serif ? .serif : s.design == .mono ? .monospaced : nil
            if let d, let desc = f.fontDescriptor.withDesign(d), let nf = NSFont(descriptor: desc, size: sz) { f = nf }
            if s.italic { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
        }
        let mono = f.fontDescriptor.addingAttributes([.featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                                                                          NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]]])
        return NSFont(descriptor: mono, size: sz) ?? f
    }

    struct TextStyle {
        var font: NSFont
        var tracking: CGFloat = 0
        var fill: Fill
        var stroke: Stroke
        var shadow: Shadow
        var alpha: Double = 1

        init(_ l: Layer, fill: Fill? = nil) {
            font = Ink.font(l.font); tracking = CGFloat(l.font.tracking); self.fill = fill ?? l.fill
            stroke = l.stroke; shadow = l.shadow; alpha = l.kind.isLive ? l.opacity : 1
        }
        var pad: Int { Ink.shadowPad(shadow) + (stroke.on ? Int(ceil(stroke.width / 2)) + 1 : 0) + 1 }
        func attrs(_ color: NSColor = .white, align: NSTextAlignment = .center) -> [NSAttributedString.Key: Any] {
            let p = NSMutableParagraphStyle(); p.alignment = align
            return [.font: font, .foregroundColor: color, .kern: tracking, .paragraphStyle: p]
        }
        func width(_ s: String) -> CGFloat { ceil(NSAttributedString(string: s, attributes: attrs()).size().width) }
    }

    /// Render one string. `capBox` sizes the box to the cap height (glyph cells); otherwise to the full text block.
    /// `hPad` narrows the horizontal padding (watch digit cells sit edge to edge, so a wide glow
    /// would push digits apart); the clipped glow is feathered out at the cell edges.
    static func text(_ s: String, _ st: TextStyle, cellWidth: CGFloat? = nil, capBox: Bool, hPad: Int? = nil) -> Canvas {
        let pad = st.pad, hp = min(pad, hPad ?? pad)
        let str = NSAttributedString(string: s, attributes: st.attrs())
        let size = str.boundingRect(with: NSSize(width: 4000, height: 4000), options: [.usesLineFragmentOrigin]).size
        let tw = ceil(size.width), innerW = max(cellWidth ?? tw, 1)
        let boxH = capBox ? ceil(st.font.capHeight) : ceil(size.height)
        let w = Int(innerW) + 2 * hp, h = Int(boxH) + 2 * pad
        let topY = CGFloat(pad) - (capBox ? (st.font.ascender - st.font.capHeight) : 0)
        let rect = NSRect(x: CGFloat(hp) + (innerW - tw) / 2 - 2, y: topY, width: tw + 4, height: ceil(size.height) + 4)
        let box = CGRect(x: CGFloat(hp), y: CGFloat(pad), width: innerW, height: boxH)

        let layer = Canvas(w, h)
        if st.stroke.on {
            var a = st.attrs(); a[.strokeColor] = NSColor.white; a[.strokeWidth] = st.stroke.width / Double(st.font.pointSize) * 200
            let m = Canvas(w, h)
            m.draw { NSAttributedString(string: s, attributes: a).draw(with: rect, options: [.usesLineFragmentOrigin]) }
            layer.put(colorize(m, .solid(st.stroke.color)).cgImage, 0, 0)
        }
        if st.fill.kind != .none {
            let m = Canvas(w, h)
            m.draw { str.draw(with: rect, options: [.usesLineFragmentOrigin]) }
            layer.put(colorize(m, st.fill, box: box).cgImage, 0, 0)
        }
        let out = shadowed(layer, st.shadow, alpha: st.alpha)
        if hp < pad && hp > 0 {
            let fw = Double(hp)
            let ramp = pixels(w, h) { x, _ in
                let e = min(x, Double(w) - x)
                return (0, 0, 0, e < fw ? 1 - e / fw : 0)
            }
            out.ctx.setBlendMode(.destinationOut)
            drawImage(ramp, out.ctx, CGRect(x: 0, y: 0, width: w, height: h))
            out.ctx.setBlendMode(.normal)
        }
        return out
    }

    // MARK: shapes

    static func path(_ l: Layer, in r: CGRect) -> CGPath {
        switch l.shape {
        case .rect: return CGPath(rect: r, transform: nil)
        case .rounded:
            let c = min(l.corner, Double(min(r.width, r.height)) / 2)
            return CGPath(roundedRect: r, cornerWidth: c, cornerHeight: c, transform: nil)
        case .ellipse: return CGPath(ellipseIn: r, transform: nil)
        case .capsule:
            let c = min(r.width, r.height) / 2
            return CGPath(roundedRect: r, cornerWidth: c, cornerHeight: c, transform: nil)
        case .polygon, .star:
            let p = CGMutablePath(), n = max(3, l.sides)
            let pts = l.shape == .star ? n * 2 : n
            for i in 0..<pts {
                let a = Double(i) / Double(pts) * 2 * .pi - .pi / 2
                let k = l.shape == .star && i % 2 == 1 ? 0.45 : 1.0
                let pt = CGPoint(x: r.midX + r.width / 2 * k * cos(a), y: r.midY + r.height / 2 * k * sin(a))
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
            p.closeSubpath()
            return p
        }
    }

    static func shapeArt(_ l: Layer) -> Canvas {
        let pad = shadowPad(l.shadow) + (l.stroke.on ? Int(ceil(l.stroke.width)) : 0) + 2
        let w = Int(ceil(l.w)) + 2 * pad, h = Int(ceil(l.h)) + 2 * pad
        let r = CGRect(x: CGFloat(pad), y: CGFloat(pad), width: l.w, height: l.h)
        let pth = path(l, in: r)
        let c = Canvas(w, h)
        if l.fill.kind != .none {
            c.ctx.saveGState(); c.ctx.addPath(pth); c.ctx.clip()
            paint(l.fill, c.ctx, box: r, canvas: CGRect(x: 0, y: 0, width: w, height: h))
            c.ctx.restoreGState()
        }
        if l.stroke.on {
            c.ctx.addPath(pth); c.ctx.setStrokeColor(l.stroke.color.cg); c.ctx.setLineWidth(l.stroke.width); c.ctx.strokePath()
        }
        return shadowed(c, l.shadow)
    }

    // MARK: ring

    static func ringArt(_ l: Layer) -> Canvas {
        let pad = shadowPad(l.shadow) + Int(l.lineWidth / 2) + 2
        let d = Int(ceil(l.w)), w = d + 2 * pad
        let c = Canvas(w, w)
        let cx = CGFloat(w) / 2, rad = CGFloat(l.w / 2 - l.lineWidth / 2)
        let ctx = c.ctx
        func arc(_ a0: Double, _ a1: Double, color: RGBA, caps: Bool) {
            guard a1 > a0 else { return }
            let p = CGMutablePath()
            p.addArc(center: CGPoint(x: cx, y: cx), radius: rad, startAngle: (a0 - 90) * .pi / 180, endAngle: (a1 - 90) * .pi / 180, clockwise: false)
            ctx.addPath(p); ctx.setStrokeColor(color.cg); ctx.setLineWidth(l.lineWidth)
            ctx.setLineCap(caps && l.roundCaps ? .round : .butt); ctx.strokePath()
        }
        let start = l.ringStart, sweep = max(1, min(360, l.ringSweep))
        let segs = max(0, l.segments), gap = segs > 0 ? min(8.0, sweep / Double(segs) * 0.35) : 0
        let filledTo = start + sweep * max(0, min(1, l.ringProgress))

        func spans(_ from: Double, _ to: Double) -> [(Double, Double)] {
            if to <= from { return [] }
            if segs == 0 { return [(from, to)] }
            let step = sweep / Double(segs)
            return (0..<segs).map { (start + Double($0) * step + gap / 2, start + Double($0 + 1) * step - gap / 2) }
                .compactMap { s in let a = max(s.0, from), b = min(s.1, to); return b > a ? (a, b) : nil }
        }
        if l.trackColor.a > 0.001 { for s in spans(start, start + sweep) { arc(s.0, s.1, color: l.trackColor, caps: true) } }
        let grad = l.fill.kind != .solid && l.fill.kind != .none
        for s in spans(start, filledTo) {
            if !grad { arc(s.0, s.1, color: l.fill.c1, caps: true); continue }
            // gradient along the arc: many short butt-capped pieces + coloured caps
            let n = max(2, Int((s.1 - s.0) / 1.5))
            for i in 0..<n {
                let a0 = s.0 + (s.1 - s.0) * Double(i) / Double(n), a1 = s.0 + (s.1 - s.0) * Double(i + 1) / Double(n) + 0.4
                let t = ((a0 - start) / max(1, filledTo - start))
                arc(a0, min(a1, s.1), color: l.fill.c1.mix(l.fill.c2, t), caps: false)
            }
            if l.roundCaps {
                for (a, t) in [(s.0, (s.0 - start) / max(1, filledTo - start)), (s.1, (s.1 - start) / max(1, filledTo - start))] {
                    let rr = (a - 90) * .pi / 180
                    ctx.setFillColor(l.fill.c1.mix(l.fill.c2, t).cg)
                    ctx.fillEllipse(in: CGRect(x: cx + rad * cos(rr) - l.lineWidth / 2, y: cx + rad * sin(rr) - l.lineWidth / 2,
                                               width: l.lineWidth, height: l.lineWidth))
                }
            }
        }
        return shadowed(c, l.shadow)
    }

    // MARK: dial

    static let roman = ["XII", "I", "II", "III", "IIII", "V", "VI", "VII", "VIII", "IX", "X", "XI"]

    static func dialArt(_ l: Layer) -> Canvas {
        let d = l.dial
        let pad = shadowPad(l.shadow) + 4
        let w = Int(ceil(l.w)) + 2 * pad, h = Int(ceil(l.h)) + 2 * pad
        let c = Canvas(w, h)
        let cx = CGFloat(w) / 2, cy = CGFloat(h) / 2
        let hw = CGFloat(l.w) / 2, hh = CGFloat(l.h) / 2
        // distance from centre to the dial edge along angle a (0 = 12 o'clock, clockwise)
        func edge(_ a: CGFloat, inset: CGFloat) -> CGFloat {
            if d.shape == .circle { return min(hw, hh) - inset }
            let s = abs(sin(a)), co = abs(cos(a))
            let ex = s > 1e-6 ? (hw - inset) / s : .greatestFiniteMagnitude
            let ey = co > 1e-6 ? (hh - inset) / co : .greatestFiniteMagnitude
            return min(ex, ey)
        }
        func pt(_ a: CGFloat, _ r: CGFloat) -> CGPoint { CGPoint(x: cx + r * sin(a), y: cy - r * cos(a)) }
        let ctx = c.ctx
        ctx.setLineCap(.round)
        if d.ticks > 0 {
            for k in 0..<d.ticks {
                let a = CGFloat(k) / CGFloat(d.ticks) * 2 * .pi
                let major = d.majorEvery > 0 && k % d.majorEvery == 0
                let r1 = edge(a, inset: 2), len = CGFloat(major ? d.majorLength : d.minorLength)
                let r0 = r1 - len
                let col = major ? (k == 0 && d.accentTop ? d.accent : d.majorColor) : d.minorColor
                ctx.setStrokeColor(col.cg); ctx.setLineWidth(major ? d.majorWidth : d.minorWidth)
                ctx.move(to: pt(a, r0)); ctx.addLine(to: pt(a, r1)); ctx.strokePath()
            }
        }
        if d.numerals != .none {
            let f = font(d.numeralFont)
            for i in 0..<12 {
                if d.numerals == .quarters && i % 3 != 0 { continue }
                if d.hideThree && i == 3 { continue }
                let a = CGFloat(i) / 12 * 2 * .pi
                let r = edge(a, inset: CGFloat(d.numeralInset))
                let p = pt(a, r)
                let col = i == 0 && d.accentTop ? d.accent : d.numeralColor
                if d.numerals == .dots {
                    let rr = CGFloat(i % 3 == 0 ? d.numeralFont.size * 0.2 : d.numeralFont.size * 0.12)
                    ctx.setFillColor(col.cg); ctx.fillEllipse(in: CGRect(x: p.x - rr, y: p.y - rr, width: 2 * rr, height: 2 * rr))
                    continue
                }
                let label = d.numerals == .roman ? roman[i] : "\(i == 0 ? 12 : i)"
                let s = NSAttributedString(string: label, attributes: [.font: f, .foregroundColor: col.ns, .kern: d.numeralFont.tracking])
                let sz = s.size()
                c.draw { s.draw(at: NSPoint(x: p.x - sz.width / 2, y: p.y - f.capHeight / 2 - (f.ascender - f.capHeight))) }
            }
        }
        return shadowed(c, l.shadow)
    }

    // MARK: glow, symbol, image, text block

    static func glowArt(_ l: Layer) -> Canvas {
        let w = max(2, Int(ceil(l.w))), h = max(2, Int(ceil(l.h)))
        let c = Canvas(w, h)
        let soft = max(0.05, min(1, l.softness)), col = l.fill.c1
        let rx = Double(w) / 2, ry = Double(h) / 2
        let img = pixels(w, h) { x, y in
            let d = hypot((x - rx) / rx, (y - ry) / ry)
            var k = d <= 1 - soft ? 1 : max(0, (1 - d) / soft)
            k = k * k * (3 - 2 * k)                       // smoothstep falloff
            return (col.r, col.g, col.b, col.a * k)
        }
        drawImage(img, c.ctx, CGRect(x: 0, y: 0, width: w, height: h))
        return c
    }

    static func symbolArt(_ l: Layer) -> Canvas {
        let cfg = NSImage.SymbolConfiguration(pointSize: CGFloat(l.font.size), weight: l.font.weight.ns)
        let img = NSImage(systemSymbolName: l.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
            ?? NSImage(systemSymbolName: "questionmark.square.dashed", accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
        let pad = shadowPad(l.shadow) + 2
        let s = img.size
        let w = Int(ceil(s.width)) + 2 * pad, h = Int(ceil(s.height)) + 2 * pad
        let m = Canvas(w, h)
        m.draw {
            img.draw(in: NSRect(x: CGFloat(pad), y: CGFloat(pad), width: s.width, height: s.height), from: .zero,
                     operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let box = CGRect(x: CGFloat(pad), y: CGFloat(pad), width: s.width, height: s.height)
        return shadowed(colorize(m, l.fill.kind == .none ? .solid(.white) : l.fill, box: box), l.shadow)
    }

    static func imageArt(_ l: Layer, _ img: CGImage?) -> Canvas {
        let pad = shadowPad(l.shadow) + (l.stroke.on ? Int(ceil(l.stroke.width)) : 0) + 2
        let w = Int(ceil(l.w)) + 2 * pad, h = Int(ceil(l.h)) + 2 * pad
        let r = CGRect(x: CGFloat(pad), y: CGFloat(pad), width: l.w, height: l.h)
        let c = Canvas(w, h)
        let pth = path(l, in: r)
        c.ctx.saveGState(); c.ctx.addPath(pth); c.ctx.clip()
        if let img {
            let iw = CGFloat(img.width), ih = CGFloat(img.height)
            let sc = max(r.width / iw, r.height / ih)
            c.put(img, r.midX - iw * sc / 2, r.midY - ih * sc / 2, iw * sc, ih * sc)
        } else {
            c.ctx.setFillColor(RGBA(0x2C2C2E).cg); c.ctx.fill(r)
        }
        if l.fill.kind != .none {   // optional tint overlay
            paint(l.fill, c.ctx, box: r, canvas: r)
        }
        c.ctx.restoreGState()
        if l.stroke.on {
            c.ctx.addPath(pth); c.ctx.setStrokeColor(l.stroke.color.cg); c.ctx.setLineWidth(l.stroke.width); c.ctx.strokePath()
        }
        return shadowed(c, l.shadow)
    }

    // MARK: hands

    static func hand(_ s: HandsSpec, length: Double, width: Double, color: RGBA, cap: Bool) -> Canvas {
        let len = CGFloat(min(148, max(10, length))), tail = CGFloat(min(28, max(0, s.tail)))
        let wd = CGFloat(max(1, width))
        let cw = (Int(max(wd * 2.6, cap ? s.capSize * 2 : 0, 6)) + 8) / 2 * 2
        let c = Canvas(cw, 300)
        let cx = CGFloat(cw) / 2, py: CGFloat = 150
        let p = CGMutablePath()
        switch s.style {
        case .baton, .skeleton:
            p.addRoundedRect(in: CGRect(x: cx - wd / 2, y: py - len, width: wd, height: len + tail), cornerWidth: wd / 2, cornerHeight: wd / 2)
        case .sword:
            p.move(to: CGPoint(x: cx - wd / 2, y: py + tail)); p.addLine(to: CGPoint(x: cx + wd / 2, y: py + tail))
            p.addLine(to: CGPoint(x: cx + wd / 2, y: py - len * 0.82)); p.addLine(to: CGPoint(x: cx, y: py - len))
            p.addLine(to: CGPoint(x: cx - wd / 2, y: py - len * 0.82)); p.closeSubpath()
        case .dauphine:
            p.move(to: CGPoint(x: cx, y: py - len)); p.addLine(to: CGPoint(x: cx + wd * 0.75, y: py - len * 0.08))
            p.addLine(to: CGPoint(x: cx, y: py + tail)); p.addLine(to: CGPoint(x: cx - wd * 0.75, y: py - len * 0.08)); p.closeSubpath()
        case .needle:
            p.addRoundedRect(in: CGRect(x: cx - wd / 2, y: py - len, width: wd, height: len + tail), cornerWidth: wd / 2, cornerHeight: wd / 2)
            if tail > 6 { p.addEllipse(in: CGRect(x: cx - wd * 2.2, y: py + tail * 0.55 - wd * 2.2, width: wd * 4.4, height: wd * 4.4)) }
        }
        let ctx = c.ctx
        ctx.saveGState()
        if s.shadow { ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 4, color: NSColor.black.withAlphaComponent(0.6).cgColor) }
        ctx.addPath(p)
        if s.style == .skeleton {
            ctx.setStrokeColor(color.cg); ctx.setLineWidth(1.6); ctx.strokePath()
        } else {
            ctx.setFillColor(color.cg); ctx.fillPath()
        }
        ctx.restoreGState()
        if s.lume || s.style == .skeleton, s.style != .needle, wd >= 4 {
            let inset = max(1.5, wd * 0.25)
            let lr = CGRect(x: cx - wd / 2 + inset, y: py - len + inset * 2, width: wd - 2 * inset, height: len * 0.62)
            ctx.setFillColor(s.lumeColor.cg)
            ctx.addPath(CGPath(roundedRect: lr, cornerWidth: lr.width / 2, cornerHeight: lr.width / 2, transform: nil)); ctx.fillPath()
        }
        if cap {
            let r = CGFloat(s.capSize)
            ctx.setFillColor(s.capColor.cg); ctx.fillEllipse(in: CGRect(x: cx - r, y: py - r, width: 2 * r, height: 2 * r))
            ctx.setFillColor(NSColor.black.cgColor); ctx.fillEllipse(in: CGRect(x: cx - 1.8, y: py - 1.8, width: 3.6, height: 3.6))
        }
        return c
    }
}

// MARK: - live layer glyphs

struct LiveGlyphs {
    var a: [Canvas]
    var b: [Canvas] = []
    var cw: Int, ch: Int
    var sep: Canvas? = nil
    var sepW: CGFloat = 0
    var hands: [Canvas] = []        // hour, minute, (second)
}

final class ComposerEngine {
    private var art: [Int: (Canvas, CGImage)] = [:]
    private var glyphs: [Int: LiveGlyphs] = [:]
    private var images: [Int: CGImage] = [:]
    private var bgCache: (Int, CGImage)?

    static let weekdayNames = ["SUNDAY", "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY"]
    static func names(_ s: NameStyle) -> [String] {
        weekdayNames.map { n in
            switch s {
            case .upper: return String(n.prefix(3))
            case .title: return String(n.prefix(3)).capitalized
            case .full: return n
            case .letter: return String(n.prefix(1))
            }
        }
    }

    /// Content identity of a layer (position, name and visibility don't change its pixels).
    static func key(_ l: Layer) -> Int {
        var k = l
        k.id = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        k.x = 0; k.y = 0; k.name = ""; k.visible = true; k.locked = false
        if !l.kind.isLive { k.rotation = 0; k.opacity = 1; k.blend = .normal }
        return k.hashValue
    }

    func trim() {
        if art.count > 160 { art.removeAll() }
        if glyphs.count > 80 { glyphs.removeAll() }
        if images.count > 24 { images.removeAll() }
    }

    func decoded(_ d: Data?) -> CGImage? {
        guard let d else { return nil }
        let k = d.hashValue
        if let i = images[k] { return i }
        let i = Ink.decode(d)
        images[k] = i
        return i
    }

    // MARK: artwork

    func artwork(_ l: Layer) -> (Canvas, CGImage) {
        let k = Self.key(l)
        if let a = art[k] { return a }
        let c: Canvas
        switch l.kind {
        case .shape: c = Ink.shapeArt(l)
        case .ring: c = Ink.ringArt(l)
        case .dial: c = Ink.dialArt(l)
        case .glow: c = Ink.glowArt(l)
        case .symbol: c = Ink.symbolArt(l)
        case .image: c = Ink.imageArt(l, decoded(l.imageData))
        default: c = Ink.text(l.text, Ink.TextStyle(l), capBox: false)
        }
        let v = (c, c.cgImage)
        art[k] = v
        return v
    }

    // MARK: live

    func live(_ l: Layer) -> LiveGlyphs {
        let k = Self.key(l)
        if let g = glyphs[k] { return g }
        var g: LiveGlyphs
        let digits = (0...9).map(String.init)
        func set(_ strings: [String], _ fill: Fill) -> [Canvas] {
            let st = Ink.TextStyle(l, fill: fill)
            let cell = strings.map { st.width($0) }.max() ?? 1
            let hp = max(2, Int(l.font.size * 0.05)) + (l.stroke.on ? Int(ceil(l.stroke.width / 2)) + 1 : 0)
            return strings.map { Ink.text($0, st, cellWidth: cell, capBox: true, hPad: hp) }
        }
        switch l.kind {
        case .time:
            let a = set(digits, l.fill), b = set(digits, l.fill2)
            g = LiveGlyphs(a: a, b: b, cw: a[0].w, ch: a[0].h)
            if l.timeLayout == .inline {
                g.sepW = CGFloat(max(0, l.spacing))
                if l.separator != .none { g.sep = separator(l, height: g.ch, width: g.sepW) }
            }
        case .date, .month, .seconds:
            let a = set(digits, l.fill); g = LiveGlyphs(a: a, cw: a[0].w, ch: a[0].h)
        case .weekday:
            let a = set(Self.names(l.nameStyle), l.fill); g = LiveGlyphs(a: a, cw: a[0].w, ch: a[0].h)
        case .ampm:
            let lower = l.nameStyle == .title
            let a = set(lower ? ["am", "pm"] : ["AM", "PM"], l.fill); g = LiveGlyphs(a: a, cw: a[0].w, ch: a[0].h)
        case .steps, .heart, .calories, .distance, .battery:
            let a = set(digits + ["."], l.fill); g = LiveGlyphs(a: a, cw: a[0].w, ch: a[0].h)
        case .hands:
            let s = l.hands
            var hs = [Ink.hand(s, length: s.hourLength, width: s.hourWidth, color: s.hourColor, cap: false),
                      Ink.hand(s, length: s.minuteLength, width: s.minuteWidth, color: s.minuteColor, cap: !s.showSeconds)]
            if s.showSeconds { hs.append(Ink.hand(s, length: s.secondLength, width: s.secondWidth, color: s.secondColor, cap: true)) }
            g = LiveGlyphs(a: [], cw: 0, ch: 0, hands: hs)
        default:
            g = LiveGlyphs(a: [], cw: 0, ch: 0)
        }
        glyphs[k] = g
        return g
    }

    private func separator(_ l: Layer, height: Int, width: CGFloat) -> Canvas {
        let st = Ink.TextStyle(l)
        let pad = st.pad
        let w = Int(ceil(width)) + 2 * pad
        let m = Canvas(max(2, w), height)
        let cap = CGFloat(height - 2 * pad), cx = CGFloat(w) / 2, top = CGFloat(pad)
        let r = max(2, CGFloat(l.font.size) * (l.font.weight.fm >= 9 ? 0.06 : 0.042))
        m.ctx.setFillColor(NSColor.white.cgColor)
        switch l.separator {
        case .colon:
            for f in [0.3, 0.7] as [CGFloat] { m.ctx.fillEllipse(in: CGRect(x: cx - r, y: top + cap * f - r, width: 2 * r, height: 2 * r)) }
        case .dot:
            m.ctx.fillEllipse(in: CGRect(x: cx - r * 1.2, y: top + cap * 0.5 - r * 1.2, width: 2.4 * r, height: 2.4 * r))
        case .bar:
            m.ctx.addPath(CGPath(roundedRect: CGRect(x: cx - r * 0.6, y: top + cap * 0.12, width: r * 1.2, height: cap * 0.76),
                                 cornerWidth: r * 0.6, cornerHeight: r * 0.6, transform: nil)); m.ctx.fillPath()
        case .none: break
        }
        let box = CGRect(x: 0, y: top, width: CGFloat(w), height: cap)
        return Ink.shadowed(Ink.colorize(m, st.fill, box: box), st.shadow, alpha: st.alpha)
    }

    /// Value strings shown for a live layer with the given sample.
    static func valueIndices(_ l: Layer, _ s: Sample, twelveHour: Bool) -> [Int] {
        func two(_ v: Int) -> [Int] { [v / 10 % 10, v % 10] }
        func digits(_ str: String) -> [Int] { str.compactMap { $0 == "." ? 10 : Int(String($0)) } }
        switch l.kind {
        case .date: return two(s.day)
        case .month: return two(s.month)
        case .seconds: return two(s.second)
        case .weekday: return [s.weekday]
        case .ampm: return [s.hour >= 12 ? 1 : 0]
        case .steps: return digits("\(s.steps)")
        case .heart: return digits("\(s.heart)")
        case .calories: return digits("\(s.kcal)")
        case .distance: return digits(String(format: "%.1f", s.distance))
        case .battery: return digits("\(s.battery)")
        default: return []
        }
    }

    /// Unrotated content bounds in watch coordinates.
    func bounds(_ l: Layer, sample: Sample = .classic, twelveHour: Bool = false) -> CGRect {
        let c = CGPoint(x: l.x, y: l.y)
        if !l.kind.isLive {
            let (cv, _) = artwork(l)
            var sz = CGSize(width: cv.w, height: cv.h)
            if l.hasSize { sz = CGSize(width: l.w, height: l.h) }
            else if l.kind == .text || l.kind == .symbol {
                let p = CGFloat(l.kind == .text ? Ink.TextStyle(l).pad : Ink.shadowPad(l.shadow) + 2)
                sz = CGSize(width: max(4, CGFloat(cv.w) - 2 * p), height: max(4, CGFloat(cv.h) - 2 * p))
            }
            return CGRect(x: c.x - sz.width / 2, y: c.y - sz.height / 2, width: sz.width, height: sz.height)
        }
        let g = live(l)
        switch l.kind {
        case .hands:
            let r = CGFloat(max(l.hands.minuteLength, l.hands.showSeconds ? l.hands.secondLength : 0, l.hands.hourLength))
            return CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        case .time:
            let sz = timeSize(l, g)
            return CGRect(x: c.x - sz.width / 2, y: c.y - sz.height / 2, width: sz.width, height: sz.height)
        default:
            let n = CGFloat(max(1, Self.valueIndices(l, sample, twelveHour: twelveHour).count))
            let w = CGFloat(g.cw) * n
            return CGRect(x: c.x - w / 2, y: c.y - CGFloat(g.ch) / 2, width: w, height: CGFloat(g.ch))
        }
    }

    func timeSize(_ l: Layer, _ g: LiveGlyphs) -> CGSize {
        l.timeLayout == .inline
            ? CGSize(width: CGFloat(4 * g.cw) + g.sepW, height: CGFloat(g.ch))
            : CGSize(width: CGFloat(2 * g.cw), height: CGFloat(2 * g.ch) + CGFloat(l.spacing))
    }

    /// Top-left origins of the hour and minute elements.
    func timeOrigins(_ l: Layer, _ g: LiveGlyphs) -> (CGPoint, CGPoint) {
        let sz = timeSize(l, g)
        let x0 = (l.x - sz.width / 2).rounded(), y0 = (l.y - sz.height / 2).rounded()
        if l.timeLayout == .inline {
            return (CGPoint(x: x0, y: y0), CGPoint(x: x0 + CGFloat(2 * g.cw) + g.sepW.rounded(), y: y0))
        }
        return (CGPoint(x: x0, y: y0), CGPoint(x: x0, y: y0 + CGFloat(g.ch) + CGFloat(l.spacing).rounded()))
    }

    // MARK: compositing

    private func drawArtwork(_ l: Layer, on c: Canvas) {
        let (cv, img) = artwork(l)
        let ctx = c.ctx
        if l.kind == .shape && l.material == .glass {
            let snap = Ink.blurred(c.cgImage, l.glassBlur)
            ctx.saveGState()
            ctx.translateBy(x: l.x, y: l.y); ctx.rotate(by: l.rotation * .pi / 180)
            ctx.addPath(Ink.path(l, in: CGRect(x: -l.w / 2, y: -l.h / 2, width: l.w, height: l.h))); ctx.clip()
            ctx.rotate(by: -l.rotation * .pi / 180); ctx.translateBy(x: -l.x, y: -l.y)
            ctx.setAlpha(l.opacity)
            c.put(snap, 0, 0)
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.translateBy(x: l.x, y: l.y)
        ctx.rotate(by: l.rotation * .pi / 180)
        ctx.setAlpha(l.opacity)
        ctx.setBlendMode(l.blend.cg)
        c.put(img, -CGFloat(cv.w) / 2, -CGFloat(cv.h) / 2)
        ctx.restoreGState()
    }

    func backgroundImage(_ b: BackgroundSpec) -> CGImage {
        let k = b.hashValue
        if let c = bgCache, c.0 == k { return c.1 }
        let W = FaceKit.W, H = FaceKit.H
        let c = Canvas(W, H)
        let full = CGRect(x: 0, y: 0, width: W, height: H)
        c.ctx.setFillColor(NSColor.black.cgColor); c.ctx.fill(full)
        if b.kind == .photo, let ph = decoded(b.photo) {
            let iw = CGFloat(ph.width), ih = CGFloat(ph.height)
            let sc = max(CGFloat(W) / iw, CGFloat(H) / ih) * CGFloat(max(1, b.zoom))
            let dw = iw * sc, dh = ih * sc
            let x = -(dw - CGFloat(W)) * CGFloat(b.focusX), y = -(dh - CGFloat(H)) * CGFloat(b.focusY)
            let tmp = Canvas(W, H)
            tmp.put(ph, x, y, dw, dh)
            c.put(Ink.blurred(tmp.cgImage, b.blur), 0, 0)
            if b.dim > 0 { c.ctx.setFillColor(NSColor.black.withAlphaComponent(b.dim).cgColor); c.ctx.fill(full) }
        } else {
            Ink.paint(b.fill, c.ctx, box: full, canvas: full)
        }
        if b.tint.a > 0 { c.ctx.setFillColor(b.tint.cg); c.ctx.fill(full) }
        if b.vignette > 0 {
            let v = b.vignette, cx = Double(W) / 2, cy = Double(H) / 2
            let img = Ink.pixels(W, H) { x, y in
                let d = hypot(x - cx, y - cy) / 330
                let k = max(0, min(1, (d - 0.35) / 0.65))
                return (0, 0, 0, v * k * k)
            }
            Ink.drawImage(img, c.ctx, full)
        }
        let img = c.cgImage
        bgCache = (k, img)
        return img
    }

    /// Background + artwork + the static parts of live layers (separators).
    func composeBackground(_ doc: FaceDoc) -> Canvas {
        let c = Canvas(FaceKit.W, FaceKit.H)
        c.put(backgroundImage(doc.background), 0, 0)
        for l in doc.layers where l.visible && !l.kind.isLive { drawArtwork(l, on: c) }
        for l in doc.layers where l.visible && l.kind == .time {
            let g = live(l)
            if let sep = g.sep {
                let (h, _) = timeOrigins(l, g)
                c.put(sep.cgImage, h.x + CGFloat(2 * g.cw) - CGFloat(sep.w - Int(ceil(g.sepW))) / 2, h.y)
            }
        }
        return c
    }

    func twelveHour(_ doc: FaceDoc) -> Bool { doc.layers.contains { $0.kind == .ampm && $0.visible } }

    /// Draw live layers with sample values (what the watch will show).
    func drawLive(_ doc: FaceDoc, _ s: Sample, on c: Canvas) {
        let tw = twelveHour(doc)
        let liveLayers = doc.layers.filter { $0.visible && $0.kind.isLive }
        for l in liveLayers.filter({ $0.kind != .hands }) {
            let g = live(l)
            switch l.kind {
            case .time:
                var h = s.hour
                if tw { h = h % 12; if h == 0 { h = 12 } }
                let (ho, mo) = timeOrigins(l, g)
                for (i, d) in [h / 10, h % 10].enumerated() { c.put(g.a[d].cgImage, ho.x + CGFloat(i * g.cw), ho.y) }
                for (i, d) in [s.minute / 10, s.minute % 10].enumerated() { c.put(g.b[d].cgImage, mo.x + CGFloat(i * g.cw), mo.y) }
            default:
                let idx = Self.valueIndices(l, s, twelveHour: tw)
                let b = bounds(l, sample: s, twelveHour: tw)
                for (i, d) in idx.enumerated() where d < g.a.count {
                    c.put(g.a[d].cgImage, b.minX.rounded() + CGFloat(i * g.cw), b.minY.rounded())
                }
            }
        }
        for l in liveLayers where l.kind == .hands {
            let g = live(l)
            let hA = (Double(s.hour % 12) + Double(s.minute) / 60) * 30, mA = Double(s.minute) * 6 + Double(s.second) / 10, sA = Double(s.second) * 6
            for (hc, deg) in zip(g.hands, [hA, mA, sA]) {
                c.putRotated(hc.cgImage, pivotX: CGFloat(hc.w) / 2, pivotY: 150, at: l.x, l.y, degrees: deg)
            }
        }
    }

    func preview(_ doc: FaceDoc, _ s: Sample) -> CGImage {
        let c = composeBackground(doc)
        drawLive(doc, s, on: c)
        trim()
        return c.cgImage
    }

    // MARK: build for the watch

    func build(_ doc: FaceDoc) -> FaceBuild {
        typealias E = FaceKit.Element
        let bg = composeBackground(doc)
        var els: [E] = [], handEls: [E] = []
        let tw = twelveHour(doc)
        for l in doc.layers where l.visible && l.kind.isLive {
            let g = live(l)
            func el(_ t: UInt8, _ set: [Canvas], _ p: CGPoint, gravity: UInt8 = FaceKit.gravityTopLeft) -> E {
                E(type: t, alpha: true, w: g.cw, h: g.ch, gravity: gravity, x: Int(p.x), y: Int(p.y),
                  images: set.map { FaceKit.jlConvert(Self.compact($0.rgba), alpha: true) })
            }
            switch l.kind {
            case .time:
                let (h, m) = timeOrigins(l, g)
                els.append(el(FaceKit.T.hour, g.a, h)); els.append(el(FaceKit.T.minute, g.b, m))
            case .date, .month, .seconds:
                let p = CGPoint(x: (l.x - CGFloat(g.cw)).rounded(), y: (l.y - CGFloat(g.ch) / 2).rounded())
                els.append(el(l.kind.elementTypes[0], g.a, p))
            case .weekday, .ampm:
                let p = CGPoint(x: (l.x - CGFloat(g.cw) / 2).rounded(), y: (l.y - CGFloat(g.ch) / 2).rounded())
                els.append(el(l.kind.elementTypes[0], g.a, p))
            case .steps, .heart, .calories, .distance, .battery:
                els.append(el(l.kind.elementTypes[0], g.a, CGPoint(x: l.x.rounded(), y: l.y.rounded()), gravity: FaceKit.gravityCenter))
            case .hands:
                for (t, hc) in zip([FaceKit.T.hourHand, FaceKit.T.minuteHand, FaceKit.T.secondHand], g.hands) {
                    let part = hc.rgba.cropped(height: 180)
                    handEls.append(E(type: t, alpha: true, w: hc.w, h: 180, gravity: FaceKit.gravityTopLeft, x: Int(l.x), y: Int(l.y),
                                     images: [FaceKit.rawARGB8565(part)], ignoreBlack: 1,
                                     bottomOffset: UInt8(180 - 150), leftOffset: UInt8(hc.w / 2)))
                }
            default: break
            }
        }
        _ = tw
        let pv = FaceDesigner.clone(bg)
        drawLive(doc, .classic, on: pv)
        return FaceDesigner.finish(bg, els + handEls, preview: pv)
    }

    /// Snap soft alpha (glows, shadows) to 16 levels and drop near-invisible pixels so the
    /// watch's run-length encoding can compress them. Visually lossless at watch size.
    static func compact(_ img: RGBAImage) -> RGBAImage {
        var o = img
        for i in stride(from: 0, to: o.px.count, by: 4) {
            let a = Int(o.px[i + 3])
            if a < 10 { o.px[i] = 0; o.px[i + 1] = 0; o.px[i + 2] = 0; o.px[i + 3] = 0; continue }
            if a > 245 { o.px[i + 3] = 255; continue }
            let q = (a + 8) / 17 * 17
            o.px[i + 3] = UInt8(min(255, q))
            if a < 200 {    // colour of soft edges: snap to a coarser grid as well
                for c in 0..<3 { o.px[i + c] = UInt8(min(255, (Int(o.px[i + c]) + 8) / 16 * 16)) }
            }
        }
        return o
    }

    // MARK: hit testing

    func hit(_ doc: FaceDoc, _ p: CGPoint, sample: Sample) -> Layer? {
        let tw = twelveHour(doc)
        let order = doc.layers.filter { $0.visible && $0.kind.isLive }.reversed() + doc.layers.filter { $0.visible && !$0.kind.isLive }.reversed()
        for l in order {
            let b = bounds(l, sample: sample, twelveHour: tw).insetBy(dx: -4, dy: -4)
            let a = -l.rotation * .pi / 180
            let dx = p.x - l.x, dy = p.y - l.y
            let q = CGPoint(x: l.x + dx * cos(a) - dy * sin(a), y: l.y + dx * sin(a) + dy * cos(a))
            if l.kind == .hands {
                if hypot(dx, dy) < 40 { return l } else { continue }
            }
            if l.kind == .dial || l.kind == .glow || (l.kind == .ring) {
                // only grab these near their visible part, so they don't swallow every click
                let r = min(b.width, b.height) / 2
                let d = hypot(dx, dy)
                if l.kind == .dial && l.dial.shape == .rect {
                    if b.contains(q) && !b.insetBy(dx: 44, dy: 44).contains(q) { return l }
                } else if l.kind == .glow ? d < r * 0.5 : (d > r - 30 && d < r + 6) { return l }
                continue
            }
            if b.contains(q) { return l }
        }
        return nil
    }
}
