import AppKit

// MARK: - starter templates and multi-layer widgets

enum ComposerTemplates {
    struct Template: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let make: () -> FaceDoc
    }

    static let all: [Template] = [
        Template(id: "aurora", title: "Aurora", subtitle: "Glowing orbs, thin time, glass stats", make: aurora),
        Template(id: "meridian", title: "Meridian", subtitle: "Full-screen analog with a date window", make: meridian),
        Template(id: "rings", title: "Rings", subtitle: "Activity rings with live values", make: rings),
        Template(id: "neon", title: "Neon", subtitle: "Gradient digits, segmented arc, glow", make: neon),
        Template(id: "mono", title: "Paper", subtitle: "Light, typographic, outlined minutes", make: paper),
        Template(id: "portrait", title: "Portrait", subtitle: "Your photo with legible time", make: portrait),
        Template(id: "blank", title: "Blank", subtitle: "Just the time — build from here", make: blank),
    ]

    static func L(_ k: LayerKind, _ x: Double, _ y: Double, _ f: (inout Layer) -> Void = { _ in }) -> Layer {
        var l = Layer.make(k, at: CGPoint(x: x, y: y)); f(&l); return l
    }

    static func label(_ s: String, _ x: Double, _ y: Double, size: Double = 13, color: RGBA = .grey, tracking: Double = 1.2) -> Layer {
        L(.text, x, y) { $0.text = s; $0.name = "Label \(s)"; $0.font = .sf(size, .semibold); $0.font.tracking = tracking; $0.fill = .solid(color) }
    }

    static func aurora() -> FaceDoc {
        var d = FaceDoc(name: "Aurora")
        d.background.fill = .solid(RGBA(0x05050A))
        d.layers = [
            L(.glow, 90, 120) { $0.name = "Orb violet"; $0.w = 400; $0.h = 400; $0.fill = .solid(.purple.alpha(0.75)) },
            L(.glow, 350, 300) { $0.name = "Orb mint"; $0.w = 360; $0.h = 360; $0.fill = .solid(.mint.alpha(0.5)) },
            L(.glow, 190, 540) { $0.name = "Orb amber"; $0.w = 420; $0.h = 360; $0.fill = .solid(.orange.alpha(0.5)) },
            L(.shape, 205, 398) { $0.name = "Glass card"; $0.w = 374; $0.h = 158; $0.corner = 36; $0.material = .glass; $0.glassBlur = 22
                $0.fill = .solid(RGBA(0xFFFFFF, 0.10)); $0.stroke = Stroke(on: true, width: 1, color: RGBA(0xFFFFFF, 0.16)) },
            L(.symbol, 92, 358) { $0.symbol = "heart.fill"; $0.font.size = 20; $0.fill = .solid(.red) },
            L(.symbol, 205, 358) { $0.symbol = "figure.walk"; $0.font.size = 20; $0.fill = .solid(.green) },
            L(.symbol, 318, 358) { $0.symbol = "flame.fill"; $0.font.size = 20; $0.fill = .solid(.orange) },
            label("BPM", 92, 450), label("STEPS", 205, 450), label("KCAL", 318, 450),
            L(.weekday, 178, 72) { $0.font = .sf(24, .bold); $0.fill = .solid(RGBA(0xFFFFFF, 0.92)); $0.shadow = .soft },
            L(.date, 240, 72) { $0.font = .sf(24, .bold); $0.fill = .solid(.orange); $0.shadow = .soft },
            L(.time, 205, 180) { $0.font = .sf(122, .thin); $0.spacing = 26; $0.shadow = .glow(RGBA(0xFFFFFF, 0.35), 12, passes: 1) },
            L(.heart, 92, 405) { $0.font = .sf(30, .semibold, .rounded); $0.fill = .solid(.white) },
            L(.steps, 205, 405) { $0.font = .sf(30, .semibold, .rounded); $0.fill = .solid(.white) },
            L(.calories, 318, 405) { $0.font = .sf(30, .semibold, .rounded); $0.fill = .solid(.white) },
        ]
        return d
    }

    static func meridian() -> FaceDoc {
        var d = FaceDoc(name: "Meridian")
        d.background.fill = .radial(RGBA(0x1D1D26), RGBA(0x030304))
        var dial = Layer.make(.dial)
        dial.w = 398; dial.h = 490
        dial.dial = DialSpec(shape: .rect, ticks: 60, majorEvery: 5, majorLength: 16, minorLength: 7, majorWidth: 3.5, minorWidth: 1.4,
                             majorColor: .white, minorColor: RGBA(0x6E6E73), accentTop: true, accent: .orange, numerals: .all,
                             numeralFont: .sf(40, .semibold, .rounded), numeralColor: .white, numeralInset: 50, hideThree: true)
        var hands = Layer.make(.hands)
        hands.hands = HandsSpec(style: .sword, hourLength: 100, minuteLength: 146, secondLength: 148, hourWidth: 12, minuteWidth: 9,
                                secondWidth: 2.4, tail: 20, hourColor: .white, minuteColor: .white, secondColor: .orange, lume: true,
                                lumeColor: RGBA(0xBFFFD0), showSeconds: true, capSize: 7, capColor: .orange, shadow: true)
        d.layers = [
            dial,
            L(.ring, 205, 251) { $0.name = "Inner track"; $0.w = 230; $0.h = 230; $0.lineWidth = 1.2; $0.ringProgress = 0
                $0.trackColor = RGBA(0xFFFFFF, 0.12) },
            L(.shape, 318, 251) { $0.name = "Date window"; $0.w = 58; $0.h = 42; $0.corner = 10; $0.fill = .solid(RGBA(0x16161A))
                $0.stroke = Stroke(on: true, width: 1.5, color: .orange) },
            label("MERIDIAN", 205, 170, size: 13, color: RGBA(0xAEAEB2), tracking: 4),
            L(.weekday, 205, 336) { $0.font = .sf(17, .bold); $0.font.tracking = 2; $0.fill = .solid(.orange) },
            L(.date, 318, 251) { $0.font = .sf(24, .semibold, .rounded); $0.fill = .solid(.white) },
            hands,
        ]
        return d
    }

    static func rings() -> FaceDoc {
        var d = FaceDoc(name: "Rings")
        d.background.fill = .solid(.black)
        func ring(_ name: String, _ w: Double, _ a: RGBA, _ b: RGBA, _ p: Double) -> Layer {
            L(.ring, 205, 300) { $0.name = name; $0.w = w; $0.h = w; $0.lineWidth = 26; $0.fill = .linear(a, b, 0)
                $0.ringProgress = p; $0.trackColor = a.alpha(0.2) }
        }
        d.layers = [
            ring("Move ring", 254, RGBA(0xFA114F), RGBA(0xFF6482), 0.78),
            ring("Exercise ring", 194, RGBA(0x92E82A), RGBA(0xC9FF4D), 0.62),
            ring("Stand ring", 134, RGBA(0x1EEAEF), RGBA(0x8CF6FF), 0.9),
            L(.weekday, 180, 30) { $0.font = .sf(18, .bold); $0.fill = .solid(RGBA(0xFA114F)) },
            L(.date, 228, 30) { $0.font = .sf(18, .bold); $0.fill = .solid(.white) },
            L(.time, 205, 94) { $0.font = .sf(86, .semibold, .rounded); $0.spacing = 20 },
            L(.calories, 92, 466) { $0.font = .sf(26, .bold, .rounded); $0.fill = .solid(RGBA(0xFA114F)) },
            L(.steps, 205, 466) { $0.font = .sf(26, .bold, .rounded); $0.fill = .solid(RGBA(0x92E82A)) },
            L(.distance, 318, 466) { $0.font = .sf(26, .bold, .rounded); $0.fill = .solid(RGBA(0x1EEAEF)) },
        ]
        return d
    }

    static func neon() -> FaceDoc {
        var d = FaceDoc(name: "Neon")
        d.background.fill = .linear(RGBA(0x12002A), RGBA(0x000000), 90)
        var dial = Layer.make(.dial)
        dial.w = 384; dial.h = 384
        dial.dial = DialSpec(shape: .circle, ticks: 60, majorEvery: 5, majorLength: 14, minorLength: 6, majorWidth: 3, minorWidth: 1.2,
                             majorColor: .cyan, minorColor: RGBA(0xFF2D95, 0.45), accentTop: true, accent: .pink, numerals: .none,
                             numeralFont: .sf(30, .bold), numeralColor: .white, numeralInset: 40, hideThree: false)
        dial.shadow = .glow(.cyan.alpha(0.8), 8, passes: 1)
        d.layers = [
            L(.glow, 205, 251) { $0.name = "Core glow"; $0.w = 360; $0.h = 360; $0.fill = .solid(RGBA(0xFF2D95, 0.28)) },
            dial,
            L(.ring, 205, 251) { $0.name = "Arc"; $0.w = 316; $0.h = 316; $0.lineWidth = 8; $0.ringStart = 210; $0.ringSweep = 300
                $0.ringProgress = 0.7; $0.segments = 30; $0.roundCaps = false; $0.fill = .linear(.pink, .cyan, 0)
                $0.trackColor = RGBA(0xFFFFFF, 0.08); $0.shadow = .glow(RGBA(0xFF2D95, 0.7), 8, passes: 1) },
            L(.weekday, 205, 128) { $0.font = .sf(18, .heavy); $0.font.tracking = 3; $0.fill = .solid(.cyan); $0.shadow = .glow(.cyan, 6, passes: 1) },
            L(.time, 205, 251) { $0.timeLayout = .stacked; $0.spacing = 6; $0.font = .sf(92, .heavy, .rounded)
                $0.fill = .linear(.cyan, RGBA(0x4C6BFF), 90); $0.fill2 = .linear(.pink, .purple, 90)
                $0.shadow = .glow(RGBA(0xFF2D95, 0.85), 14, passes: 2) },
            L(.heart, 205, 374) { $0.font = .sf(22, .bold, .rounded); $0.fill = .solid(.pink); $0.shadow = .glow(.pink, 6, passes: 1) },
        ]
        return d
    }

    static func paper() -> FaceDoc {
        var d = FaceDoc(name: "Paper")
        d.background.fill = .linear(RGBA(0xF4F1EA), RGBA(0xE6E1D6), 90)
        let ink = RGBA(0x141414)
        d.layers = [
            L(.shape, 362, 52) { $0.name = "Red dot"; $0.shape = .ellipse; $0.w = 20; $0.h = 20; $0.fill = .solid(RGBA(0xE5372B)) },
            L(.shape, 205, 420) { $0.name = "Rule"; $0.shape = .rect; $0.w = 350; $0.h = 2; $0.fill = .solid(ink) },
            L(.time, 168, 228) { $0.timeLayout = .stacked; $0.spacing = 8; $0.font = .sf(160, .heavy)
                $0.font.tracking = -4; $0.fill = .solid(ink); $0.fill2 = .none; $0.stroke = Stroke(on: true, width: 2.5, color: ink) },
            L(.weekday, 112, 456) { $0.nameStyle = .full; $0.font = .sf(22, .semibold); $0.font.tracking = 2; $0.fill = .solid(ink) },
            L(.date, 352, 456) { $0.font = .sf(22, .semibold); $0.fill = .solid(RGBA(0xE5372B)) },
        ]
        return d
    }

    static func portrait() -> FaceDoc {
        var d = FaceDoc(name: "Portrait")
        d.background.kind = .fill
        d.background.fill = .linear(RGBA(0x3A2B6B), RGBA(0xFF8A3D), 70)
        d.background.vignette = 0.35
        d.layers = [
            L(.shape, 205, 400) { $0.name = "Shade"; $0.shape = .rect; $0.w = 410; $0.h = 204
                $0.fill = .linear(RGBA(0x000000, 0), RGBA(0x000000, 0.8), 90) },
            L(.weekday, 70, 318) { $0.font = .sf(22, .bold); $0.fill = .solid(.orange); $0.shadow = .soft },
            L(.date, 126, 318) { $0.font = .sf(22, .bold); $0.fill = .solid(.white); $0.shadow = .soft },
            L(.time, 160, 380) { $0.font = .sf(104, .light); $0.spacing = 22; $0.shadow = .soft },
            L(.symbol, 50, 462) { $0.symbol = "heart.fill"; $0.font.size = 18; $0.fill = .solid(.red); $0.shadow = .soft },
            L(.heart, 92, 462) { $0.font = .sf(22, .semibold, .rounded); $0.shadow = .soft; $0.fill = .solid(.white) },
            L(.symbol, 170, 462) { $0.symbol = "figure.walk"; $0.font.size = 18; $0.fill = .solid(.green); $0.shadow = .soft },
            L(.steps, 228, 462) { $0.font = .sf(22, .semibold, .rounded); $0.shadow = .soft; $0.fill = .solid(.white) },
        ]
        return d
    }

    static func blank() -> FaceDoc {
        var d = FaceDoc(name: "Untitled face")
        d.layers = [Layer.make(.time)]
        return d
    }

    // MARK: widgets

    struct Widget: Identifiable {
        let id: String
        let title: String
        let icon: String
        let needs: [LayerKind]
        let make: (CGPoint) -> [Layer]
    }

    static let widgets: [Widget] = [
        Widget(id: "heartpill", title: "Heart pill", icon: "heart.circle.fill", needs: [.heart]) { p in
            [L(.shape, p.x, p.y) { $0.name = "Pill"; $0.shape = .capsule; $0.w = 150; $0.h = 56; $0.material = .glass
                $0.fill = .solid(RGBA(0xFFFFFF, 0.1)); $0.stroke = Stroke(on: true, width: 1, color: RGBA(0xFFFFFF, 0.15)) },
             L(.symbol, p.x - 42, p.y) { $0.symbol = "heart.fill"; $0.font.size = 22; $0.fill = .solid(.red) },
             L(.heart, p.x + 18, p.y) { $0.font = .sf(28, .semibold, .rounded) }]
        },
        Widget(id: "stepsring", title: "Steps ring", icon: "figure.walk.circle.fill", needs: [.steps]) { p in
            [L(.ring, p.x, p.y) { $0.name = "Steps ring"; $0.w = 124; $0.h = 124; $0.lineWidth = 11; $0.fill = .linear(.green, .mint, 0)
                $0.trackColor = RGBA.green.alpha(0.18) },
             L(.symbol, p.x, p.y - 18) { $0.symbol = "figure.walk"; $0.font.size = 20; $0.fill = .solid(.green) },
             L(.steps, p.x, p.y + 16) { $0.font = .sf(20, .bold, .rounded) }]
        },
        Widget(id: "statcard", title: "Stat card", icon: "rectangle.on.rectangle", needs: [.calories]) { p in
            [L(.shape, p.x, p.y) { $0.name = "Card"; $0.w = 176; $0.h = 104; $0.corner = 26; $0.fill = .solid(.card) },
             L(.symbol, p.x - 62, p.y - 26) { $0.symbol = "flame.fill"; $0.font.size = 18; $0.fill = .solid(.orange) },
             label("KCAL", p.x + 54, p.y - 26),
             L(.calories, p.x, p.y + 18) { $0.font = .sf(38, .medium, .rounded); $0.fill = .solid(.white) }]
        },
        Widget(id: "datestack", title: "Date stack", icon: "calendar.circle.fill", needs: [.weekday, .date]) { p in
            [L(.weekday, p.x, p.y - 20) { $0.font = .sf(18, .bold); $0.fill = .solid(.red) },
             L(.date, p.x, p.y + 14) { $0.font = .sf(34, .regular) }]
        },
        Widget(id: "distchip", title: "Distance chip", icon: "location.circle.fill", needs: [.distance]) { p in
            [L(.shape, p.x, p.y) { $0.name = "Chip"; $0.shape = .capsule; $0.w = 150; $0.h = 50; $0.fill = .solid(RGBA.cyan.alpha(0.16)) },
             L(.symbol, p.x - 44, p.y) { $0.symbol = "location.fill"; $0.font.size = 17; $0.fill = .solid(.cyan) },
             L(.distance, p.x + 14, p.y) { $0.font = .sf(24, .bold, .rounded); $0.fill = .solid(.cyan) }]
        },
        Widget(id: "minutetrack", title: "Minute track", icon: "circle.dotted", needs: []) { p in
            [L(.dial, p.x, p.y) { $0.name = "Minute track"; $0.w = 396; $0.h = 488; $0.dial.shape = .rect; $0.dial.numerals = .none
                $0.dial.majorLength = 12; $0.dial.minorLength = 5 }]
        },
    ]
}
