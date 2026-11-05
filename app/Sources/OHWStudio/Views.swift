import SwiftUI
import Charts
import UniformTypeIdentifiers

enum Page: String, CaseIterable, Identifiable {
    case overview, health, faces, composer, alarms, worldClock, stocks, wellness, workout, assistant, contacts, internals, developer, remote, weather, messages, device, console
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "Today"; case .health: return "Health"; case .faces: return "Watch Faces"; case .composer: return "Face Composer"
        case .alarms: return "Alarms"; case .worldClock: return "World Clock"; case .stocks: return "Stocks"
        case .wellness: return "Wellness"; case .workout: return "Workout"; case .assistant: return "Assistant"; case .contacts: return "Contacts"; case .internals: return "Internals"; case .developer: return "Developer"
        case .remote: return "Remote"; case .weather: return "Weather"; case .messages: return "Messages"
        case .device: return "Device"; case .console: return "Console"
        }
    }
    var symbol: String {
        switch self {
        case .overview: return "applewatch"; case .health: return "heart.text.square.fill"; case .faces: return "paintpalette.fill"; case .composer: return "wand.and.stars"
        case .alarms: return "alarm.fill"; case .worldClock: return "globe"; case .stocks: return "chart.line.uptrend.xyaxis"
        case .wellness: return "leaf.fill"; case .workout: return "figure.run"; case .assistant: return "waveform.circle.fill"; case .contacts: return "person.crop.circle.fill"; case .internals: return "cpu"; case .developer: return "hammer.fill"
        case .remote: return "av.remote.fill"; case .weather: return "cloud.sun.fill"; case .messages: return "bubble.left.and.bubble.right.fill"
        case .device: return "slider.horizontal.3"; case .console: return "terminal.fill"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: WatchStore
    @State private var page: Page = .overview
    @State private var palette = false

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                Section("Watch") {
                    ForEach([Page.overview, .health, .composer, .faces]) { p in Label(p.title, systemImage: p.symbol).tag(p) }
                }
                Section("Life") {
                    ForEach([Page.assistant, .workout, .wellness, .alarms, .worldClock, .stocks]) { p in Label(p.title, systemImage: p.symbol).tag(p) }
                }
                Section("Connect") {
                    ForEach([Page.contacts, .remote, .weather, .messages]) { p in Label(p.title, systemImage: p.symbol).tag(p) }
                }
                Section("Advanced") {
                    ForEach([Page.device, .internals, .console, .developer]) { p in Label(p.title, systemImage: p.symbol).tag(p) }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .safeAreaInset(edge: .bottom) { SidebarFooter().padding(12) }
        } detail: {
            ZStack(alignment: .top) {
                if page == .composer {
                    ComposerView()
                } else {
                ScrollView {
                    Group {
                        switch page {
                        case .overview: TodayView(go: { page = $0 })
                        case .health: HealthView()
                        case .faces: FacesView()
                        case .composer: EmptyView()
                        case .alarms: AlarmsView()
                        case .worldClock: WorldClockView()
                        case .stocks: StocksView()
                        case .wellness: WellnessView()
                        case .internals: InternalsView()
                        case .developer: DeveloperView()
                        case .workout: WorkoutView()
                        case .assistant: AssistantView()
                        case .contacts: ContactsView()
                        case .remote: RemoteView()
                        case .weather: WeatherView()
                        case .messages: MessagesView()
                        case .device: DeviceView()
                        case .console: ConsoleView()
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: 1100)
                    .frame(maxWidth: .infinity)
                }
                .background(BackdropView())
                }
                if let t = store.toast {
                    ToastView(toast: t).padding(.top, 14).transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay(alignment: .top) {
                if palette {
                    ZStack(alignment: .top) {
                        Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { palette = false }
                        CommandPalette(page: $page, shown: $palette).padding(.top, 70)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.spring(duration: 0.35), value: store.toast)
            .animation(.easeOut(duration: 0.15), value: palette)
            .toolbar {
                ToolbarItem(placement: .navigation) { ConnectionPill(state: store.state, transfer: store.link.transferActive) }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { palette.toggle() } label: { Label("Command palette", systemImage: "command") }
                        .keyboardShortcut("k", modifiers: .command).help("Jump anywhere ⌘K")
                    if store.syncing { ProgressView().controlSize(.small) }
                    Button { Task { await store.refreshAll() } } label: { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
                        .disabled(!store.ready).help("Sync health data and settings")
                    Button { Task { await store.findWatch() } } label: { Label("Find watch", systemImage: "bell.and.waves.left.and.right") }
                        .disabled(!store.ready).help("Make the watch ring and vibrate")
                }
            }
        }
        .navigationTitle(page.title)
    }
}

struct BackdropView: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [Color.brand.opacity(0.10), .clear], center: .topTrailing, startRadius: 20, endRadius: 700)
            RadialGradient(colors: [Color.brand2.opacity(0.10), .clear], center: .bottomLeading, startRadius: 20, endRadius: 700)
        }
        .ignoresSafeArea()
    }
}

struct SidebarFooter: View {
    @EnvironmentObject var store: WatchStore
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "applewatch.side.right").font(.title2).foregroundStyle(.brand)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.link.deviceInfo?.name ?? "OHW-11").font(.system(size: 13, weight: .semibold))
                Text(store.battery.map { "\($0)% battery" } ?? store.state.label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Overview
struct OverviewView: View {
    @EnvironmentObject var store: WatchStore
    var go: (Page) -> Void

    var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "Good morning" : (h < 18 ? "Good afternoon" : "Good evening")
    }

    var body: some View {
        VStack(spacing: 22) {
            HStack(alignment: .center, spacing: 30) {
                WatchMockup(face: store.installedPreview, height: 300)
                VStack(alignment: .leading, spacing: 14) {
                    Text(greeting).font(.title3).foregroundStyle(.secondary)
                    Text(store.link.deviceInfo?.name ?? "OHW-11").font(.system(size: 44, weight: .bold, design: .rounded))
                    HStack(spacing: 8) {
                        ConnectionPill(state: store.state, transfer: store.link.transferActive)
                        if let r = store.link.rssi { Label("\(r) dBm", systemImage: "antenna.radiowaves.left.and.right").font(.caption).foregroundStyle(.secondary) }
                        if let d = store.lastSync { Text("Synced \(d.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary) }
                    }
                    HStack(spacing: 22) {
                        BatteryRing(level: store.battery)
                        VStack(alignment: .leading, spacing: 6) {
                            InfoRow(label: "Firmware", value: store.firmware.map { "v\($0)" } ?? "—")
                            InfoRow(label: "Platform", value: [store.link.deviceInfo?.platform, store.link.deviceInfo?.prototype].compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? "—")
                            InfoRow(label: "Address", value: store.mac ?? store.link.deviceInfo?.address ?? "—")
                        }
                    }
                    HStack(spacing: 10) {
                        Button { go(.faces) } label: { Label("New watch face", systemImage: "paintpalette.fill") }.buttonStyle(PrimaryButtonStyle())
                        Button { Task { await store.syncTime() } } label: { Label("Sync clock", systemImage: "clock") }.buttonStyle(GhostButtonStyle()).disabled(!store.ready)
                        Button { Task { await store.findWatch() } } label: { Label("Ring", systemImage: "bell.fill") }.buttonStyle(GhostButtonStyle()).disabled(!store.ready)
                    }
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            if store.state == .searching || store.state == .disconnected {
                Card {
                    HStack(spacing: 14) {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Looking for your watch…").font(.headline)
                            Text("Keep the watch nearby. If CO FIT on your iPhone is connected, turn the iPhone's Bluetooth off — the watch only talks to one app at a time.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 14) {
                StatTile(title: "Steps", value: store.todaySteps.formatted(), symbol: "figure.walk", tint: .ok)
                StatTile(title: "Heart", value: (store.liveHR ?? store.heartRates.last?.bpm).map(String.init) ?? "—", unit: "bpm", symbol: "heart.fill", tint: .heart)
                StatTile(title: "Energy", value: String(format: "%.0f", store.todayKcal), unit: "kcal", symbol: "flame.fill", tint: .brand)
                StatTile(title: "Distance", value: String(format: "%.2f", store.todayKm), unit: "km", symbol: "location.fill", tint: .sky)
            }
            HStack(alignment: .top, spacing: 14) {
                NowPlayingCard()
                WeatherMiniCard(go: go)
            }
        }
    }
}

struct InfoRow: View {
    let label: String, value: String
    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.callout).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(value).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
        }
    }
}

extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }

struct NowPlayingCard: View {
    @EnvironmentObject var store: WatchStore
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Now playing", systemImage: "music.note").font(.headline)
                    Spacer()
                    Toggle("Show on watch", isOn: $store.trackSync).toggleStyle(.switch).controlSize(.small)
                }
                if let np = store.media.now {
                    HStack(spacing: 14) {
                        RoundedRectangle(cornerRadius: 12).fill(LinearGradient(colors: [.brand, .brand2], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 58, height: 58)
                            .overlay(Image(systemName: np.playing ? "waveform" : "pause.fill").font(.title2).foregroundStyle(.white)
                                .symbolEffect(.variableColor.iterative, isActive: np.playing))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(np.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                            Text(np.artist).foregroundStyle(.secondary).lineLimit(1)
                            Text(np.player).font(.caption).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        HStack(spacing: 6) {
                            Button { Task { await store.media.control("previous") } } label: { Image(systemName: "backward.fill") }
                            Button { Task { await store.media.control("playpause") } } label: { Image(systemName: np.playing ? "pause.fill" : "play.fill") }
                            Button { Task { await store.media.control("next") } } label: { Image(systemName: "forward.fill") }
                        }
                        .buttonStyle(GhostButtonStyle())
                    }
                } else {
                    Text("Play something in Spotify or Music — it appears here and on your watch's music screen.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct WeatherMiniCard: View {
    @EnvironmentObject var store: WatchStore
    var go: (Page) -> Void
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Weather on watch", systemImage: "cloud.sun.fill").font(.headline)
                if let w = store.weather.now {
                    HStack(spacing: 14) {
                        Image(systemName: WeatherNow.symbol(w.code)).symbolRenderingMode(.multicolor).font(.system(size: 34))
                        VStack(alignment: .leading) {
                            Text("\(w.temp)°").font(.system(size: 30, weight: .semibold, design: .rounded))
                            Text("\(WeatherNow.describe(w.code)) · \(w.place)").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Button("Set your city") { go(.weather) }.buttonStyle(GhostButtonStyle())
                }
            }
        }
        .frame(maxWidth: 320)
    }
}

// MARK: - Health
struct HealthView: View {
    @EnvironmentObject var store: WatchStore
    @State private var beat = false

    var hourly: [(Date, Int)] {
        // records are cumulative per day → convert to per-bucket deltas for today
        let today = store.activity.filter { Calendar.current.isDateInToday($0.date) }
        var prev = 0
        return today.map { r in defer { prev = r.steps }; return (r.date, max(0, r.steps - prev)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionHeader(title: "Health", subtitle: "Synced straight from the watch's sensors.")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 14) {
                StatTile(title: "Steps today", value: store.todaySteps.formatted(), unit: store.settings.stepGoal.map { "/ \($0.formatted())" } ?? "", symbol: "figure.walk", tint: .ok)
                StatTile(title: "Energy", value: String(format: "%.0f", store.todayKcal), unit: "kcal", symbol: "flame.fill", tint: .brand)
                StatTile(title: "Distance", value: String(format: "%.2f", store.todayKm), unit: "km", symbol: "location.fill", tint: .sky)
            }
            Card {
                HStack(spacing: 18) {
                    Image(systemName: "heart.fill").font(.system(size: 44)).foregroundStyle(.heart)
                        .scaleEffect(store.liveHRRunning && beat ? 1.15 : 1)
                        .animation(store.liveHRRunning ? .easeInOut(duration: 0.42).repeatForever(autoreverses: true) : .default, value: beat)
                        .onAppear { beat = true }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Live heart rate").font(.headline)
                        Text(store.liveHRRunning ? "Measuring… keep the watch snug on your wrist." : "Start a measurement on the watch's sensor.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(store.liveHR.map { "\($0)" } ?? "––").font(.system(size: 48, weight: .bold, design: .rounded)).contentTransition(.numericText())
                    Text("bpm").foregroundStyle(.secondary)
                    Button(store.liveHRRunning ? "Stop" : "Measure") { Task { await store.toggleLiveHR() } }
                        .buttonStyle(PrimaryButtonStyle(tint: .heart)).disabled(!store.ready)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Activity today").font(.headline)
                    if hourly.isEmpty { EmptyHint(text: "No activity recorded yet today.") } else {
                        Chart(hourly, id: \.0) { item in
                            BarMark(x: .value("Time", item.0, unit: .minute), y: .value("Steps", item.1), width: .fixed(8))
                                .foregroundStyle(Color.ok.gradient).cornerRadius(3)
                        }
                        .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 3)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) } }
                        .frame(height: 180)
                    }
                }
            }
            HStack(alignment: .top, spacing: 14) {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Heart rate").font(.headline)
                        if store.heartRates.isEmpty { EmptyHint(text: "Wear the watch to collect heart-rate readings.") } else {
                            Chart(store.heartRates.suffix(200)) { s in
                                LineMark(x: .value("Time", s.date), y: .value("BPM", s.bpm)).interpolationMethod(.catmullRom)
                                    .foregroundStyle(Color.heart)
                                AreaMark(x: .value("Time", s.date), y: .value("BPM", s.bpm)).interpolationMethod(.catmullRom)
                                    .foregroundStyle(LinearGradient(colors: [.heart.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                            }
                            .chartYScale(domain: 40...180).frame(height: 170)
                        }
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Sleep").font(.headline)
                        if store.sleep.isEmpty { EmptyHint(text: "Sleep stages appear after a night with the watch on.") } else {
                            Chart(store.sleep) { s in
                                PointMark(x: .value("Time", s.date), y: .value("Stage", s.stage)).foregroundStyle(by: .value("Stage", s.stage))
                            }
                            .frame(height: 170)
                        }
                    }
                }
            }
            VitalsSection()
        }
    }
}

struct EmptyHint: View {
    let text: String
    var body: some View {
        HStack { Image(systemName: "sparkles").foregroundStyle(.tertiary); Text(text).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity, minHeight: 120)
    }
}

// MARK: - Faces
struct FacesView: View {
    @EnvironmentObject var store: WatchStore
    @State private var style: FaceStyle = .studio
    @State private var accent: Color = .brand
    @State private var photo: CGImage?
    @State private var photoName: String?
    @State private var focus: Double = 0.35
    @State private var build: FaceBuild?
    @State private var rendering = false
    @State private var progress: Double?
    @State private var error: String?
    @State private var dropHover = false
    @State private var thumbs: [FaceStyle: NSImage] = [:]

    var options: FaceOptions {
        FaceOptions(accent: NSColor(accent), photo: photo, photoFocus: focus)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionHeader(title: "Watch Face Studio", subtitle: "Design a face, preview it live, install it over Bluetooth.")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(FaceStyle.allCases) { s in
                        Button { style = s } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                ZStack {
                                    if let t = thumbs[s] { Image(nsImage: t).resizable().aspectRatio(410.0 / 502, contentMode: .fit) }
                                    else { Color.black }
                                }
                                .frame(width: 110, height: 135)
                                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(style == s ? accent : .white.opacity(0.08), lineWidth: style == s ? 3 : 1))
                                Text(s.title).font(.system(size: 13, weight: .semibold))
                                Text(s.tagline).font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(width: 120, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
            HStack(alignment: .top, spacing: 26) {
                VStack {
                    WatchMockup(face: build?.preview.nsImage, height: 380, glow: accent)
                        .overlay { if rendering { ProgressView().controlSize(.large) } }
                }
                VStack(alignment: .leading, spacing: 16) {
                    Card {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Customize").font(.headline)
                            HStack {
                                Text("Accent colour")
                                Spacer()
                                ForEach([Color.brand, .ok, .sky, .heart, .brand2, .pink, .yellow], id: \.self) { c in
                                    Circle().fill(c).frame(width: 20, height: 20)
                                        .overlay(Circle().strokeBorder(.white, lineWidth: accent == c ? 2 : 0))
                                        .onTapGesture { accent = c }
                                }
                                ColorPicker("", selection: $accent, supportsOpacity: false).labelsHidden()
                            }
                            if style == .portrait {
                                VStack(alignment: .leading, spacing: 8) {
                                    RoundedRectangle(cornerRadius: 14).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                                        .foregroundStyle(dropHover ? accent : .secondary)
                                        .frame(height: 86)
                                        .overlay {
                                            VStack(spacing: 4) {
                                                Image(systemName: "photo.badge.plus").font(.title2)
                                                Text(photoName ?? "Drop a photo here or click to choose").font(.callout)
                                            }.foregroundStyle(.secondary)
                                        }
                                        .contentShape(Rectangle())
                                        .onTapGesture { choosePhoto() }
                                        .onDrop(of: [.fileURL], isTargeted: $dropHover) { providers in
                                            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                                                if let url { DispatchQueue.main.async { loadPhoto(url) } }
                                            }
                                            return true
                                        }
                                    if photo != nil {
                                        HStack { Text("Crop"); Slider(value: $focus, in: 0...1) { Text("") } minimumValueLabel: { Image(systemName: "arrow.up") } maximumValueLabel: { Image(systemName: "arrow.down") } }
                                    }
                                }
                            }
                        }
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Install").font(.headline)
                            if let b = build {
                                Text("\(b.elements.count) layers · \(ByteCountFormatter.string(fromByteCount: Int64(b.blob.count), countStyle: .file)) · about \(max(5, b.blob.count / 11_500)) s over Bluetooth")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            if let p = progress {
                                ProgressView(value: p) { Text("Installing… \(Int(p * 100))%").font(.callout) }.tint(accent)
                            }
                            if let e = error { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout) }
                            HStack {
                                Button { install() } label: { Label("Install on watch", systemImage: "arrow.down.to.line.circle.fill") }
                                    .buttonStyle(PrimaryButtonStyle(tint: .brand))
                                    .disabled(build == nil || progress != nil || !store.ready)
                                Button { export() } label: { Label("Export PNG", systemImage: "square.and.arrow.up") }
                                    .buttonStyle(GhostButtonStyle()).disabled(build == nil)
                            }
                            if store.state != .ready { Text("Connect the watch to install.").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
        .task { renderThumbs() }
        .task(id: "\(style.rawValue)-\(accent.description)-\(photoName ?? "")-\(Int(focus * 100))") { await rerender() }
    }

    func rerender() async {
        rendering = true
        let o = options, s = style
        let b = await Task.detached(priority: .userInitiated) { s.build(o) }.value
        build = b
        rendering = false
    }

    func renderThumbs() {
        for s in FaceStyle.allCases where thumbs[s] == nil {
            Task {
                let o = FaceOptions(accent: NSColor(accent))
                let img = await Task.detached { s.build(o).preview }.value
                thumbs[s] = img.nsImage
            }
        }
    }

    func choosePhoto() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.image]; p.allowsMultipleSelection = false
        if p.runModal() == .OK, let u = p.url { loadPhoto(u) }
    }

    func loadPhoto(_ url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 1600]
        photo = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        photoName = url.lastPathComponent
    }

    func install() {
        guard let b = build else { return }
        error = nil; progress = 0
        Task {
            do {
                try await store.install(b) { p in progress = p }
                UserDefaults.standard.removeObject(forKey: "installedDesign")
                store.show("Face installed — enjoy!", "sparkles")
            } catch {
                self.error = error.localizedDescription
            }
            progress = nil
        }
    }

    func export() {
        guard let b = build, let png = b.preview.pngData() else { return }
        let p = NSSavePanel(); p.nameFieldStringValue = "\(style.title) face.png"; p.allowedContentTypes = [.png]
        if p.runModal() == .OK, let u = p.url { try? png.write(to: u) }
    }
}

// MARK: - Remote
struct RemoteView: View {
    @EnvironmentObject var store: WatchStore
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionHeader(title: "Remote", subtitle: "Turn the watch's music, camera and find-phone buttons into Mac controls.")
            Card {
                VStack(spacing: 0) {
                    ForEach(WatchTrigger.allCases) { t in
                        HStack(spacing: 14) {
                            Image(systemName: t.symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.brand)
                                .frame(width: 34, height: 34).background(Color.brand.opacity(0.13), in: RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.title).font(.system(size: 14, weight: .semibold))
                                Text("on the watch").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                            Picker("", selection: Binding(get: { store.mapping[t] ?? t.defaultAction }, set: { store.mapping[t] = $0 })) {
                                ForEach(RemoteAction.allCases) { a in Text(a.title).tag(a) }
                            }
                            .labelsHidden().frame(width: 210)
                            if store.mapping[t] == .shortcut {
                                TextField("Shortcut name", text: Binding(get: { store.shortcuts[t] ?? "" }, set: { store.shortcuts[t] = $0 }))
                                    .textFieldStyle(.roundedBorder).frame(width: 150)
                            }
                            Button { store.fire(t) } label: { Image(systemName: "play.circle") }.buttonStyle(.plain).help("Test this action")
                        }
                        .padding(.vertical, 10)
                        if t != WatchTrigger.allCases.last { Divider() }
                    }
                }
            }
            HStack(alignment: .top, spacing: 14) {
                NowPlayingCard()
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Live feed").font(.headline)
                        if store.remoteFeed.isEmpty { EmptyHint(text: "Press a button on the watch.") }
                        ForEach(Array(store.remoteFeed.prefix(8).enumerated()), id: \.offset) { _, e in
                            HStack(spacing: 10) {
                                Image(systemName: e.2).frame(width: 20).foregroundStyle(.brand)
                                Text(e.1).lineLimit(1)
                                Spacer()
                                Text(e.0.formatted(date: .omitted, time: .standard)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                    }
                }
            }
            Text("Music and slide actions use macOS Automation; approve the permission prompt the first time.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Weather
struct WeatherView: View {
    @EnvironmentObject var store: WatchStore
    @State private var city = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionHeader(title: "Weather", subtitle: "Live conditions and a 3-day forecast, delivered to the watch's weather screen.")
            Card {
                HStack {
                    Image(systemName: "mappin.and.ellipse").foregroundStyle(.brand)
                    TextField("City (e.g. Lagos)", text: $city).textFieldStyle(.plain).font(.title3)
                        .onSubmit { save() }
                    Button("Update") { save() }.buttonStyle(PrimaryButtonStyle())
                }
            }
            .onAppear { city = store.weather.city }
            if store.weather.loading { ProgressView() }
            if let e = store.weather.error { Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            if let w = store.weather.now {
                Card(padding: 24) {
                    HStack(spacing: 26) {
                        Image(systemName: WeatherNow.symbol(w.code)).symbolRenderingMode(.multicolor).font(.system(size: 70))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(w.place).font(.title3).foregroundStyle(.secondary)
                            Text("\(w.temp)°").font(.system(size: 64, weight: .thin, design: .rounded))
                            Text("\(WeatherNow.describe(w.code)) · H \(w.high)°  L \(w.low)°").foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .leading, spacing: 8) {
                            Label("\(w.humidity)% humidity", systemImage: "humidity.fill")
                            Label("\(w.wind) km/h wind", systemImage: "wind")
                            Label("UV \(w.uv)", systemImage: "sun.max.trianglebadge.exclamationmark")
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 14) {
                    ForEach(Array(w.days.enumerated()), id: \.offset) { i, d in
                        Card {
                            VStack(spacing: 8) {
                                Text(i == 0 ? "Today" : Calendar.current.date(byAdding: .day, value: i, to: Date())!.formatted(.dateTime.weekday(.wide)))
                                    .font(.headline)
                                Image(systemName: WeatherNow.symbol(d.code)).symbolRenderingMode(.multicolor).font(.system(size: 30))
                                Text("\(d.high)° / \(d.low)°").font(.title3.monospacedDigit())
                            }.frame(maxWidth: .infinity)
                        }
                    }
                }
                HStack {
                    Toggle("Keep the watch updated every 30 minutes", isOn: $store.weatherAuto)
                    Spacer()
                    Button { Task { await store.pushWeather(); store.show("Weather sent to watch", "cloud.sun.fill") } } label: {
                        Label("Send to watch now", systemImage: "arrow.up.forward.app")
                    }.buttonStyle(PrimaryButtonStyle()).disabled(!store.ready)
                }
            }
            Text("Weather data by Open-Meteo.com").font(.caption).foregroundStyle(.tertiary)
        }
    }
    func save() { store.weather.setCity(city); Task { await store.pushWeather(refresh: true) } }
}

// MARK: - Messages
struct MessagesView: View {
    @EnvironmentObject var store: WatchStore
    @State private var title = ""
    @State private var message = ""
    let templates: [(String, String, String)] = [
        ("Stand up", "Time to stretch your legs 🧘", "figure.stand"), ("Water", "Have a glass of water 💧", "drop.fill"),
        ("Meeting", "Meeting starts in 5 minutes", "calendar"), ("Focus", "Deep-work block: phone away", "brain.head.profile")]
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionHeader(title: "Messages", subtitle: "Send notifications to your wrist from the Mac.")
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Title", text: $title).textFieldStyle(.roundedBorder).font(.title3)
                    TextEditor(text: $message).font(.body).frame(height: 90).scrollContentBackground(.hidden)
                        .padding(8).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    HStack {
                        Text("\(message.utf8.count)/250").font(.caption.monospacedDigit()).foregroundStyle(message.utf8.count > 250 ? .red : .secondary)
                        Spacer()
                        Button { Task { await store.sendNotification(title: "", body: "", call: true) } } label: { Label("Ring watch", systemImage: "phone.arrow.down.left.fill") }
                            .buttonStyle(GhostButtonStyle()).disabled(!store.ready)
                        Button { Task { await store.sendNotification(title: title.isEmpty ? "Mac" : title, body: message); message = "" } } label: {
                            Label("Send", systemImage: "paperplane.fill")
                        }
                        .buttonStyle(PrimaryButtonStyle()).disabled(!store.ready || (title.isEmpty && message.isEmpty))
                        .keyboardShortcut(.return, modifiers: .command)
                    }
                }
            }
            Text("Quick reminders").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 14) {
                ForEach(templates, id: \.0) { t in
                    Button { Task { await store.sendNotification(title: t.0, body: t.1) } } label: {
                        Card {
                            VStack(alignment: .leading, spacing: 8) {
                                Image(systemName: t.2).font(.title2).foregroundStyle(.brand)
                                Text(t.0).font(.headline)
                                Text(t.1).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                    .buttonStyle(.plain).disabled(!store.ready)
                }
            }
        }
    }
}

// MARK: - Device
struct DeviceView: View {
    @EnvironmentObject var store: WatchStore
    @State private var backlight: Double = 5
    @State private var brightness: Double = 6
    @State private var goal: Double = 8000

    let featureLabels: [(String, String, String)] = [
        ("RequestRealtimeWeather", "Weather", "cloud.sun"), ("WorldClock", "World clock", "globe"), ("Stock", "Stocks", "chart.line.uptrend.xyaxis"),
        ("NoDisturb", "Do not disturb", "moon.fill"), ("AppSport", "Workouts", "figure.run"), ("2DAcceleration", "Custom faces", "paintpalette"),
        ("BatteryUsage", "Battery stats", "battery.75"), ("SOS2", "SOS", "sos"), ("TemperatureUnit", "°C / °F", "thermometer"),
        ("DateFormat", "Date format", "calendar"), ("MusicTransfer", "Music files", "music.note.list"), ("CustomLogo", "Boot logo", "seal"),
        ("AppStore", "App store", "square.grid.3x3"), ("Watchface2", "Faces v2", "rectangle.stack")]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionHeader(title: "Device", subtitle: "Watch settings and what this firmware supports.")
            Card {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Display").font(.headline)
                    SettingSlider(label: "Screen timeout", symbol: "timer", value: $backlight, range: 3...30, unit: "s") { Task { await store.setBacklight(Int(backlight)) } }
                    SettingSlider(label: "Brightness", symbol: "sun.max.fill", value: $brightness, range: 1...10, unit: "") { Task { await store.setBrightness(Int(brightness)) } }
                    Divider()
                    Text("Goals").font(.headline)
                    SettingSlider(label: "Daily steps", symbol: "figure.walk", value: $goal, range: 1000...30000, step: 500, unit: "") { Task { await store.setStepGoal(Int(goal)) } }
                    Divider()
                    HStack {
                        Label("Watch clock", systemImage: "clock")
                        Spacer()
                        Button("Sync to this Mac") { Task { await store.syncTime() } }.buttonStyle(GhostButtonStyle())
                    }
                }
                .disabled(!store.ready)
            }
            .onReceive(store.$settings) { s in
                if let v = s.backlight { backlight = Double(v) }
                if let v = s.brightness { brightness = Double(v) }
                if let v = s.stepGoal { goal = Double(v) }
            }
            if let info = store.link.deviceInfo {
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Firmware features").font(.headline)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                            ForEach(featureLabels, id: \.0) { f in
                                let on = info.has(f.0)
                                HStack(spacing: 8) {
                                    Image(systemName: f.2).frame(width: 18)
                                    Text(f.1).lineLimit(1)
                                    Spacer()
                                    Image(systemName: on ? "checkmark.circle.fill" : "minus.circle").foregroundStyle(on ? Color.ok : Color.secondary)
                                }
                                .font(.callout)
                                .padding(10).background(.quaternary.opacity(on ? 0.5 : 0.2), in: RoundedRectangle(cornerRadius: 10))
                                .opacity(on ? 1 : 0.6)
                            }
                        }
                        Divider()
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                            GridRow { Text("Model").foregroundStyle(.secondary); Text(info.firmwareFlag).font(.callout.monospaced()) }
                            GridRow { Text("Platform").foregroundStyle(.secondary); Text("\(info.platform) · \(info.prototype) · face type \(info.watchFaceType)").font(.callout.monospaced()) }
                            GridRow { Text("Transfer buffer").foregroundStyle(.secondary); Text("\(info.ioBuffer) bytes").font(.callout.monospaced()) }
                        }
                    }
                }
            }
        }
    }
}

struct SettingSlider: View {
    let label: String, symbol: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    let unit: String
    let commit: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            Label(label, systemImage: symbol).frame(width: 170, alignment: .leading)
            Slider(value: $value, in: range, step: step) { editing in if !editing { commit() } }
            Text("\(Int(value).formatted())\(unit)").font(.callout.monospacedDigit()).frame(width: 70, alignment: .trailing)
        }
    }
}

// MARK: - Console
struct ConsoleView: View {
    @EnvironmentObject var store: WatchStore
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Console", subtitle: "Every frame on the SMA protocol, live.")
            Card(padding: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(store.log) { l in
                                HStack(alignment: .top, spacing: 10) {
                                    Text(l.date.formatted(.dateTime.hour().minute().second())).foregroundStyle(.tertiary)
                                    Image(systemName: l.outgoing ? "arrow.up.right" : "arrow.down.left").foregroundStyle(l.outgoing ? Color.brand : Color.sky)
                                    Text(l.text).textSelection(.enabled)
                                }
                                .font(.system(size: 11.5, design: .monospaced))
                                .id(l.id)
                            }
                        }
                        .padding(14)
                    }
                    .frame(height: 520)
                    .onChange(of: store.log.count) { if let last = store.log.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                    .onAppear { if let last = store.log.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
        }
    }
}

// MARK: - Menu bar
struct MenuBarView: View {
    @EnvironmentObject var store: WatchStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                BatteryRing(level: store.battery, size: 54)
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.link.deviceInfo?.name ?? "OHW-11").font(.headline)
                    ConnectionPill(state: store.state, transfer: store.link.transferActive)
                }
            }
            HStack(spacing: 16) {
                Label(store.todaySteps.formatted(), systemImage: "figure.walk").foregroundStyle(.ok)
                Label((store.liveHR ?? store.heartRates.last?.bpm).map { "\($0)" } ?? "–", systemImage: "heart.fill").foregroundStyle(.heart)
            }
            .font(.callout.weight(.semibold))
            if let np = store.media.now {
                Divider()
                HStack {
                    Image(systemName: "music.note")
                    Text("\(np.title) — \(np.artist)").lineLimit(1).font(.callout)
                }
            }
            Divider()
            HStack {
                Button { Task { await store.findWatch() } } label: { Label("Ring", systemImage: "bell.fill") }
                Button { Task { await store.syncTime() } } label: { Label("Clock", systemImage: "clock") }
                Button { Task { await store.refreshAll() } } label: { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
            }
            .buttonStyle(GhostButtonStyle()).disabled(!store.ready)
            HStack {
                Button("Open OHW Studio") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .font(.callout)
        }
        .padding(16)
        .frame(width: 300)
    }
}
