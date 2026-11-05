import AppKit
import CoreGraphics

// Watch-face file format for the OHW-11 (see FINDINGS.md):
//  container = libsmawatchface.so buildWatchFace (little-endian)
//  images    = libjl_bmp_convert.so br28_*_to_res no-pack (RLE rows) / raw ARGB8565 for hands

enum FaceKit {
    static let W = 410, H = 502, PW = 260, PH = 300

    enum T {
        static let preview: UInt8 = 1, background: UInt8 = 2
        static let hourHand: UInt8 = 3, minuteHand: UInt8 = 4, secondHand: UInt8 = 5
        static let month: UInt8 = 7, day: UInt8 = 8, hour: UInt8 = 9, minute: UInt8 = 10
        static let ampm: UInt8 = 12, weekday: UInt8 = 13
        static let steps: UInt8 = 14, heart: UInt8 = 15, calories: UInt8 = 16, distance: UInt8 = 17
    }
    static let gravityTopLeft: UInt8 = 9      // X_LEFT | Y_TOP
    static let gravityCenter: UInt8 = 18      // 410x502 activity: X_CENTER 2 | Y_CENTER 16

    struct Element {
        var type: UInt8
        var alpha: Bool
        var w: Int, h: Int
        var gravity: UInt8
        var x: Int, y: Int
        var images: [[UInt8]]
        var ignoreBlack: UInt8 = 4
        var bottomOffset: UInt8 = 0
        var leftOffset: UInt8 = 0
    }

    // MARK: JieLi Rle_Encode (byte-exact port; unit = bytes per pixel, thr = 3)
    static func rle(_ row: [UInt8], unit: Int, thr: Int = 3) -> [UInt8] {
        let n0 = row.count / unit
        var px = [UInt32](repeating: 0, count: n0)
        for k in 0..<n0 {
            var v: UInt32 = 0
            for b in 0..<unit { v = v << 8 | UInt32(row[k * unit + b]) }
            px[k] = v
        }
        var out: [UInt8] = []
        out.reserveCapacity(row.count + row.count / 64 + 8)
        var i = 0, n = n0
        func put(_ k: Int) { out.append(contentsOf: row[(k * unit)..<(k * unit + unit)]) }
        while n > 0 {
            let first = px[i]
            var streak = 0, j = 0
            while true {
                streak = px[i + j] == first ? streak + 1 : 0
                if streak >= thr { break }
                j += 1
                if j == thr || j >= n { break }
            }
            var cnt: Int
            if streak >= thr {
                cnt = 0
                while cnt < n && cnt < 127 && px[i + cnt] == first { cnt += 1 }
                out.append(UInt8(0x80 | cnt)); put(i)
            } else {
                var prev = first, rep = 0, k = 0
                cnt = 0
                while true {
                    if k == n { cnt = n; break }
                    if px[i + k] == prev {
                        rep += 1
                        if rep == thr { cnt = k + 1 - thr; break }
                    } else { prev = px[i + k]; rep = 1 }
                    k += 1
                    if k == 127 { cnt = 127; break }
                }
                cnt = max(1, cnt)
                out.append(UInt8(cnt))
                for q in 0..<cnt { put(i + q) }
            }
            i += cnt; n -= cnt
        }
        return out
    }

    @inline(__always) static func rgb565(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> (UInt8, UInt8) {
        let v = (UInt16(r >> 3) << 11) | (UInt16(g >> 2) << 5) | UInt16(b >> 3)
        return (UInt8(v >> 8), UInt8(v & 0xff))
    }

    /// br28_png_to_res / br28_bmp_to_res, no-pack: [h x u32 LE off|len<<21][RLE rows], padded to 4.
    static func jlConvert(_ img: RGBAImage, alpha: Bool) -> [UInt8] {
        let unit = alpha ? 3 : 2
        var rows: [[UInt8]] = []
        rows.reserveCapacity(img.h)
        var row = [UInt8](repeating: 0, count: img.w * unit)
        for y in 0..<img.h {
            for x in 0..<img.w {
                let p = (y * img.w + x) * 4
                let (hi, lo) = rgb565(img.px[p], img.px[p + 1], img.px[p + 2])
                if alpha { row[x * 3] = img.px[p + 3]; row[x * 3 + 1] = hi; row[x * 3 + 2] = lo }
                else { row[x * 2] = hi; row[x * 2 + 1] = lo }
            }
            rows.append(rle(row, unit: unit))
        }
        var out: [UInt8] = []
        var off = 4 * img.h
        for r in rows {
            let e = UInt32(off & 0x1FFFFF) | UInt32(min(r.count, 2047)) << 21
            out += [UInt8(e & 0xff), UInt8((e >> 8) & 0xff), UInt8((e >> 16) & 0xff), UInt8(e >> 24)]
            off += r.count
        }
        for r in rows { out += r }
        while out.count % 4 != 0 { out.append(0) }
        return out
    }

    /// getPointer2 (JL): uncompressed [A][565 hi][lo], rows padded to 4 bytes.
    static func rawARGB8565(_ img: RGBAImage) -> [UInt8] {
        let stride = (img.w * 3 + 3) / 4 * 4
        var out = [UInt8](repeating: 0, count: stride * img.h)
        for y in 0..<img.h {
            for x in 0..<img.w {
                let p = (y * img.w + x) * 4
                let (hi, lo) = rgb565(img.px[p], img.px[p + 1], img.px[p + 2])
                let o = y * stride + x * 3
                out[o] = img.px[p + 3]; out[o + 1] = hi; out[o + 2] = lo
            }
        }
        return out
    }

    /// buildWatchFace container.
    static func container(_ els: [Element], format: UInt8 = 2) -> [UInt8] {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
        func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)] }
        let total = els.reduce(0) { $0 + $1.images.count }
        var out = le16(total) + [UInt8(els.count), format]
        var dataOff = 4 + 20 * els.count + 4 * total
        var idx = 0
        var sizes: [UInt8] = [], blobs: [UInt8] = []
        for e in els {
            out += le32(dataOff) + le16(idx) + le16(e.w) + le16(e.h) + le16(e.x) + le16(e.y)
            out += [UInt8(e.images.count), e.type | (e.alpha ? 0x80 : 0), e.gravity, e.ignoreBlack, e.bottomOffset, e.leftOffset]
            for im in e.images { sizes += le32(im.count); blobs += im; dataOff += im.count }
            idx += e.images.count
        }
        return out + sizes + blobs
    }
}

// MARK: - pixels & drawing

/// Un-premultiplied RGBA, top row first.
struct RGBAImage {
    let w: Int, h: Int
    var px: [UInt8]

    func cropped(height: Int) -> RGBAImage {
        RGBAImage(w: w, h: height, px: Array(px[0..<(w * height * 4)]))
    }
}

/// A y-down CoreGraphics canvas that AppKit can draw into.
final class Canvas {
    let w: Int, h: Int
    let ctx: CGContext

    init(_ w: Int, _ h: Int) {
        self.w = w; self.h = h
        ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(true)
    }

    func draw(_ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Draw a CGImage with its top-left at (x, y) in y-down coordinates.
    func put(_ img: CGImage, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat? = nil, _ h: CGFloat? = nil) {
        let ww = w ?? CGFloat(img.width), hh = h ?? CGFloat(img.height)
        ctx.saveGState()
        ctx.translateBy(x: x, y: y + hh)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: ww, height: hh))
        ctx.restoreGState()
    }

    /// Draw `img` rotated by `deg` (clockwise) around its point (px, py), placed at (cx, cy).
    func putRotated(_ img: CGImage, pivotX px: CGFloat, pivotY py: CGFloat, at cx: CGFloat, _ cy: CGFloat, degrees deg: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: cx, y: cy)
        ctx.rotate(by: deg * .pi / 180)
        put(img, -px, -py)
        ctx.restoreGState()
    }

    var cgImage: CGImage { ctx.makeImage()! }

    var rgba: RGBAImage {
        let data = ctx.data!.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let s = y * ctx.bytesPerRow + x * 4, d = (y * w + x) * 4
                let a = data[s + 3]
                if a == 0 { continue }
                if a == 255 {
                    px[d] = data[s]; px[d + 1] = data[s + 1]; px[d + 2] = data[s + 2]
                } else {
                    px[d] = UInt8(min(255, Int(data[s]) * 255 / Int(a)))
                    px[d + 1] = UInt8(min(255, Int(data[s + 1]) * 255 / Int(a)))
                    px[d + 2] = UInt8(min(255, Int(data[s + 2]) * 255 / Int(a)))
                }
                px[d + 3] = a
            }
        }
        return RGBAImage(w: w, h: h, px: px)
    }
}

/// A set of same-size glyph cells (digits, weekday names...) sharing one baseline.
struct GlyphSet {
    let canvases: [Canvas]
    var w: Int { canvases.first?.w ?? 0 }
    var h: Int { canvases.first?.h ?? 0 }
    var images: [CGImage] { canvases.map { $0.cgImage } }
    func encoded() -> [[UInt8]] { canvases.map { FaceKit.jlConvert($0.rgba, alpha: true) } }

    static func make(_ strings: [String], font: NSFont, color: NSColor, shadow: Bool = false,
                     pad: Int = 1, tracking: CGFloat = 0) -> GlyphSet {
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: tracking]
        var sp = pad
        if shadow {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.75)
            s.shadowBlurRadius = 3
            s.shadowOffset = NSSize(width: 0, height: -1)
            attrs[.shadow] = s
            sp = pad + 3
        }
        let widths = strings.map { NSAttributedString(string: $0, attributes: attrs).size().width }
        let w = Int(ceil(widths.max() ?? 1)) + 2 * (shadow ? 1 : sp)
        let capTopInset = font.ascender - font.capHeight
        let h = Int(ceil(font.capHeight)) + 2 * sp
        let canvases = zip(strings, widths).map { (s, sw) -> Canvas in
            let c = Canvas(w, h)
            c.draw {
                NSAttributedString(string: s, attributes: attrs)
                    .draw(at: NSPoint(x: (CGFloat(w) - sw) / 2, y: CGFloat(sp) - capTopInset))
            }
            return c
        }
        return GlyphSet(canvases: canvases)
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

extension CGImage {
    var nsImage: NSImage { NSImage(cgImage: self, size: NSSize(width: width, height: height)) }

    func pngData() -> Data? {
        let rep = NSBitmapImageRep(cgImage: self)
        return rep.representation(using: .png, properties: [:])
    }
}
