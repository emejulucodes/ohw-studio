import AppKit
import SwiftUI

// MARK: - Face Composer document model
//
// A face is a background plus an ordered stack of layers (bottom → top).
// Artwork layers (shapes, text, dials, rings, images, glows...) are flattened into the watch's
// background image. Live layers (time, date, metrics, hands) become watch elements that the watch
// redraws itself, so they always sit above the artwork.

struct RGBA: Codable, Hashable {
    var r: Double, g: Double, b: Double, a: Double

    init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    init(_ hex: UInt32, _ a: Double = 1) {
        r = Double((hex >> 16) & 0xff) / 255; g = Double((hex >> 8) & 0xff) / 255; b = Double(hex & 0xff) / 255; self.a = a
    }
    init(_ c: Color) {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .white
        r = Double(n.redComponent); g = Double(n.greenComponent); b = Double(n.blueComponent); a = Double(n.alphaComponent)
    }
    var ns: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var cg: CGColor { ns.cgColor }
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    func alpha(_ v: Double) -> RGBA { RGBA(r: r, g: g, b: b, a: v) }
    func mix(_ o: RGBA, _ t: Double) -> RGBA {
        RGBA(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t, a: a + (o.a - a) * t)
    }

    static let white = RGBA(0xFFFFFF), black = RGBA(0x000000), clear = RGBA(0x000000, 0)
    static let orange = RGBA(0xFF9F0A), red = RGBA(0xFF453A), green = RGBA(0x30D158), cyan = RGBA(0x64D2FF)
    static let indigo = RGBA(0x5E5CE6), pink = RGBA(0xFF375F), yellow = RGBA(0xFFD60A), grey = RGBA(0x8E8E93)
    static let mint = RGBA(0x63E6E2), purple = RGBA(0xBF5AF2), card = RGBA(0x1C1C1E)
}

enum FillKind: String, Codable, CaseIterable, Identifiable {
    case solid, linear, radial, angular, none
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct Fill: Codable, Hashable {
    var kind: FillKind = .solid
    var c1: RGBA = .white
    var c2: RGBA = .orange
    var angle: Double = 90

    static func solid(_ c: RGBA) -> Fill { Fill(kind: .solid, c1: c, c2: c) }
    static func linear(_ a: RGBA, _ b: RGBA, _ angle: Double = 90) -> Fill { Fill(kind: .linear, c1: a, c2: b, angle: angle) }
    static func radial(_ a: RGBA, _ b: RGBA) -> Fill { Fill(kind: .radial, c1: a, c2: b) }
    static let none = Fill(kind: .none)
}

struct Stroke: Codable, Hashable {
    var on = false
    var width: Double = 2
    var color: RGBA = .white
}

struct Shadow: Codable, Hashable {
    var on = false
    var color: RGBA = RGBA(0x000000, 0.7)
    var radius: Double = 6
    var dx: Double = 0
    var dy: Double = 2
    var passes: Int = 1

    static func glow(_ c: RGBA, _ r: Double = 14, passes: Int = 2) -> Shadow {
        Shadow(on: true, color: c, radius: r, dx: 0, dy: 0, passes: passes)
    }
    static let soft = Shadow(on: true, color: RGBA(0x000000, 0.75), radius: 5, dx: 0, dy: 2)
}

enum FontDesign: String, Codable, CaseIterable, Identifiable {
    case standard, rounded, serif, mono, custom
    var id: String { rawValue }
    var title: String {
        switch self { case .standard: return "SF Pro"; case .rounded: return "SF Rounded"; case .serif: return "New York"
        case .mono: return "SF Mono"; case .custom: return "Other font…" }
    }
}

enum FontWeight: String, Codable, CaseIterable, Identifiable {
    case ultraLight, thin, light, regular, medium, semibold, bold, heavy, black
    var id: String { rawValue }
    var title: String {
        switch self { case .ultraLight: return "Ultralight"; case .semibold: return "Semibold"; default: return rawValue.capitalized }
    }
    var ns: NSFont.Weight {
        switch self {
        case .ultraLight: return .ultraLight; case .thin: return .thin; case .light: return .light
        case .regular: return .regular; case .medium: return .medium; case .semibold: return .semibold
        case .bold: return .bold; case .heavy: return .heavy; case .black: return .black
        }
    }
    /// NSFontManager weight (0–15)
    var fm: Int { [2, 3, 4, 5, 6, 8, 9, 10, 11][FontWeight.allCases.firstIndex(of: self)!] }
}

struct FontSpec: Codable, Hashable {
    var design: FontDesign = .standard
    var family: String = "Helvetica Neue"
    var weight: FontWeight = .regular
    var size: Double = 40
    var tracking: Double = 0
    var italic = false

    static func sf(_ size: Double, _ w: FontWeight = .regular, _ d: FontDesign = .standard) -> FontSpec {
        FontSpec(design: d, weight: w, size: size)
    }
}

enum TimeLayout: String, Codable, CaseIterable, Identifiable {
    case inline, stacked
    var id: String { rawValue }
    var title: String { self == .inline ? "Side by side" : "Stacked" }
}

enum Separator: String, Codable, CaseIterable, Identifiable {
    case colon, dot, bar, none
    var id: String { rawValue }
    var title: String { switch self { case .colon: return "Colon"; case .dot: return "Dot"; case .bar: return "Bar"; case .none: return "None" } }
}

enum NameStyle: String, Codable, CaseIterable, Identifiable {
    case upper, title, full, letter
    var id: String { rawValue }
    var title: String { switch self { case .upper: return "MON"; case .title: return "Mon"; case .full: return "MONDAY"; case .letter: return "M" } }
}

enum ShapeKind: String, Codable, CaseIterable, Identifiable {
    case rect, rounded, ellipse, capsule, polygon, star
    var id: String { rawValue }
    var title: String { switch self { case .rect: return "Rectangle"; case .rounded: return "Rounded"; case .ellipse: return "Ellipse"
        case .capsule: return "Capsule"; case .polygon: return "Polygon"; case .star: return "Star" } }
    var symbol: String { switch self { case .rect: return "rectangle"; case .rounded: return "rectangle.roundedtop"; case .ellipse: return "circle"
        case .capsule: return "capsule"; case .polygon: return "hexagon"; case .star: return "star" } }
}

enum MaterialKind: String, Codable, CaseIterable, Identifiable {
    case flat, glass
    var id: String { rawValue }
    var title: String { self == .flat ? "Flat" : "Frosted glass" }
}

enum BlendKind: String, Codable, CaseIterable, Identifiable {
    case normal, screen, plusLighter, multiply, overlay, softLight
    var id: String { rawValue }
    var title: String { switch self { case .plusLighter: return "Add"; case .softLight: return "Soft light"; default: return rawValue.capitalized } }
    var cg: CGBlendMode {
        switch self { case .normal: return .normal; case .screen: return .screen; case .plusLighter: return .plusLighter
        case .multiply: return .multiply; case .overlay: return .overlay; case .softLight: return .softLight }
    }
}

enum HandStyle: String, Codable, CaseIterable, Identifiable {
    case baton, sword, dauphine, needle, skeleton
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct HandsSpec: Codable, Hashable {
    var style: HandStyle = .baton
    var hourLength: Double = 92, minuteLength: Double = 140, secondLength: Double = 148
    var hourWidth: Double = 10, minuteWidth: Double = 7, secondWidth: Double = 2.4
    var tail: Double = 18
    var hourColor: RGBA = .white, minuteColor: RGBA = .white, secondColor: RGBA = .orange
    var lume = false
    var lumeColor: RGBA = RGBA(0x9DFFB0)
    var showSeconds = true
    var capSize: Double = 6.5
    var capColor: RGBA = .orange
    var shadow = true
}

enum NumeralStyle: String, Codable, CaseIterable, Identifiable {
    case none, quarters, all, roman, dots
    var id: String { rawValue }
    var title: String { switch self { case .none: return "None"; case .quarters: return "12 · 3 · 6 · 9"; case .all: return "1 – 12"
        case .roman: return "Roman"; case .dots: return "Dots" } }
}

enum DialShape: String, Codable, CaseIterable, Identifiable {
    case circle, rect
    var id: String { rawValue }
    var title: String { self == .circle ? "Round" : "Follow screen" }
}

struct DialSpec: Codable, Hashable {
    var shape: DialShape = .circle
    var ticks: Int = 60
    var majorEvery: Int = 5
    var majorLength: Double = 22, minorLength: Double = 9
    var majorWidth: Double = 4, minorWidth: Double = 1.6
    var majorColor: RGBA = .white, minorColor: RGBA = RGBA(0x8E8E93)
    var accentTop = true
    var accent: RGBA = .orange
    var numerals: NumeralStyle = .quarters
    var numeralFont = FontSpec.sf(34, .semibold)
    var numeralColor: RGBA = .white
    var numeralInset: Double = 50
    var hideThree = false
}

enum LayerKind: String, Codable, CaseIterable, Identifiable {
    // live — redrawn by the watch
    case time, date, month, weekday, ampm, seconds, steps, heart, calories, distance, battery, hands
    // artwork — baked into the background
    case text, symbol, shape, ring, dial, image, glow

    var id: String { rawValue }
    var isLive: Bool {
        switch self { case .text, .symbol, .shape, .ring, .dial, .image, .glow: return false; default: return true }
    }
    var isMetric: Bool { [.steps, .heart, .calories, .distance, .battery].contains(self) }
    var experimental: Bool { self == .seconds || self == .battery }
    var title: String {
        switch self {
        case .time: return "Time"; case .date: return "Day"; case .month: return "Month"; case .weekday: return "Weekday"
        case .ampm: return "AM / PM"; case .seconds: return "Seconds"; case .steps: return "Steps"; case .heart: return "Heart rate"
        case .calories: return "Calories"; case .distance: return "Distance"; case .battery: return "Battery"; case .hands: return "Analog hands"
        case .text: return "Text"; case .symbol: return "Symbol"; case .shape: return "Shape"; case .ring: return "Ring"
        case .dial: return "Dial"; case .image: return "Image"; case .glow: return "Glow"
        }
    }
    var icon: String {
        switch self {
        case .time: return "clock.fill"; case .date: return "calendar"; case .month: return "calendar.badge.clock"
        case .weekday: return "textformat.abc"; case .ampm: return "sun.and.horizon.fill"; case .seconds: return "timer"
        case .steps: return "figure.walk"; case .heart: return "heart.fill"; case .calories: return "flame.fill"
        case .distance: return "location.fill"; case .battery: return "battery.75percent"; case .hands: return "clock.arrow.circlepath"
        case .text: return "textformat"; case .symbol: return "star.square.on.square.fill"; case .shape: return "square.on.circle"
        case .ring: return "circle.dashed"; case .dial: return "circle.circle"; case .image: return "photo.fill"; case .glow: return "sun.max.fill"
        }
    }
    /// watch element types this layer occupies (each may appear once per face)
    var elementTypes: [UInt8] {
        switch self {
        case .time: return [FaceKit.T.hour, FaceKit.T.minute]
        case .date: return [FaceKit.T.day]; case .month: return [FaceKit.T.month]; case .weekday: return [FaceKit.T.weekday]
        case .ampm: return [FaceKit.T.ampm]; case .seconds: return [11]
        case .steps: return [FaceKit.T.steps]; case .heart: return [FaceKit.T.heart]; case .calories: return [FaceKit.T.calories]
        case .distance: return [FaceKit.T.distance]; case .battery: return [18]
        case .hands: return [FaceKit.T.hourHand, FaceKit.T.minuteHand, FaceKit.T.secondHand]
        default: return []
        }
    }
}

struct Layer: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: LayerKind
    var name: String
    var x: Double = 205, y: Double = 251        // centre, watch pixels
    var rotation: Double = 0
    var opacity: Double = 1
    var visible = true
    var locked = false
    var blend: BlendKind = .normal

    // type
    var text: String = "Hello"
    var font = FontSpec()
    var fill = Fill.solid(.white)
    var fill2 = Fill.solid(.white)              // time: minutes
    var stroke = Stroke()
    var shadow = Shadow()

    // live text options
    var timeLayout: TimeLayout = .inline
    var separator: Separator = .colon
    var spacing: Double = 14
    var nameStyle: NameStyle = .upper

    // geometry
    var w: Double = 120, h: Double = 120
    var corner: Double = 24
    var shape: ShapeKind = .rounded
    var sides: Int = 6
    var material: MaterialKind = .flat
    var glassBlur: Double = 14

    // ring
    var ringStart: Double = 0
    var ringSweep: Double = 360
    var ringProgress: Double = 0.72
    var lineWidth: Double = 14
    var trackColor: RGBA = RGBA(0xFFFFFF, 0.14)
    var segments: Int = 0
    var roundCaps = true

    var dial = DialSpec()
    var hands = HandsSpec()

    var symbol: String = "heart.fill"
    var imageData: Data? = nil
    var softness: Double = 1

    init(_ kind: LayerKind, name: String? = nil) {
        self.kind = kind
        self.name = name ?? kind.title
    }
}

enum BackgroundKind: String, Codable, CaseIterable, Identifiable {
    case fill, photo
    var id: String { rawValue }
}

struct BackgroundSpec: Codable, Hashable {
    var kind: BackgroundKind = .fill
    var fill = Fill(kind: .solid, c1: .black, c2: RGBA(0x1C1C2E), angle: 90)
    var photo: Data? = nil
    var zoom: Double = 1
    var focusX: Double = 0.5, focusY: Double = 0.4
    var blur: Double = 0
    var dim: Double = 0
    var tint: RGBA = RGBA(0x000000, 0)
    var vignette: Double = 0
}

struct FaceDoc: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = "Untitled face"
    var modified = Date()
    var background = BackgroundSpec()
    var layers: [Layer] = []

    func usedTypes(excluding id: UUID? = nil) -> Set<UInt8> {
        Set(layers.filter { $0.id != id }.flatMap { $0.kind.elementTypes })
    }
    func canAdd(_ k: LayerKind) -> Bool { k.elementTypes.allSatisfy { !usedTypes().contains($0) } }
}

/// Values shown in the editor preview (the watch fills in the real ones).
struct Sample: Equatable {
    var hour = 10, minute = 9, second = 30
    var day = 24, month = 11, weekday = 2
    var steps = 8412, heart = 72, kcal = 326
    var distance = 5.4
    var battery = 86

    static let classic = Sample()

    func at(_ date: Date) -> Sample {
        var s = self
        let c = Calendar.current.dateComponents([.hour, .minute, .second, .day, .month, .weekday], from: date)
        s.hour = c.hour ?? 10; s.minute = c.minute ?? 9; s.second = c.second ?? 0
        s.day = c.day ?? 1; s.month = c.month ?? 1; s.weekday = (c.weekday ?? 1) - 1
        return s
    }
}

// MARK: - layer factories

extension Layer {
    static func make(_ k: LayerKind, at p: CGPoint = CGPoint(x: 205, y: 251)) -> Layer {
        var l = Layer(k)
        l.x = Double(p.x); l.y = Double(p.y)
        switch k {
        case .time:
            l.font = .sf(118, .thin); l.fill = .solid(.white); l.fill2 = .solid(.white); l.spacing = 28
        case .date, .month, .seconds:
            l.font = .sf(28, .semibold); l.fill = .solid(.white)
        case .weekday:
            l.font = .sf(26, .bold); l.fill = .solid(.orange)
        case .ampm:
            l.font = .sf(22, .medium); l.fill = .solid(.grey)
        case .steps: l.font = .sf(32, .semibold, .rounded); l.fill = .solid(.white)
        case .heart: l.font = .sf(32, .semibold, .rounded); l.fill = .solid(.red)
        case .calories: l.font = .sf(32, .semibold, .rounded); l.fill = .solid(.orange)
        case .distance: l.font = .sf(32, .semibold, .rounded); l.fill = .solid(.cyan)
        case .battery: l.font = .sf(28, .semibold, .rounded); l.fill = .solid(.green)
        case .hands: l.x = 205; l.y = 251
        case .text: l.text = "OHW"; l.font = .sf(30, .bold); l.fill = .solid(.white)
        case .symbol: l.symbol = "heart.fill"; l.font = .sf(30, .semibold); l.fill = .solid(.red)
        case .shape: l.w = 180; l.h = 90; l.corner = 26; l.fill = .solid(.card)
        case .ring: l.w = 150; l.h = 150; l.fill = .linear(.green, .mint, 0); l.lineWidth = 14
        case .dial: l.w = 390; l.h = 390
        case .image: l.w = 160; l.h = 160; l.corner = 24; l.fill = .none
        case .glow: l.w = 300; l.h = 300; l.fill = .solid(.indigo.alpha(0.7)); l.blend = .screen
        }
        return l
    }

    var hasSize: Bool { [.shape, .ring, .dial, .image, .glow].contains(kind) }
    var hasFont: Bool { [.text, .symbol].contains(kind) || (kind.isLive && kind != .hands) }
}
