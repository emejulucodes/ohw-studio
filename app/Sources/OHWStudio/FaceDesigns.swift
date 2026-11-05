import AppKit
import CoreGraphics

struct FaceOptions {
    var accent: NSColor = NSColor(hex: 0xFF9F0A)
    var photo: CGImage? = nil
    var photoFocus: CGFloat = 0.35
}

struct FaceBuild {
    let elements: [FaceKit.Element]
    let preview: CGImage
    var blob: [UInt8] { FaceKit.container(elements) }
}

enum FaceStyle: String, CaseIterable, Identifiable {
    case studio, portrait, chrono, pulse
    var id: String { rawValue }
    var title: String {
        switch self { case .studio: return "Studio"; case .portrait: return "Portrait"
        case .chrono: return "Chrono"; case .pulse: return "Pulse" }
    }
    var tagline: String {
        switch self {
        case .studio: return "Thin time, four live complication cards"
        case .portrait: return "Your photo, edge to edge"
        case .chrono: return "Analog with sweeping hands"
        case .pulse: return "Bold stacked digits, glowing orbs"
        }
    }
    var symbol: String {
        switch self { case .studio: return "square.grid.2x2"; case .portrait: return "photo"
        case .chrono: return "clock"; case .pulse: return "textformat.123" }
    }

    func build(_ o: FaceOptions) -> FaceBuild {
        switch self {
        case .studio: return FaceDesigner.studio(o)
        case .portrait: return FaceDesigner.portrait(o)
        case .chrono: return FaceDesigner.chrono(o)
        case .pulse: return FaceDesigner.pulse(o)
        }
    }
}

enum FaceDesigner {
    typealias E = FaceKit.Element
    static let W = FaceKit.W, H = FaceKit.H
    static let weekdays = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]
    static let digits = (0...9).map(String.init)
    static let grey = NSColor(hex: 0x8E8E93)
    static let card = NSColor(hex: 0x1C1C1E)
    static let green = NSColor(hex: 0x30D158), red = NSColor(hex: 0xFF453A)
    static let orange = NSColor(hex: 0xFF9F0A), cyan = NSColor(hex: 0x64D2FF)

    // MARK: shared helpers
    static func element(_ t: UInt8, _ g: GlyphSet, _ x: Int, _ y: Int, gravity: UInt8 = FaceKit.gravityTopLeft) -> E {
        E(type: t, alpha: true, w: g.w, h: g.h, gravity: gravity, x: x, y: y, images: g.encoded())
    }

    /// Place a sample string from a glyph set on the preview (left/top anchored or centered).
    static func sample(_ c: Canvas, _ g: GlyphSet, _ s: [Int], _ x: Int, _ y: Int, centered: Bool = false) {
        let imgs = g.images
        let x0 = centered ? x - g.w * s.count / 2 : x
        let y0 = centered ? y - g.h / 2 : y
        for (i, k) in s.enumerated() { c.put(imgs[k], CGFloat(x0 + i * g.w), CGFloat(y0)) }
    }
    static func ds(_ s: String) -> [Int] { s.map { $0 == "." ? 10 : Int(String($0)) ?? 0 } }

    static func symbol(_ name: String, size: CGFloat, color: NSColor, weight: NSFont.Weight = .semibold) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
    }

    static func drawSymbol(_ name: String, size: CGFloat, color: NSColor, in r: NSRect) {
        guard let img = symbol(name, size: size, color: color) else { return }
        let s = img.size, scale = min(r.width / s.width, r.height / s.height)
        let dr = NSRect(x: r.midX - s.width * scale / 2, y: r.midY - s.height * scale / 2,
                        width: s.width * scale, height: s.height * scale)
        img.draw(in: dr, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    static func radial(_ ctx: CGContext, center: CGPoint, radius: CGFloat, color: NSColor, alpha: CGFloat) {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let c0 = color.withAlphaComponent(alpha).cgColor, c1 = color.withAlphaComponent(0).cgColor
        let g = CGGradient(colorsSpace: cs, colors: [c0, c1] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }

    static func colon(_ c: Canvas, x: CGFloat, y: CGFloat, h: CGFloat, r: CGFloat, color: NSColor = .white, shadow: Bool = false) {
        c.draw {
            if shadow {
                let s = NSShadow(); s.shadowColor = NSColor.black.withAlphaComponent(0.7); s.shadowBlurRadius = 4; s.set()
            }
            color.setFill()
            for f in [0.34, 0.72] as [CGFloat] {
                NSBezierPath(ovalIn: NSRect(x: x - r, y: y + h * f - r, width: 2 * r, height: 2 * r)).fill()
            }
        }
    }

    static func finish(_ bg: Canvas, _ els: [E], preview: Canvas) -> FaceBuild {
        let pv = Canvas(FaceKit.PW, FaceKit.PH)
        pv.put(preview.cgImage, 0, 0, CGFloat(FaceKit.PW), CGFloat(FaceKit.PH))
        let head = [
            E(type: FaceKit.T.preview, alpha: false, w: FaceKit.PW, h: FaceKit.PH, gravity: 0, x: 0, y: 0,
              images: [FaceKit.jlConvert(pv.rgba, alpha: false)]),
            E(type: FaceKit.T.background, alpha: false, w: W, h: H + 1, gravity: FaceKit.gravityTopLeft, x: 0, y: 0,
              images: [FaceKit.jlConvert(bg.rgba, alpha: false)]),
        ]
        return FaceBuild(elements: head + els, preview: preview.cgImage)
    }

    static func clone(_ c: Canvas) -> Canvas { let n = Canvas(c.w, c.h); n.put(c.cgImage, 0, 0); return n }

    // MARK: Studio
    static func studio(_ o: FaceOptions) -> FaceBuild {
        let bg = Canvas(W, H)
        bg.ctx.setFillColor(NSColor.black.cgColor); bg.ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        radial(bg.ctx, center: CGPoint(x: W / 2, y: -40), radius: 330, color: o.accent, alpha: 0.28)

        let M = 26
        let time = GlyphSet.make(digits, font: .monospacedDigitSystemFont(ofSize: 132, weight: .thin), color: .white, pad: 0)
        let colonW = 30
        let tx = (W - (4 * time.w + colonW)) / 2, ty = 74
        let hx = tx, mx = tx + 2 * time.w + colonW
        colon(bg, x: CGFloat(tx + 2 * time.w + colonW / 2), y: CGFloat(ty), h: CGFloat(time.h), r: 6)

        let week = GlyphSet.make(weekdays, font: .systemFont(ofSize: 25, weight: .semibold), color: o.accent)
        let day = GlyphSet.make(digits, font: .monospacedDigitSystemFont(ofSize: 25, weight: .semibold), color: .white)
        let ampm = GlyphSet.make(["AM", "PM"], font: .systemFont(ofSize: 21, weight: .medium), color: grey)
        let wx = M + 8, wy = 34, dx = wx + week.w + 6
        let ax = W - M - 8 - ampm.w, ay = wy + (week.h - ampm.h) / 2

        let dv = ty + time.h + 22
        bg.draw {
            NSColor(hex: 0x3A3A3C).setFill()
            NSBezierPath(roundedRect: NSRect(x: M, y: dv, width: W - 2 * M, height: 2), xRadius: 1, yRadius: 1).fill()
        }

        let gap = 12, cw = (W - 2 * M - gap) / 2, top = dv + 16, ch = (H - 36 - top - gap) / 2
        let cards: [(String, String, UInt8, NSColor, String)] = [
            ("figure.walk", "STEPS", FaceKit.T.steps, green, "8412"),
            ("heart.fill", "BPM", FaceKit.T.heart, red, "72"),
            ("flame.fill", "KCAL", FaceKit.T.calories, orange, "326"),
            ("location.fill", "KM", FaceKit.T.distance, cyan, "5.4")]
        var els: [E] = []
        var samples: [(GlyphSet, [Int], Int, Int)] = []
        for (i, c) in cards.enumerated() {
            let x0 = M + (i % 2) * (cw + gap), y0 = top + (i / 2) * (ch + gap)
            bg.draw {
                card.setFill()
                NSBezierPath(roundedRect: NSRect(x: x0, y: y0, width: cw, height: ch), xRadius: 24, yRadius: 24).fill()
                drawSymbol(c.0, size: 22, color: c.3, in: NSRect(x: x0 + 14, y: y0 + 13, width: 28, height: 26))
                let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: grey, .kern: 0.6]
                let s = NSAttributedString(string: c.1, attributes: a)
                s.draw(at: NSPoint(x: CGFloat(x0 + cw - 16) - s.size().width, y: CGFloat(y0 + 17)))
            }
            let vals = GlyphSet.make(digits + ["."], font: .monospacedDigitSystemFont(ofSize: 42, weight: .medium),
                                     color: c.2 == FaceKit.T.steps ? .white : c.3, pad: 0)
            let vcx = x0 + cw / 2, vcy = y0 + ch - 14 - vals.h / 2
            els.append(element(c.2, vals, vcx, vcy, gravity: FaceKit.gravityCenter))
            samples.append((vals, ds(c.4), vcx, vcy))
        }
        els += [element(FaceKit.T.weekday, week, wx, wy), element(FaceKit.T.day, day, dx, wy),
                element(FaceKit.T.ampm, ampm, ax, ay),
                element(FaceKit.T.hour, time, hx, ty), element(FaceKit.T.minute, time, mx, ty)]

        let pv = clone(bg)
        sample(pv, week, [4], wx, wy); sample(pv, day, [0, 5], dx, wy); sample(pv, ampm, [0], ax, ay)
        sample(pv, time, [1, 0], hx, ty); sample(pv, time, [0, 9], mx, ty)
        for s in samples { sample(pv, s.0, s.1, s.2, s.3, centered: true) }
        return finish(bg, els, preview: pv)
    }

    // MARK: Portrait
    static func portrait(_ o: FaceOptions) -> FaceBuild {
        let bg = Canvas(W, H)
        if let ph = o.photo {
            let sw = CGFloat(ph.width), sh = CGFloat(ph.height), tr = CGFloat(W) / CGFloat(H)
            var crop: CGRect
            if sw / sh > tr { let nw = sh * tr; crop = CGRect(x: (sw - nw) / 2, y: 0, width: nw, height: sh) }
            else { let nh = sw / tr; crop = CGRect(x: 0, y: (sh - nh) * o.photoFocus, width: sw, height: nh) }
            if let c = ph.cropping(to: crop.integral) { bg.put(c, 0, 0, CGFloat(W), CGFloat(H)) }
        } else {
            bg.ctx.setFillColor(NSColor(hex: 0x101018).cgColor); bg.ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
            radial(bg.ctx, center: CGPoint(x: 90, y: 120), radius: 300, color: o.accent, alpha: 0.55)
            radial(bg.ctx, center: CGPoint(x: 340, y: 300), radius: 260, color: NSColor(hex: 0x5E5CE6), alpha: 0.5)
        }
        // legibility gradient
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let g = CGGradient(colorsSpace: cs, colors: [NSColor.black.withAlphaComponent(0).cgColor,
                                                    NSColor.black.withAlphaComponent(0.82).cgColor] as CFArray, locations: [0, 1])!
        bg.ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: H / 2), end: CGPoint(x: 0, y: H), options: [.drawsAfterEndLocation])

        let M = 34
        let time = GlyphSet.make(digits, font: .monospacedDigitSystemFont(ofSize: 112, weight: .light), color: .white, shadow: true, pad: 0)
        let colonW = 24
        let tx = M - 6, ty = H - 64 - time.h - 28
        let hx = tx, mx = tx + 2 * time.w + colonW
        colon(bg, x: CGFloat(tx + 2 * time.w + colonW / 2), y: CGFloat(ty + 5), h: CGFloat(time.h - 10), r: 5.5, shadow: true)
        let week = GlyphSet.make(weekdays, font: .systemFont(ofSize: 24, weight: .bold), color: o.accent, shadow: true)
        let day = GlyphSet.make(digits, font: .monospacedDigitSystemFont(ofSize: 24, weight: .bold), color: .white, shadow: true)
        let ampm = GlyphSet.make(["AM", "PM"], font: .systemFont(ofSize: 20, weight: .semibold), color: NSColor(white: 0.92, alpha: 1), shadow: true)
        let wx = M - 2, wy = ty - week.h + 2, dx = wx + week.w + 4
        let ax = mx + 2 * time.w + 2, ay = ty + time.h - ampm.h - 4

        let rowY = H - 58
        let small: [(String, UInt8, NSColor, String)] = [("heart.fill", FaceKit.T.heart, red, "72"),
                                                         ("figure.walk", FaceKit.T.steps, green, "8412")]
        var els: [E] = [], samples: [(GlyphSet, [Int], Int, Int)] = []
        var x = M + 4
        for s in small {
            bg.draw {
                let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.6); sh.shadowBlurRadius = 3; sh.set()
                drawSymbol(s.0, size: 20, color: s.2, in: NSRect(x: x, y: rowY - 12, width: 24, height: 24))
            }
            let vals = GlyphSet.make(digits + ["."], font: .monospacedDigitSystemFont(ofSize: 25, weight: .semibold), color: .white, shadow: true, pad: 0)
            let vcx = x + 32 + vals.w * s.3.count / 2
            els.append(element(s.1, vals, vcx, rowY, gravity: FaceKit.gravityCenter))
            samples.append((vals, ds(s.3), vcx, rowY))
            x += 32 + vals.w * 4 + 26
        }
        els += [element(FaceKit.T.weekday, week, wx, wy), element(FaceKit.T.day, day, dx, wy),
                element(FaceKit.T.ampm, ampm, ax, ay),
                element(FaceKit.T.hour, time, hx, ty), element(FaceKit.T.minute, time, mx, ty)]
        let pv = clone(bg)
        sample(pv, week, [4], wx, wy); sample(pv, day, [0, 5], dx, wy); sample(pv, ampm, [0], ax, ay)
        sample(pv, time, [1, 0], hx, ty); sample(pv, time, [0, 9], mx, ty)
        for s in samples { sample(pv, s.0, s.1, s.2, s.3, centered: true) }
        return finish(bg, els, preview: pv)
    }

    // MARK: Chrono (analog)
    static func hand(width hw: Int, length: CGFloat, tail: CGFloat, thickness: CGFloat, color: NSColor,
                     cap: CGFloat = 0, capColor: NSColor = .white) -> Canvas {
        let c = Canvas(hw, 300)
        let cx = CGFloat(hw) / 2, py: CGFloat = 150
        c.draw {
            let r = NSRect(x: cx - thickness / 2, y: py - length, width: thickness, height: length + tail)
            let p = NSBezierPath(roundedRect: r, xRadius: thickness / 2, yRadius: thickness / 2)
            NSColor.black.withAlphaComponent(0.55).setStroke(); p.lineWidth = 1.2; p.stroke()
            color.setFill(); p.fill()
            if cap > 0 {
                capColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: cx - cap, y: py - cap, width: 2 * cap, height: 2 * cap)).fill()
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: cx - 2, y: py - 2, width: 4, height: 4)).fill()
            }
        }
        return c
    }

    static func chrono(_ o: FaceOptions) -> FaceBuild {
        let bg = Canvas(W, H)
        let cx = CGFloat(W / 2), cy = CGFloat(H / 2)
        bg.ctx.setFillColor(NSColor(hex: 0x07070A).cgColor); bg.ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        radial(bg.ctx, center: CGPoint(x: cx, y: cy), radius: 260, color: o.accent, alpha: 0.16)
        bg.draw {
            for k in 0..<60 {
                let a = CGFloat(k) * 6 * .pi / 180, big = k % 5 == 0
                let r0: CGFloat = big ? 166 : 180, r1: CGFloat = 190
                let p = NSBezierPath()
                p.move(to: NSPoint(x: cx + r0 * sin(a), y: cy - r0 * cos(a)))
                p.line(to: NSPoint(x: cx + r1 * sin(a), y: cy - r1 * cos(a)))
                p.lineWidth = big ? 4 : 1.6; p.lineCapStyle = .round
                (big ? (k == 0 ? o.accent : NSColor.white) : NSColor(white: 0.45, alpha: 1)).setStroke()
                p.stroke()
            }
            let numerals = [(12, 0.0), (3, 90.0), (6, 180.0), (9, 270.0)]
            for (n, deg) in numerals where n == 12 || n == 6 {
                let a = CGFloat(deg) * .pi / 180, r: CGFloat = 138
                let s = NSAttributedString(string: "\(n)", attributes: [.font: NSFont.systemFont(ofSize: 34, weight: .semibold),
                                                                         .foregroundColor: n == 12 ? o.accent : NSColor.white])
                let sz = s.size()
                s.draw(at: NSPoint(x: cx + r * sin(a) - sz.width / 2, y: cy - r * cos(a) - sz.height / 2))
            }
            // date window at 3 o'clock
            NSColor(hex: 0x1C1C1E).setFill()
            NSBezierPath(roundedRect: NSRect(x: cx + 108, y: cy - 20, width: 50, height: 40), xRadius: 9, yRadius: 9).fill()
            // steps sub-dial above 6
            drawSymbol("figure.walk", size: 18, color: green, in: NSRect(x: cx - 11, y: cy + 62, width: 22, height: 22))
            drawSymbol("heart.fill", size: 16, color: red, in: NSRect(x: cx - 143, y: cy - 10, width: 20, height: 20))
        }
        let day = GlyphSet.make(digits, font: .monospacedDigitSystemFont(ofSize: 24, weight: .semibold), color: .white, pad: 0)
        let vals = GlyphSet.make(digits + ["."], font: .monospacedDigitSystemFont(ofSize: 22, weight: .semibold), color: .white, pad: 0)
        let hvals = GlyphSet.make(digits + ["."], font: .monospacedDigitSystemFont(ofSize: 22, weight: .semibold), color: red, pad: 0)
        let dayX = Int(cx) + 133 - day.w, dayY = Int(cy) - day.h / 2
        var els: [E] = [
            element(FaceKit.T.day, day, dayX, dayY),
            element(FaceKit.T.steps, vals, Int(cx), Int(cy) + 100, gravity: FaceKit.gravityCenter),
            element(FaceKit.T.heart, hvals, Int(cx) - 100, Int(cy), gravity: FaceKit.gravityCenter),
        ]
        let hourH = hand(width: 14, length: 92, tail: 18, thickness: 9, color: .white)
        let minH = hand(width: 12, length: 140, tail: 20, thickness: 6, color: NSColor(white: 0.93, alpha: 1))
        let secH = hand(width: 16, length: 148, tail: 28, thickness: 2.4, color: o.accent, cap: 6.5, capColor: o.accent)
        for (t, hc) in [(FaceKit.T.hourHand, hourH), (FaceKit.T.minuteHand, minH), (FaceKit.T.secondHand, secH)] {
            let part = hc.rgba.cropped(height: 180)
            els.append(E(type: t, alpha: true, w: hc.w, h: 180, gravity: FaceKit.gravityTopLeft, x: W / 2, y: H / 2,
                         images: [FaceKit.rawARGB8565(part)], ignoreBlack: 1,
                         bottomOffset: UInt8(180 - 150), leftOffset: UInt8(hc.w / 2)))
        }
        let pv = clone(bg)
        sample(pv, day, [0, 5], dayX, dayY)
        sample(pv, vals, ds("8412"), Int(cx), Int(cy) + 100, centered: true)
        sample(pv, hvals, ds("72"), Int(cx) - 100, Int(cy), centered: true)
        for (hc, deg) in [(hourH, 304.5), (minH, 54.0), (secH, 180.0)] as [(Canvas, CGFloat)] {
            pv.putRotated(hc.cgImage, pivotX: CGFloat(hc.w) / 2, pivotY: 150, at: cx, cy, degrees: deg)
        }
        return finish(bg, els, preview: pv)
    }

    // MARK: Pulse (bold digital)
    static func pulse(_ o: FaceOptions) -> FaceBuild {
        let bg = Canvas(W, H)
        bg.ctx.setFillColor(NSColor(hex: 0x050507).cgColor); bg.ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        radial(bg.ctx, center: CGPoint(x: 330, y: 110), radius: 260, color: o.accent, alpha: 0.55)
        radial(bg.ctx, center: CGPoint(x: 70, y: 330), radius: 240, color: NSColor(hex: 0x5E5CE6), alpha: 0.45)
        radial(bg.ctx, center: CGPoint(x: 260, y: 470), radius: 200, color: NSColor(hex: 0x30D158), alpha: 0.18)

        let big = NSFont.monospacedDigitSystemFont(ofSize: 150, weight: .heavy)
        let hourG = GlyphSet.make(digits, font: big, color: .white, pad: 0)
        let minG = GlyphSet.make(digits, font: big, color: NSColor(white: 1, alpha: 0.62), pad: 0)
        let tx = 30, hy = 66, my = hy + hourG.h + 18
        let week = GlyphSet.make(weekdays, font: .systemFont(ofSize: 22, weight: .heavy), color: .white, tracking: 1)
        let day = GlyphSet.make(digits, font: .monospacedDigitSystemFont(ofSize: 22, weight: .heavy), color: o.accent)
        let ampm = GlyphSet.make(["AM", "PM"], font: .systemFont(ofSize: 20, weight: .bold), color: NSColor(white: 1, alpha: 0.7))
        let wx = 34, wy = 30, dx = wx + week.w + 4
        let ax = W - 34 - ampm.w
        let rowY = my + minG.h + 52
        let items: [(String, UInt8, NSColor, String, Int)] = [("heart.fill", FaceKit.T.heart, red, "72", 34),
                                                              ("figure.walk", FaceKit.T.steps, green, "8412", 160),
                                                              ("flame.fill", FaceKit.T.calories, orange, "326", 300)]
        bg.draw {
            NSColor.white.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: NSRect(x: 22, y: rowY - 30, width: W - 44, height: 60), xRadius: 30, yRadius: 30).fill()
        }
        var els: [E] = [], samples: [(GlyphSet, [Int], Int, Int)] = []
        for it in items {
            bg.draw { drawSymbol(it.0, size: 18, color: it.2, in: NSRect(x: it.4, y: rowY - 11, width: 22, height: 22)) }
            let vals = GlyphSet.make(digits + ["."], font: .monospacedDigitSystemFont(ofSize: 23, weight: .bold), color: .white, pad: 0)
            let vcx = it.4 + 28 + vals.w * it.3.count / 2
            els.append(element(it.1, vals, vcx, rowY, gravity: FaceKit.gravityCenter))
            samples.append((vals, ds(it.3), vcx, rowY))
        }
        els += [element(FaceKit.T.weekday, week, wx, wy), element(FaceKit.T.day, day, dx, wy),
                element(FaceKit.T.ampm, ampm, ax, wy),
                element(FaceKit.T.hour, hourG, tx, hy), element(FaceKit.T.minute, minG, tx, my)]
        let pv = clone(bg)
        sample(pv, week, [4], wx, wy); sample(pv, day, [0, 5], dx, wy); sample(pv, ampm, [0], ax, wy)
        sample(pv, hourG, [1, 0], tx, hy); sample(pv, minG, [0, 9], tx, my)
        for s in samples { sample(pv, s.0, s.1, s.2, s.3, centered: true) }
        return finish(bg, els, preview: pv)
    }
}
