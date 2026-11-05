import SwiftUI
import AppKit

// MARK: - reusable inspector controls

struct InspectorSection<Content: View>: View {
    let title: String
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content
    @State private var open = true
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { withAnimation(.snappy) { open.toggle() } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                        Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).kerning(0.7)
                    }.foregroundStyle(.secondary)
                }.buttonStyle(.plain)
                Spacer()
                trailing
            }
            if open { content }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct NumberRow: View {
    let label: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1
    var unit: String = ""
    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
            Slider(value: Binding(get: { min(max(value, range.lowerBound), range.upperBound) },
                                  set: { value = (($0 / step).rounded() * step) }), in: range)
                .controlSize(.small)
            TextField("", value: $value, format: .number.precision(.fractionLength(step < 1 ? 1 : 0)))
                .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 52).multilineTextAlignment(.trailing)
            if !unit.isEmpty { Text(unit).font(.caption2).foregroundStyle(.tertiary).frame(width: 12, alignment: .leading) }
        }
    }
}

struct IntRow: View {
    let label: String
    @Binding var value: Int
    var range: ClosedRange<Int>
    var body: some View {
        NumberRow(label: label, value: Binding(get: { Double(value) }, set: { value = Int($0.rounded()) }),
                  range: Double(range.lowerBound)...Double(range.upperBound))
    }
}

struct ColorRow: View {
    let label: String
    @Binding var color: RGBA
    var swatches = true
    static let palette: [RGBA] = [.white, .grey, RGBA(0x1C1C1E), .black, .red, .pink, .orange, .yellow, .green, .mint, .cyan,
                                  RGBA(0x0A84FF), .purple]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(label).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
                ColorPicker("", selection: Binding(get: { color.color }, set: { color = RGBA($0) }), supportsOpacity: true).labelsHidden()
                Text(hex).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if color.a < 0.995 { Text("\(Int(color.a * 100))%").font(.caption2).foregroundStyle(.tertiary) }
            }
            if swatches {
                HStack(spacing: 3) {
                    ForEach(Self.palette, id: \.self) { c in
                        Circle().fill(c.color).frame(width: 12, height: 12)
                            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                            .onTapGesture { color = c.alpha(color.a) }
                    }
                }.padding(.leading, 82)
            }
        }
    }
    var hex: String { String(format: "#%02X%02X%02X", Int(color.r * 255), Int(color.g * 255), Int(color.b * 255)) }
}

struct FillEditor: View {
    @Binding var fill: Fill
    var kinds: [FillKind] = [.solid, .linear, .radial, .angular, .none]
    static let presets: [(String, Fill)] = [
        ("Sunset", .linear(RGBA(0xFF5F6D), RGBA(0xFFC371), 90)), ("Ocean", .linear(RGBA(0x00C6FF), RGBA(0x0072FF), 90)),
        ("Neon", .linear(.pink, .cyan, 0)), ("Mint", .linear(.green, .mint, 90)), ("Fire", .linear(.yellow, .red, 90)),
        ("Violet", .linear(.purple, .indigo, 135)), ("Chrome", .linear(.white, RGBA(0x8E8E93), 90)), ("Gold", .linear(RGBA(0xFFE29F), RGBA(0xB8860B), 90)),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $fill.kind) { ForEach(kinds) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            if fill.kind != .none {
                ColorRow(label: fill.kind == .solid ? "Colour" : "From", color: $fill.c1)
                if fill.kind != .solid {
                    ColorRow(label: "To", color: $fill.c2, swatches: false)
                    if fill.kind != .radial { NumberRow(label: "Angle", value: $fill.angle, range: 0...360, unit: "°") }
                    HStack(spacing: 5) {
                        ForEach(Self.presets, id: \.0) { p in
                            RoundedRectangle(cornerRadius: 5)
                                .fill(LinearGradient(colors: [p.1.c1.color, p.1.c2.color], startPoint: .top, endPoint: .bottom))
                                .frame(width: 22, height: 16).help(p.0)
                                .onTapGesture { let k = fill.kind; fill = p.1; fill.kind = k }
                        }
                    }
                }
            }
        }
    }
}

struct FontEditor: View {
    @Binding var font: FontSpec
    var sizeRange: ClosedRange<Double> = 6...220
    static let families: [String] = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }.sorted()
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Picker("", selection: $font.design) { ForEach(FontDesign.allCases) { Text($0.title).tag($0) } }
                    .labelsHidden().controlSize(.small)
                Picker("", selection: $font.weight) { ForEach(FontWeight.allCases) { Text($0.title).tag($0) } }
                    .labelsHidden().controlSize(.small).frame(width: 104)
                Toggle(isOn: $font.italic) { Image(systemName: "italic") }.toggleStyle(.button).controlSize(.small)
            }
            if font.design == .custom {
                Picker("Family", selection: $font.family) { ForEach(Self.families, id: \.self) { Text($0).tag($0) } }
                    .controlSize(.small)
            }
            NumberRow(label: "Size", value: $font.size, range: sizeRange, unit: "pt")
            NumberRow(label: "Tracking", value: $font.tracking, range: -10...20, step: 0.5)
        }
    }
}

struct ShadowEditor: View {
    @Binding var shadow: Shadow
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Enabled", isOn: $shadow.on).toggleStyle(.switch).controlSize(.mini)
                Spacer()
                Button("Soft") { shadow = .soft }.controlSize(.small)
                Button("Glow") { shadow = .glow(shadow.on ? shadow.color.alpha(max(0.6, shadow.color.a)) : RGBA.white.alpha(0.7)) }.controlSize(.small)
            }
            if shadow.on {
                ColorRow(label: "Colour", color: $shadow.color)
                NumberRow(label: "Blur", value: $shadow.radius, range: 0...40)
                NumberRow(label: "Offset X", value: $shadow.dx, range: -20...20)
                NumberRow(label: "Offset Y", value: $shadow.dy, range: -20...20)
                IntRow(label: "Intensity", value: $shadow.passes, range: 1...4)
            }
        }
    }
}

struct StrokeEditor: View {
    @Binding var stroke: Stroke
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Outline", isOn: $stroke.on).toggleStyle(.switch).controlSize(.mini)
            if stroke.on {
                NumberRow(label: "Width", value: $stroke.width, range: 0.5...16, step: 0.5)
                ColorRow(label: "Colour", color: $stroke.color)
            }
        }
    }
}

// MARK: - inspector

struct InspectorPanel: View {
    @ObservedObject var cs: ComposerState
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let l = cs.single {
                    LayerInspector(cs: cs, id: l.id).id(l.id)
                } else if cs.selection.count > 1 {
                    MultiInspector(cs: cs)
                } else {
                    BackgroundInspector(cs: cs)
                }
            }
            .padding(12)
            .frame(width: 318)
        }
    }
}

struct AlignBar: View {
    @ObservedObject var cs: ComposerState
    var body: some View {
        HStack(spacing: 2) {
            ForEach([("align.horizontal.left", ComposerState.Align.left), ("align.horizontal.center", .hcenter),
                     ("align.horizontal.right", .right), ("align.vertical.top", .top), ("align.vertical.center", .vcenter),
                     ("align.vertical.bottom", .bottom)], id: \.0) { s in
                Button { cs.align(s.1) } label: { Image(systemName: s.0).frame(width: 22, height: 20) }
                    .buttonStyle(.borderless).help(cs.selection.count > 1 ? "Align selection" : "Align to screen")
            }
        }
    }
}

struct MultiInspector: View {
    @ObservedObject var cs: ComposerState
    var body: some View {
        InspectorSection(title: "\(cs.selection.count) layers selected") {
            VStack(alignment: .leading, spacing: 10) {
                AlignBar(cs: cs)
                HStack {
                    Button { cs.distribute(horizontal: true) } label: { Label("Distribute ↔", systemImage: "distribute.horizontal.center") }
                    Button { cs.distribute(horizontal: false) } label: { Label("Distribute ↕", systemImage: "distribute.vertical.center") }
                }.controlSize(.small).disabled(cs.selection.count < 3)
                HStack {
                    Button { cs.duplicateSelection() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                    Button(role: .destructive) { cs.deleteSelection() } label: { Label("Delete", systemImage: "trash") }
                }.controlSize(.small)
                Text("Drag on the canvas to move them together. Arrow keys nudge (⇧ for 10 px).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct LayerInspector: View {
    @ObservedObject var cs: ComposerState
    let id: UUID

    var l: Layer { cs.layer(id) ?? Layer(.text) }

    func b<T>(_ kp: WritableKeyPath<Layer, T>) -> Binding<T> {
        let fallback = l[keyPath: kp]
        return Binding(get: { cs.layer(id)?[keyPath: kp] ?? fallback },
                       set: { v in cs.update(id, "\(kp)") { $0[keyPath: kp] = v } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            InspectorSection(title: "Layout", trailing: AnyView(AlignBar(cs: cs))) {
                VStack(spacing: 8) {
                    NumberRow(label: "X", value: b(\.x), range: -100...510)
                    NumberRow(label: "Y", value: b(\.y), range: -100...600)
                    if !l.kind.isLive { NumberRow(label: "Rotation", value: b(\.rotation), range: -180...180, unit: "°") }
                    if l.kind != .hands { NumberRow(label: "Opacity", value: b(\.opacity), range: 0...1, step: 0.01) }
                    if !l.kind.isLive {
                        HStack {
                            Text("Blend").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
                            Picker("", selection: b(\.blend)) { ForEach(BlendKind.allCases) { Text($0.title).tag($0) } }
                                .labelsHidden().controlSize(.small)
                        }
                    }
                }
            }
            kindSections
            if l.hasFont {
                InspectorSection(title: "Typography") {
                    FontEditor(font: b(\.font), sizeRange: l.kind == .symbol ? 6...160 : 6...220)
                }
            }
            if showsFill {
                InspectorSection(title: l.kind == .time ? "Hours" : (l.kind == .image ? "Tint" : "Fill")) {
                    FillEditor(fill: b(\.fill), kinds: fillKinds)
                }
            }
            if l.kind == .time {
                InspectorSection(title: "Minutes") { FillEditor(fill: b(\.fill2)) }
            }
            if [.text, .shape, .image].contains(l.kind) || (l.kind.isLive && l.kind != .hands) {
                InspectorSection(title: "Outline") { StrokeEditor(stroke: b(\.stroke)) }
            }
            if l.kind != .hands && l.kind != .glow {
                InspectorSection(title: "Shadow & glow") { ShadowEditor(shadow: b(\.shadow)) }
            }
            footer
        }
    }

    var showsFill: Bool { ![.hands, .dial, .glow].contains(l.kind) }
    var fillKinds: [FillKind] {
        switch l.kind {
        case .ring: return [.solid, .linear]
        case .image: return [.none, .solid, .linear, .radial]
        default: return [.solid, .linear, .radial, .angular, .none]
        }
    }

    var header: some View {
        HStack(spacing: 10) {
            Image(systemName: l.kind.icon).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(l.kind.isLive ? Color.ok : Color.brand)
                .frame(width: 32, height: 32)
                .background((l.kind.isLive ? Color.ok : Color.brand).opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: b(\.name)).textFieldStyle(.plain).font(.system(size: 14, weight: .semibold))
                HStack(spacing: 4) {
                    Text(l.kind.isLive ? "LIVE · updated by the watch" : "ARTWORK · baked into the background")
                    if l.kind.experimental { Text("· experimental").foregroundStyle(.orange) }
                }.font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(isOn: b(\.visible)) { Image(systemName: l.visible ? "eye" : "eye.slash") }.toggleStyle(.button).controlSize(.small)
            Toggle(isOn: b(\.locked)) { Image(systemName: l.locked ? "lock.fill" : "lock.open") }.toggleStyle(.button).controlSize(.small)
        }
    }

    var footer: some View {
        HStack {
            Button { cs.reorder(id, by: 1) } label: { Image(systemName: "square.2.layers.3d.top.filled") }.help("Bring forward")
            Button { cs.reorder(id, by: -1) } label: { Image(systemName: "square.2.layers.3d.bottom.filled") }.help("Send backward")
            Spacer()
            if !l.kind.isLive {
                Button { cs.duplicateSelection() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            }
            Button(role: .destructive) { cs.deleteSelection() } label: { Label("Delete", systemImage: "trash") }
        }
        .controlSize(.small)
    }

    @ViewBuilder var kindSections: some View {
        switch l.kind {
        case .time:
            InspectorSection(title: "Time") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Layout", selection: b(\.timeLayout)) { ForEach(TimeLayout.allCases) { Text($0.title).tag($0) } }
                        .pickerStyle(.segmented).controlSize(.small)
                    if l.timeLayout == .inline {
                        Picker("Separator", selection: b(\.separator)) { ForEach(Separator.allCases) { Text($0.title).tag($0) } }
                            .pickerStyle(.segmented).controlSize(.small)
                    }
                    NumberRow(label: l.timeLayout == .inline ? "Gap" : "Line gap", value: b(\.spacing), range: -20...80)
                    Text("12/24-hour follows the watch. Add an AM/PM layer to preview 12-hour time.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        case .weekday:
            InspectorSection(title: "Weekday") {
                Picker("Style", selection: b(\.nameStyle)) { ForEach(NameStyle.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).controlSize(.small)
            }
        case .ampm:
            InspectorSection(title: "AM / PM") {
                Picker("Case", selection: b(\.nameStyle)) { Text("AM").tag(NameStyle.upper); Text("am").tag(NameStyle.title) }
                    .pickerStyle(.segmented).controlSize(.small)
            }
        case .text:
            InspectorSection(title: "Text") {
                TextField("Text", text: b(\.text), axis: .vertical).lineLimit(1...5).textFieldStyle(.roundedBorder)
            }
        case .symbol:
            SymbolPicker(symbol: b(\.symbol))
        case .shape:
            InspectorSection(title: "Shape") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 3) {
                        ForEach(ShapeKind.allCases) { k in
                            Button { cs.update(id) { $0.shape = k } } label: {
                                Image(systemName: k.symbol).frame(width: 30, height: 22)
                                    .background(l.shape == k ? Color.brand.opacity(0.3) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.borderless).help(k.title)
                        }
                    }
                    NumberRow(label: "Width", value: b(\.w), range: 1...420)
                    NumberRow(label: "Height", value: b(\.h), range: 1...520)
                    if l.shape == .rounded { NumberRow(label: "Corner", value: b(\.corner), range: 0...200) }
                    if l.shape == .polygon || l.shape == .star { IntRow(label: l.shape == .star ? "Points" : "Sides", value: b(\.sides), range: 3...16) }
                    Picker("Material", selection: b(\.material)) { ForEach(MaterialKind.allCases) { Text($0.title).tag($0) } }
                        .pickerStyle(.segmented).controlSize(.small)
                    if l.material == .glass {
                        NumberRow(label: "Blur", value: b(\.glassBlur), range: 0...40)
                        Text("Frosted glass blurs whatever artwork is behind it. Use a translucent fill for the tint.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        case .ring:
            InspectorSection(title: "Ring") {
                VStack(spacing: 8) {
                    NumberRow(label: "Diameter", value: Binding(get: { l.w }, set: { v in cs.update(id, "ringW") { $0.w = v; $0.h = v } }), range: 10...500)
                    NumberRow(label: "Thickness", value: b(\.lineWidth), range: 0.5...80, step: 0.5)
                    NumberRow(label: "Start", value: b(\.ringStart), range: 0...360, unit: "°")
                    NumberRow(label: "Sweep", value: b(\.ringSweep), range: 1...360, unit: "°")
                    NumberRow(label: "Progress", value: b(\.ringProgress), range: 0...1, step: 0.01)
                    IntRow(label: "Segments", value: b(\.segments), range: 0...120)
                    Toggle("Round caps", isOn: b(\.roundCaps)).toggleStyle(.switch).controlSize(.mini).frame(maxWidth: .infinity, alignment: .leading)
                    ColorRow(label: "Track", color: b(\.trackColor))
                    Text("Rings are artwork: progress is a design choice, not live data.").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .dial:
            DialInspector(dial: b(\.dial), w: b(\.w), h: b(\.h))
        case .image:
            InspectorSection(title: "Image") {
                VStack(alignment: .leading, spacing: 8) {
                    Button { if let u = pickImage() { if let d = ComposerState.imageData(u, maxPixel: 900, png: true) { cs.update(id) { $0.imageData = d } } } }
                        label: { Label(l.imageData == nil ? "Choose image…" : "Replace image…", systemImage: "photo.badge.plus") }
                        .controlSize(.small)
                    NumberRow(label: "Width", value: b(\.w), range: 4...420)
                    NumberRow(label: "Height", value: b(\.h), range: 4...520)
                    Picker("Mask", selection: b(\.shape)) {
                        Text("Square").tag(ShapeKind.rect); Text("Rounded").tag(ShapeKind.rounded)
                        Text("Circle").tag(ShapeKind.ellipse); Text("Capsule").tag(ShapeKind.capsule)
                        Text("Hexagon").tag(ShapeKind.polygon); Text("Star").tag(ShapeKind.star)
                    }.pickerStyle(.menu).controlSize(.small)
                    if l.shape == .rounded { NumberRow(label: "Corner", value: b(\.corner), range: 0...200) }
                }
            }
        case .glow:
            InspectorSection(title: "Glow") {
                VStack(spacing: 8) {
                    NumberRow(label: "Width", value: b(\.w), range: 10...800)
                    NumberRow(label: "Height", value: b(\.h), range: 10...800)
                    NumberRow(label: "Softness", value: b(\.softness), range: 0.05...1, step: 0.01)
                    ColorRow(label: "Colour", color: Binding(get: { l.fill.c1 }, set: { v in cs.update(id, "glowc") { $0.fill.c1 = v } }))
                }
            }
        case .hands:
            HandsInspector(hands: b(\.hands))
        default:
            if l.kind.isMetric {
                InspectorSection(title: l.kind.title) {
                    Text(l.kind == .battery
                         ? "Battery uses a watch element that CO FIT never uses. It may not show on every firmware."
                         : "The watch centres the value on this point and grows it in both directions as the number gets longer.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if l.kind == .seconds {
                InspectorSection(title: "Seconds") {
                    Text("Digital seconds use a watch element CO FIT never uses. It may not show on every firmware.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    func pickImage() -> URL? {
        let p = NSOpenPanel(); p.allowedContentTypes = [.image]
        return p.runModal() == .OK ? p.url : nil
    }
}

struct SymbolPicker: View {
    @Binding var symbol: String
    static let common = ["heart.fill", "figure.walk", "flame.fill", "location.fill", "bolt.fill", "moon.stars.fill", "sun.max.fill",
                         "cloud.sun.fill", "drop.fill", "battery.75percent", "bell.fill", "music.note", "star.fill", "sparkles",
                         "leaf.fill", "applelogo", "figure.run", "bicycle", "dumbbell.fill", "lungs.fill", "bed.double.fill",
                         "cup.and.saucer.fill", "airplane", "house.fill", "globe.europe.africa.fill", "crown.fill", "atom", "pawprint.fill"]
    var body: some View {
        InspectorSection(title: "Symbol") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("SF Symbol name", text: $symbol).textFieldStyle(.roundedBorder).controlSize(.small)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 4), count: 8), spacing: 4) {
                    ForEach(Self.common, id: \.self) { s in
                        Image(systemName: s).frame(width: 28, height: 26)
                            .background(symbol == s ? Color.brand.opacity(0.3) : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                            .onTapGesture { symbol = s }.help(s)
                    }
                }
                Text("Any SF Symbol name works — browse them in Apple's SF Symbols app.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct DialInspector: View {
    @Binding var dial: DialSpec
    @Binding var w: Double
    @Binding var h: Double
    var body: some View {
        InspectorSection(title: "Dial") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Shape", selection: $dial.shape) { ForEach(DialShape.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).controlSize(.small)
                NumberRow(label: "Width", value: $w, range: 40...420)
                NumberRow(label: "Height", value: $h, range: 40...520)
                Picker("Ticks", selection: $dial.ticks) { Text("None").tag(0); Text("12").tag(12); Text("60").tag(60); Text("120").tag(120) }
                    .pickerStyle(.segmented).controlSize(.small)
                if dial.ticks > 0 {
                    IntRow(label: "Major every", value: $dial.majorEvery, range: 0...30)
                    NumberRow(label: "Major len", value: $dial.majorLength, range: 0...80)
                    NumberRow(label: "Major width", value: $dial.majorWidth, range: 0.5...14, step: 0.5)
                    NumberRow(label: "Minor len", value: $dial.minorLength, range: 0...60)
                    NumberRow(label: "Minor width", value: $dial.minorWidth, range: 0.5...10, step: 0.5)
                    ColorRow(label: "Major", color: $dial.majorColor, swatches: false)
                    ColorRow(label: "Minor", color: $dial.minorColor, swatches: false)
                }
                Toggle("Accent at 12", isOn: $dial.accentTop).toggleStyle(.switch).controlSize(.mini)
                if dial.accentTop { ColorRow(label: "Accent", color: $dial.accent, swatches: false) }
                Divider()
                Picker("Numerals", selection: $dial.numerals) { ForEach(NumeralStyle.allCases) { Text($0.title).tag($0) } }
                    .controlSize(.small)
                if dial.numerals != .none {
                    NumberRow(label: "Inset", value: $dial.numeralInset, range: 0...200)
                    ColorRow(label: "Colour", color: $dial.numeralColor, swatches: false)
                    Toggle("Hide 3 (room for a date)", isOn: $dial.hideThree).toggleStyle(.switch).controlSize(.mini)
                    FontEditor(font: $dial.numeralFont, sizeRange: 6...120)
                }
            }
        }
    }
}

struct HandsInspector: View {
    @Binding var hands: HandsSpec
    var body: some View {
        InspectorSection(title: "Hands") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Style", selection: $hands.style) { ForEach(HandStyle.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).controlSize(.small)
                Text("HOUR").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                NumberRow(label: "Length", value: $hands.hourLength, range: 20...148)
                NumberRow(label: "Width", value: $hands.hourWidth, range: 1...30, step: 0.5)
                ColorRow(label: "Colour", color: $hands.hourColor, swatches: false)
                Text("MINUTE").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                NumberRow(label: "Length", value: $hands.minuteLength, range: 20...148)
                NumberRow(label: "Width", value: $hands.minuteWidth, range: 1...30, step: 0.5)
                ColorRow(label: "Colour", color: $hands.minuteColor, swatches: false)
                Toggle("Second hand", isOn: $hands.showSeconds).toggleStyle(.switch).controlSize(.mini)
                if hands.showSeconds {
                    NumberRow(label: "Length", value: $hands.secondLength, range: 20...148)
                    NumberRow(label: "Width", value: $hands.secondWidth, range: 0.5...12, step: 0.5)
                    ColorRow(label: "Colour", color: $hands.secondColor, swatches: false)
                }
                Divider()
                NumberRow(label: "Tail", value: $hands.tail, range: 0...28)
                NumberRow(label: "Cap", value: $hands.capSize, range: 0...16, step: 0.5)
                ColorRow(label: "Cap colour", color: $hands.capColor, swatches: false)
                Toggle("Lume inlay", isOn: $hands.lume).toggleStyle(.switch).controlSize(.mini)
                if hands.lume || hands.style == .skeleton { ColorRow(label: "Lume", color: $hands.lumeColor, swatches: false) }
                Toggle("Drop shadow", isOn: $hands.shadow).toggleStyle(.switch).controlSize(.mini)
            }
        }
    }
}

struct BackgroundInspector: View {
    @ObservedObject var cs: ComposerState
    @EnvironmentObject var store: WatchStore

    func b<T>(_ kp: WritableKeyPath<BackgroundSpec, T>) -> Binding<T> {
        Binding(get: { cs.doc.background[keyPath: kp] }, set: { v in cs.mutate("bg\(kp)") { $0.background[keyPath: kp] = v } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.portrait.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(.sky)
                    .frame(width: 32, height: 32).background(Color.sky.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Face name", text: Binding(get: { cs.doc.name }, set: { v in cs.mutate("name") { $0.name = v } }))
                        .textFieldStyle(.plain).font(.system(size: 14, weight: .semibold))
                    Text("BACKGROUND · nothing selected").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            InspectorSection(title: "Background") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: b(\.kind)) { Text("Colour & gradient").tag(BackgroundKind.fill); Text("Photo").tag(BackgroundKind.photo) }
                        .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                    if cs.doc.background.kind == .fill {
                        FillEditor(fill: b(\.fill), kinds: [.solid, .linear, .radial, .angular])
                    } else {
                        Button { choosePhoto() } label: {
                            Label(cs.doc.background.photo == nil ? "Choose photo…" : "Replace photo…", systemImage: "photo.on.rectangle.angled")
                        }.controlSize(.small)
                        NumberRow(label: "Zoom", value: b(\.zoom), range: 1...4, step: 0.05)
                        NumberRow(label: "Pan X", value: b(\.focusX), range: 0...1, step: 0.01)
                        NumberRow(label: "Pan Y", value: b(\.focusY), range: 0...1, step: 0.01)
                        NumberRow(label: "Blur", value: b(\.blur), range: 0...40)
                        NumberRow(label: "Darken", value: b(\.dim), range: 0...0.9, step: 0.01)
                    }
                    ColorRow(label: "Tint", color: b(\.tint), swatches: false)
                    NumberRow(label: "Vignette", value: b(\.vignette), range: 0...1, step: 0.01)
                }
            }
            FaceReport(cs: cs)
            InspectorSection(title: "Tips") {
                VStack(alignment: .leading, spacing: 6) {
                    tip("hand.draw", "Drag layers on the canvas; they snap to the centre and to each other (hold ⌘ to turn snapping off).")
                    tip("square.on.square.dashed", "Drag on an empty spot to select several layers; ⇧-click adds to the selection.")
                    tip("arrow.up.and.down.and.arrow.left.and.right", "Arrow keys nudge by 1 px, ⇧ arrows by 10 px. ⌫ deletes, ⌘D duplicates.")
                    tip("photo", "Drop an image file on the canvas to add it as a layer.")
                    tip("bolt.horizontal", "Live layers are redrawn by the watch and always sit above the artwork.")
                }
            }
        }
    }

    func tip(_ icon: String, _ s: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).frame(width: 16).foregroundStyle(.brand)
            Text(s).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    func choosePhoto() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.image]
        if p.runModal() == .OK, let u = p.url { cs.setPhoto(u) }
    }
}

struct FaceReport: View {
    @ObservedObject var cs: ComposerState
    var warnings: [String] {
        var w: [String] = []
        let screen = CGRect(x: 0, y: 0, width: FaceKit.W, height: FaceKit.H)
        for l in cs.doc.layers where l.visible && l.kind.isLive {
            let r = cs.bounds(l)
            if !screen.contains(r.insetBy(dx: 2, dy: 2)) { w.append("\(l.name) is partly off the screen.") }
        }
        if let b = cs.buildBytes, b > 420_000 { w.append("This face is large. Soft glows on big digits cost the most; reduce glow or digit size if the install fails.") }
        if !cs.doc.layers.contains(where: { ($0.kind == .time || $0.kind == .hands) && $0.visible }) { w.append("There is no visible time or hands layer.") }
        return w
    }
    var body: some View {
        InspectorSection(title: "Face") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    stat("Layers", "\(cs.doc.layers.count)")
                    stat("Elements", cs.buildBytes == nil ? "…" : "\(cs.buildElements)")
                    stat("Size", cs.buildBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "…")
                    stat("Install", cs.buildBytes.map { "~\(max(5, $0 / 11_500)) s" } ?? "…")
                }
                ForEach(warnings, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }
    func stat(_ t: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v).font(.system(size: 15, weight: .semibold, design: .rounded))
            Text(t).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
