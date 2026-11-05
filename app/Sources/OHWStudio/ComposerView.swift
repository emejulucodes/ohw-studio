import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Face Composer page

struct ComposerView: View {
    @EnvironmentObject var store: WatchStore
    @EnvironmentObject var cs: ComposerState
    @State private var showGallery = false
    @State private var installing: Double?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            ComposerToolbar(cs: cs, showGallery: $showGallery, installing: installing, install: install)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    LibraryPanel(cs: cs)
                    Divider()
                    LayersPanel(cs: cs)
                }
                .frame(width: 250)
                .background(.background.opacity(0.35))
                Divider()
                CanvasArea(cs: cs)
                Divider()
                InspectorPanel(cs: cs)
                    .frame(width: 318)
                    .background(.background.opacity(0.35))
            }
        }
        .background(BackdropView())
        .sheet(isPresented: $showGallery) { DesignGallery(cs: cs) }
        .alert("Install failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    func install() {
        guard installing == nil else { return }
        installing = 0
        Task {
            let b = await cs.makeBuild()
            do {
                try await store.install(b) { p in installing = p }
                UserDefaults.standard.set(cs.doc.id.uuidString, forKey: "installedDesign")
                store.show("\(cs.doc.name) is on your wrist", "sparkles")
            } catch {
                self.error = error.localizedDescription
            }
            installing = nil
        }
    }
}

// MARK: toolbar

struct ComposerToolbar: View {
    @EnvironmentObject var store: WatchStore
    @ObservedObject var cs: ComposerState
    @Binding var showGallery: Bool
    let installing: Double?
    let install: () -> Void
    @State private var showSample = false

    var body: some View {
        HStack(spacing: 10) {
            Button { showGallery = true } label: { Label("Designs", systemImage: "square.grid.2x2") }
                .help("Your designs and templates")
            Menu {
                ForEach(ComposerTemplates.all) { t in Button(t.title) { cs.newFrom(t) } }
                Divider()
                Button("Import .ohwface…") { importDesign() }
            } label: { Label("New", systemImage: "plus") }
            .fixedSize()
            Divider().frame(height: 18)
            TextField("Face name", text: Binding(get: { cs.doc.name }, set: { v in cs.mutate("name") { $0.name = v } }))
                .textFieldStyle(.plain).font(.system(size: 15, weight: .semibold)).frame(maxWidth: 220)
            Spacer()
            Group {
                Button { cs.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .keyboardShortcut("z", modifiers: .command).disabled(!cs.canUndo).help("Undo ⌘Z")
                Button { cs.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!cs.canRedo).help("Redo ⇧⌘Z")
                Button { cs.duplicateSelection() } label: { Image(systemName: "plus.square.on.square") }
                    .keyboardShortcut("d", modifiers: .command).disabled(cs.selection.isEmpty).help("Duplicate ⌘D")
            }
            Divider().frame(height: 18)
            Toggle(isOn: $cs.liveClock) { Label("Live", systemImage: "clock.badge.checkmark") }
                .toggleStyle(.button).help("Preview with the current time")
            Button { showSample.toggle() } label: { Label("Preview data", systemImage: "slider.horizontal.below.rectangle") }
                .popover(isPresented: $showSample, arrowEdge: .bottom) { SamplePopover(cs: cs) }
            Toggle(isOn: $cs.showGrid) { Image(systemName: "grid") }.toggleStyle(.button).help("Grid")
            Toggle(isOn: $cs.showSafeArea) { Image(systemName: "viewfinder") }.toggleStyle(.button).help("Screen corners")
            Divider().frame(height: 18)
            Menu {
                Button("Export preview PNG…") { exportPNG() }
                Button("Export design (.ohwface)…") { exportDesign() }
                Button("Export watch file (.bin)…") { exportBin() }
            } label: { Image(systemName: "square.and.arrow.up") }
            .fixedSize()
            if let p = installing {
                ProgressView(value: p).frame(width: 90).tint(.brand)
                Text("\(Int(p * 100))%").font(.system(size: 12, weight: .semibold).monospacedDigit()).frame(width: 34)
            } else {
                Button { install() } label: { Label("Install", systemImage: "applewatch.radiowaves.left.and.right") }
                    .buttonStyle(PrimaryButtonStyle(tint: .brand))
                    .disabled(!store.ready)
                    .help(store.ready ? "Send this face to the watch" : "Connect the watch to install")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .controlSize(.regular)
    }

    func exportPNG() {
        guard let img = cs.preview, let png = img.pngData() else { return }
        let p = NSSavePanel(); p.nameFieldStringValue = "\(cs.doc.name).png"; p.allowedContentTypes = [.png]
        if p.runModal() == .OK, let u = p.url { try? png.write(to: u) }
    }
    func exportDesign() {
        let p = NSSavePanel(); p.nameFieldStringValue = "\(cs.doc.name).ohwface"
        if p.runModal() == .OK, let u = p.url { cs.exportDesign(to: u) }
    }
    func exportBin() {
        let p = NSSavePanel(); p.nameFieldStringValue = "\(cs.doc.name).bin"
        guard p.runModal() == .OK, let u = p.url else { return }
        Task { let b = await cs.makeBuild(); try? Data(b.blob).write(to: u) }
    }
    func importDesign() {
        let p = NSOpenPanel(); p.allowedContentTypes = [UTType(filenameExtension: "ohwface") ?? .json, .json]
        if p.runModal() == .OK, let u = p.url { cs.importDesign(u) }
    }
}

struct SamplePopover: View {
    @ObservedObject var cs: ComposerState
    func b(_ kp: WritableKeyPath<Sample, Int>) -> Binding<Double> {
        Binding(get: { Double(cs.sample[keyPath: kp]) }, set: { cs.sample[keyPath: kp] = Int($0.rounded()) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Preview data").font(.headline)
            Text("Try long and short values to check your layout. The watch fills in the real numbers.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Use the current time", isOn: $cs.liveClock)
            if !cs.liveClock {
                NumberRow(label: "Hour", value: b(\.hour), range: 0...23)
                NumberRow(label: "Minute", value: b(\.minute), range: 0...59)
                NumberRow(label: "Second", value: b(\.second), range: 0...59)
                NumberRow(label: "Day", value: b(\.day), range: 1...31)
                NumberRow(label: "Month", value: b(\.month), range: 1...12)
                NumberRow(label: "Weekday", value: b(\.weekday), range: 0...6)
            }
            Divider()
            NumberRow(label: "Steps", value: b(\.steps), range: 0...99999)
            NumberRow(label: "Heart", value: b(\.heart), range: 30...220)
            NumberRow(label: "Calories", value: b(\.kcal), range: 0...9999)
            NumberRow(label: "Distance", value: $cs.sample.distance, range: 0...99, step: 0.1)
            NumberRow(label: "Battery", value: b(\.battery), range: 0...100)
            HStack {
                Button("Typical") { cs.sample = Sample.classic.with(cs.sample) }
                Button("Longest") { var s = cs.sample; s.steps = 88888; s.heart = 188; s.kcal = 8888; s.distance = 88.8; s.battery = 100; cs.sample = s }
                Button("Shortest") { var s = cs.sample; s.steps = 0; s.heart = 0; s.kcal = 0; s.distance = 0; s.battery = 5; cs.sample = s }
            }.controlSize(.small)
        }
        .padding(16).frame(width: 330)
    }
}

extension Sample {
    /// Typical data values, keeping the time fields of `t`.
    func with(_ t: Sample) -> Sample {
        var s = self; s.hour = t.hour; s.minute = t.minute; s.second = t.second; s.day = t.day; s.month = t.month; s.weekday = t.weekday
        return s
    }
}

// MARK: library

struct LibraryPanel: View {
    @ObservedObject var cs: ComposerState
    @State private var tab = 0
    let cols = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $tab) { Text("Live").tag(0); Text("Artwork").tag(1); Text("Widgets").tag(2) }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            ScrollView {
                LazyVGrid(columns: cols, spacing: 6) {
                    switch tab {
                    case 0:
                        ForEach([LayerKind.time, .hands, .date, .weekday, .month, .ampm, .steps, .heart, .calories, .distance, .battery, .seconds]) { k in
                            Tile(icon: k.icon, title: k.title, live: true, badge: k.experimental ? "β" : nil, enabled: cs.doc.canAdd(k)) { cs.add(k) }
                                .help(cs.doc.canAdd(k) ? "Add \(k.title)" : "\(k.title) is already on this face (the watch allows one)")
                        }
                    case 1:
                        Tile(icon: "textformat", title: "Text") { cs.add(.text) }
                        Tile(icon: "star.square.on.square.fill", title: "Symbol") { cs.add(.symbol) }
                        Tile(icon: "rectangle.roundedtop.fill", title: "Card") { cs.add(.shape) }
                        Tile(icon: "circle.fill", title: "Circle") { shape(.ellipse, 90, 90) }
                        Tile(icon: "capsule.fill", title: "Capsule") { shape(.capsule, 160, 54) }
                        Tile(icon: "star.fill", title: "Star") { shape(.star, 90, 90) }
                        Tile(icon: "circle.dashed", title: "Ring") { cs.add(.ring) }
                        Tile(icon: "circle.circle", title: "Dial") { cs.add(.dial) }
                        Tile(icon: "sun.max.fill", title: "Glow") { cs.add(.glow) }
                        Tile(icon: "rectangle.fill.on.rectangle.fill", title: "Glass") { glass() }
                        Tile(icon: "photo.fill", title: "Image") { pickImage { cs.addImage($0) } }
                        Tile(icon: "photo.on.rectangle.angled", title: "Photo BG") { pickImage { cs.setPhoto($0) } }
                    default:
                        ForEach(ComposerTemplates.widgets) { w in
                            Tile(icon: w.icon, title: w.title, live: !w.needs.isEmpty,
                                 enabled: w.needs.allSatisfy { cs.doc.canAdd($0) }) { cs.addWidget(w) }
                        }
                    }
                }
                .padding(.bottom, 4)
            }
            .frame(height: 196)
        }
        .padding(12)
    }

    func shape(_ k: ShapeKind, _ w: Double, _ h: Double) {
        var l = Layer.make(.shape); l.shape = k; l.w = w; l.h = h; l.fill = .solid(.orange); l.name = cs.uniqueName(k.title)
        cs.insert([l])
    }
    func glass() {
        var l = Layer.make(.shape); l.w = 300; l.h = 130; l.corner = 32; l.material = .glass; l.glassBlur = 18
        l.fill = .solid(RGBA(0xFFFFFF, 0.1)); l.stroke = Stroke(on: true, width: 1, color: RGBA(0xFFFFFF, 0.16)); l.name = cs.uniqueName("Glass")
        cs.insert([l])
    }
    func pickImage(_ f: (URL) -> Void) {
        let p = NSOpenPanel(); p.allowedContentTypes = [.image]
        if p.runModal() == .OK, let u = p.url { f(u) }
    }
}

struct Tile: View {
    let icon: String
    let title: String
    var live = false
    var badge: String? = nil
    var enabled = true
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(live ? Color.ok : Color.brand)
                Text(title).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity).frame(height: 54)
            .background(.white.opacity(hover ? 0.10 : 0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if let badge { Text(badge).font(.system(size: 9, weight: .bold)).foregroundStyle(.orange).padding(4) }
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled).opacity(enabled ? 1 : 0.35)
        .onHover { hover = $0 }
    }
}

// MARK: layers

struct LayersPanel: View {
    @ObservedObject var cs: ComposerState

    var live: [Layer] { cs.doc.layers.filter { $0.kind.isLive }.reversed() }
    var art: [Layer] { cs.doc.layers.filter { !$0.kind.isLive }.reversed() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("LAYERS").font(.system(size: 10.5, weight: .semibold)).kerning(0.7).foregroundStyle(.secondary)
                Spacer()
                Text("\(cs.doc.layers.count)").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
            List(selection: $cs.selection) {
                Section {
                    ForEach(live) { l in LayerRow(cs: cs, layer: l).tag(l.id) }
                        .onMove { from, to in move(live: true, from, to) }
                } header: { Label("Live · drawn by the watch", systemImage: "bolt.fill").font(.caption2) }
                Section {
                    ForEach(art) { l in LayerRow(cs: cs, layer: l).tag(l.id) }
                        .onMove { from, to in move(live: false, from, to) }
                } header: { Label("Artwork", systemImage: "paintbrush.pointed.fill").font(.caption2) }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .onDeleteCommand { cs.deleteSelection() }
        }
    }

    func move(live isLive: Bool, _ from: IndexSet, _ to: Int) {
        var shown = isLive ? live : art
        shown.move(fromOffsets: from, toOffset: to)
        let ordered = Array(shown.reversed())
        cs.mutate { d in
            let others = d.layers.filter { $0.kind.isLive != isLive }
            d.layers = isLive ? others + ordered : ordered + others
        }
    }
}

struct LayerRow: View {
    @ObservedObject var cs: ComposerState
    let layer: Layer
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: layer.kind == .shape ? layer.shape.symbol : layer.kind.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(layer.kind.isLive ? Color.ok : Color.brand)
                .frame(width: 18)
            Text(layer.name).font(.system(size: 12)).lineLimit(1)
                .foregroundStyle(layer.visible ? .primary : .tertiary)
            Spacer(minLength: 4)
            if layer.locked { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.secondary) }
            Button { cs.update(layer.id) { $0.visible.toggle() } } label: {
                Image(systemName: layer.visible ? "eye" : "eye.slash").font(.system(size: 10))
            }.buttonStyle(.borderless).foregroundStyle(.secondary)
        }
        .contextMenu {
            Button("Duplicate") { cs.selection = [layer.id]; cs.duplicateSelection() }.disabled(layer.kind.isLive)
            Button(layer.locked ? "Unlock" : "Lock") { cs.update(layer.id) { $0.locked.toggle() } }
            Button("Bring to front") { cs.moveToEdge(layer.id, front: true) }
            Button("Send to back") { cs.moveToEdge(layer.id, front: false) }
            Divider()
            Button("Delete", role: .destructive) { cs.selection = [layer.id]; cs.deleteSelection() }
        }
    }
}

// MARK: canvas

struct CanvasArea: View {
    @ObservedObject var cs: ComposerState
    var body: some View {
        GeometryReader { geo in
            let scale = max(0.4, min((geo.size.width - 120) / CGFloat(FaceKit.W), (geo.size.height - 70) / CGFloat(FaceKit.H)))
            ZStack {
                // watch case around the screen
                RoundedRectangle(cornerRadius: 96 * scale, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.30), Color(white: 0.09)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: CGFloat(FaceKit.W) * scale + 44 * scale, height: CGFloat(FaceKit.H) * scale + 44 * scale)
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
                RoundedRectangle(cornerRadius: 84 * scale, style: .continuous).fill(.black)
                    .frame(width: CGFloat(FaceKit.W) * scale + 22 * scale, height: CGFloat(FaceKit.H) * scale + 22 * scale)
                CanvasEditor(cs: cs, scale: scale)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(minWidth: 380)
    }
}

struct CanvasEditor: View {
    @ObservedObject var cs: ComposerState
    let scale: CGFloat
    @FocusState private var focused: Bool

    private struct DragState {
        var marquee = false
        var origin: CGPoint
        var starts: [UUID: CGPoint] = [:]
        var union: CGRect = .zero
        var xs: [CGFloat] = [], ys: [CGFloat] = []
        var moved = false
        var clickedID: UUID?
    }
    @State private var drag: DragState?
    @State private var marquee: CGRect?

    static let cornerRadius: CGFloat = 70    // OHW-11 panel corners, watch px

    var W: CGFloat { CGFloat(FaceKit.W) * scale }
    var H: CGFloat { CGFloat(FaceKit.H) * scale }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let p = cs.preview {
                    Image(decorative: p, scale: 1).resizable().interpolation(.high)
                } else { Color.black }
            }
            .frame(width: W, height: H)
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius * scale, style: .continuous))

            if cs.showGrid { GridOverlay(scale: scale).allowsHitTesting(false) }
            if cs.showSafeArea {
                RoundedRectangle(cornerRadius: Self.cornerRadius * scale, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .frame(width: W, height: H).allowsHitTesting(false)
            }
            ForEach(cs.selectedLayers) { l in
                SelectionBox(cs: cs, layer: l, scale: scale, handles: cs.selection.count == 1 && !l.locked)
            }
            guides.allowsHitTesting(false)
            if let m = marquee {
                Rectangle().fill(Color.brand.opacity(0.08))
                    .overlay(Rectangle().strokeBorder(Color.brand.opacity(0.8), lineWidth: 1))
                    .frame(width: m.width * scale, height: m.height * scale)
                    .offset(x: m.minX * scale, y: m.minY * scale)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: W, height: H, alignment: .topLeading)
        .coordinateSpace(name: "canvas")
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas")).onChanged(changed).onEnded(ended))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { k in
            let step: Double = k.modifiers.contains(.shift) ? 10 : 1
            switch k.key {
            case .leftArrow: cs.move(by: -step, 0)
            case .rightArrow: cs.move(by: step, 0)
            case .upArrow: cs.move(by: 0, -step)
            default: cs.move(by: 0, step)
            }
            return .handled
        }
        .onKeyPress(.escape) { cs.selection = []; return .handled }
        .onDeleteCommand { cs.deleteSelection() }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers, loc in
            let p = CGPoint(x: loc.x / scale, y: loc.y / scale)
            for pr in providers {
                _ = pr.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { cs.addImage(url, at: p) } }
                }
            }
            return true
        }
    }

    var guides: some View {
        ZStack(alignment: .topLeading) {
            ForEach(cs.guidesX, id: \.self) { x in
                Rectangle().fill(Color.pink).frame(width: 1, height: H).offset(x: x * scale)
            }
            ForEach(cs.guidesY, id: \.self) { y in
                Rectangle().fill(Color.pink).frame(width: W, height: 1).offset(y: y * scale)
            }
        }
    }

    func changed(_ v: DragGesture.Value) {
        let p = CGPoint(x: v.location.x / scale, y: v.location.y / scale)
        let flags = NSEvent.modifierFlags
        if drag == nil {
            focused = true
            let start = CGPoint(x: v.startLocation.x / scale, y: v.startLocation.y / scale)
            let hit = cs.engine.hit(cs.doc, start, sample: cs.currentSample)
            var st = DragState(origin: start)
            if let h = hit {
                if flags.contains(.shift) {
                    if cs.selection.contains(h.id) { cs.selection.remove(h.id) } else { cs.selection.insert(h.id) }
                } else if !cs.selection.contains(h.id) {
                    cs.selection = [h.id]
                } else {
                    st.clickedID = h.id
                }
                let moving = cs.selectedLayers.filter { !$0.locked }
                st.starts = Dictionary(uniqueKeysWithValues: moving.map { ($0.id, CGPoint(x: $0.x, y: $0.y)) })
                st.union = moving.map { cs.bounds($0) }.reduce(CGRect.null) { $0.union($1) }
                var xs: [CGFloat] = [0, CGFloat(FaceKit.W) / 2, CGFloat(FaceKit.W)], ys: [CGFloat] = [0, CGFloat(FaceKit.H) / 2, CGFloat(FaceKit.H)]
                for o in cs.doc.layers where o.visible && st.starts[o.id] == nil {
                    let r = cs.bounds(o)
                    xs += [r.minX, r.midX, r.maxX]; ys += [r.minY, r.midY, r.maxY]
                }
                st.xs = xs; st.ys = ys
                if !st.starts.isEmpty { cs.checkpoint() }
            } else {
                if !flags.contains(.shift) { cs.selection = [] }
                st.marquee = true
            }
            drag = st
        }
        guard var st = drag else { return }
        if st.marquee {
            let r = CGRect(x: min(st.origin.x, p.x), y: min(st.origin.y, p.y), width: abs(p.x - st.origin.x), height: abs(p.y - st.origin.y))
            marquee = r
            if r.width > 2 || r.height > 2 {
                cs.selection = Set(cs.doc.layers.filter { $0.visible && !$0.locked && cs.bounds($0).intersects(r) }.map(\.id))
            }
            return
        }
        guard !st.starts.isEmpty else { return }
        var dx = p.x - st.origin.x, dy = p.y - st.origin.y
        if abs(dx) + abs(dy) > 0.5 { st.moved = true }
        var gx: [CGFloat] = [], gy: [CGFloat] = []
        if !flags.contains(.command) {
            let thr: CGFloat = 5 / max(scale, 0.6)
            let r = st.union.offsetBy(dx: dx, dy: dy)
            if let s = snap([r.minX, r.midX, r.maxX], st.xs, thr) { dx += s.0; gx = [s.1] }
            if let s = snap([r.minY, r.midY, r.maxY], st.ys, thr) { dy += s.0; gy = [s.1] }
        }
        cs.guidesX = gx; cs.guidesY = gy
        let starts = st.starts
        let fx = dx.rounded(), fy = dy.rounded()
        cs.mutate(record: false) { d in
            for i in d.layers.indices { if let s = starts[d.layers[i].id] { d.layers[i].x = s.x + fx; d.layers[i].y = s.y + fy } }
        }
        drag = st
    }

    func snap(_ edges: [CGFloat], _ cands: [CGFloat], _ thr: CGFloat) -> (CGFloat, CGFloat)? {
        var best: (CGFloat, CGFloat)?
        for e in edges { for c in cands { let d = c - e; if abs(d) < thr && abs(d) < abs(best?.0 ?? .infinity) { best = (d, c) } } }
        return best
    }

    func ended(_ v: DragGesture.Value) {
        if let st = drag, !st.marquee, !st.moved, let id = st.clickedID, !NSEvent.modifierFlags.contains(.shift) {
            cs.selection = [id]
        }
        cs.endGesture()
        drag = nil; marquee = nil
        cs.guidesX = []; cs.guidesY = []
    }
}

struct GridOverlay: View {
    let scale: CGFloat
    var body: some View {
        SwiftUI.Canvas { ctx, size in
            var p = Path()
            stride(from: 0, through: CGFloat(FaceKit.W), by: 20.5).forEach { x in p.move(to: CGPoint(x: x * scale, y: 0)); p.addLine(to: CGPoint(x: x * scale, y: size.height)) }
            stride(from: 0, through: CGFloat(FaceKit.H), by: 25.1).forEach { y in p.move(to: CGPoint(x: 0, y: y * scale)); p.addLine(to: CGPoint(x: size.width, y: y * scale)) }
            ctx.stroke(p, with: .color(.white.opacity(0.07)), lineWidth: 0.5)
            var c = Path()
            c.move(to: CGPoint(x: size.width / 2, y: 0)); c.addLine(to: CGPoint(x: size.width / 2, y: size.height))
            c.move(to: CGPoint(x: 0, y: size.height / 2)); c.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            ctx.stroke(c, with: .color(.white.opacity(0.2)), lineWidth: 0.5)
        }
        .frame(width: CGFloat(FaceKit.W) * scale, height: CGFloat(FaceKit.H) * scale)
    }
}

/// Selection outline with resize and rotate handles.
struct SelectionBox: View {
    @ObservedObject var cs: ComposerState
    let layer: Layer
    let scale: CGFloat
    let handles: Bool
    @State private var start: Layer?

    var body: some View {
        let r = cs.bounds(layer)
        let w = max(6, r.width * scale), h = max(6, r.height * scale)
        let c = CGPoint(x: layer.x * scale, y: layer.y * scale)
        let rot = Angle.degrees(layer.kind.isLive ? 0 : layer.rotation)
        ZStack {
            Rectangle().strokeBorder(layer.kind.isLive ? Color.ok : Color.brand, lineWidth: 1.2)
                .frame(width: w + 6, height: h + 6)
                .allowsHitTesting(false)
            if handles {
                handle.position(x: (w + 6) / 2 + w / 2 + 3, y: (h + 6) / 2 + h / 2 + 3)
                    .gesture(resizeGesture(c: c, rot: rot.radians))
                    .help("Resize (⇧ keeps proportions)")
            }
            if handles && !layer.kind.isLive {
                VStack(spacing: 0) {
                    Circle().fill(Color.brand).frame(width: 10, height: 10)
                    Rectangle().fill(Color.brand).frame(width: 1, height: 14)
                }
                .position(x: (w + 6) / 2, y: -9)
                .gesture(rotateGesture(c: c))
                .help("Rotate (⇧ snaps to 15°)")
            }
            if layer.locked {
                Image(systemName: "lock.fill").font(.system(size: 10)).padding(3)
                    .background(.black.opacity(0.6), in: Circle()).position(x: w + 6, y: 0).allowsHitTesting(false)
            }
        }
        .frame(width: w + 6, height: h + 6)
        .rotationEffect(rot)
        .position(c)
    }

    var handle: some View {
        RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 10, height: 10)
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.brand, lineWidth: 1.5))
            .contentShape(Rectangle().inset(by: -6))
    }

    func resizeGesture(c: CGPoint, rot: Double) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
            .onChanged { v in
                if start == nil { start = layer; cs.checkpoint() }
                guard let s = start else { return }
                // pointer in the layer's unrotated frame, relative to its centre (watch px)
                let px = v.location.x / scale - s.x, py = v.location.y / scale - s.y
                let lx = px * cos(-rot) - py * sin(-rot), ly = px * sin(-rot) + py * cos(-rot)
                let r0 = cs.bounds(s)
                let sx = max(0.05, abs(lx) / max(1, r0.width / 2)), sy = max(0.05, abs(ly) / max(1, r0.height / 2))
                let keep = NSEvent.modifierFlags.contains(.shift)
                let k = max(sx, sy)
                cs.update(s.id, record: false) { l in
                    switch l.kind {
                    case .shape, .image, .glow, .dial:
                        l.w = max(2, (s.w * (keep ? k : sx)).rounded()); l.h = max(2, (s.h * (keep ? k : sy)).rounded())
                    case .ring:
                        l.w = max(8, (s.w * k).rounded()); l.h = l.w
                    case .hands:
                        let f = min(1.6, max(0.2, k))
                        l.hands.hourLength = min(148, s.hands.hourLength * f); l.hands.minuteLength = min(148, s.hands.minuteLength * f)
                        l.hands.secondLength = min(148, s.hands.secondLength * f)
                    default:
                        l.font.size = max(4, (s.font.size * sy).rounded())
                    }
                }
            }
            .onEnded { _ in start = nil; cs.endGesture() }
    }

    func rotateGesture(c: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
            .onChanged { v in
                if start == nil { start = layer; cs.checkpoint() }
                guard let s = start else { return }
                var a = atan2(v.location.y - c.y, v.location.x - c.x) * 180 / .pi + 90
                if a > 180 { a -= 360 }
                if NSEvent.modifierFlags.contains(.shift) { a = (a / 15).rounded() * 15 }
                cs.update(s.id, record: false) { $0.rotation = a.rounded() }
            }
            .onEnded { _ in start = nil; cs.endGesture() }
    }
}

// MARK: gallery

struct DesignGallery: View {
    @ObservedObject var cs: ComposerState
    @Environment(\.dismiss) private var dismiss
    @State private var thumbs: [String: NSImage] = [:]
    let cols = [GridItem(.adaptive(minimum: 132, maximum: 150), spacing: 16)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Designs").font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("Start from a template or pick up one of your faces. Everything saves automatically.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("TEMPLATES").font(.system(size: 11, weight: .semibold)).kerning(0.7).foregroundStyle(.secondary)
                    LazyVGrid(columns: cols, alignment: .leading, spacing: 16) {
                        ForEach(ComposerTemplates.all) { t in
                            GalleryCard(image: thumbs["t-\(t.id)"], title: t.title, subtitle: t.subtitle, current: false)
                                .onTapGesture { cs.newFrom(t); dismiss() }
                        }
                    }
                    Text("MY DESIGNS").font(.system(size: 11, weight: .semibold)).kerning(0.7).foregroundStyle(.secondary)
                    LazyVGrid(columns: cols, alignment: .leading, spacing: 16) {
                        ForEach(cs.designs) { d in
                            GalleryCard(image: thumbs[d.id.uuidString + "\(d.modified.timeIntervalSince1970)"], title: d.name,
                                        subtitle: d.modified.formatted(.relative(presentation: .named)), current: d.id == cs.doc.id)
                                .onTapGesture { cs.open(d); dismiss() }
                                .contextMenu {
                                    Button("Open") { cs.open(d); dismiss() }
                                    Button("Duplicate") { cs.duplicateDesign(d); render() }
                                    Divider()
                                    Button("Delete", role: .destructive) { cs.deleteDesign(d) }
                                }
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 760, height: 620)
        .task { render() }
    }

    func render() {
        var jobs: [(String, FaceDoc)] = ComposerTemplates.all.map { ("t-\($0.id)", $0.make()) }
        jobs += cs.designs.map { ($0.id.uuidString + "\($0.modified.timeIntervalSince1970)", $0) }
        for (k, d) in jobs where thumbs[k] == nil {
            Task {
                let img = await Task.detached(priority: .userInitiated) { ComposerEngine().preview(d, .classic) }.value
                thumbs[k] = img.nsImage
            }
        }
    }
}

struct GalleryCard: View {
    let image: NSImage?
    let title: String
    let subtitle: String
    let current: Bool
    @State private var hover = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if let image { Image(nsImage: image).resizable().interpolation(.high).aspectRatio(410.0 / 502, contentMode: .fit) }
                else { Color.black.overlay(ProgressView().controlSize(.small)) }
            }
            .frame(width: 132, height: 162)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(current ? Color.brand : .white.opacity(hover ? 0.3 : 0.08), lineWidth: current ? 3 : 1))
            .shadow(color: .black.opacity(hover ? 0.4 : 0.2), radius: hover ? 14 : 6, y: 4)
            .scaleEffect(hover ? 1.03 : 1)
            .animation(.spring(duration: 0.25), value: hover)
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(width: 140, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}
