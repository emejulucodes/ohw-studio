import SwiftUI
import Charts

// MARK: - Today (redesigned overview)

struct TodayView: View {
    @EnvironmentObject var store: WatchStore
    @EnvironmentObject var ex: ExtrasStore
    @EnvironmentObject var composer: ComposerState
    @EnvironmentObject var workout: WorkoutStore
    var go: (Page) -> Void

    var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 5 ? "Good night" : h < 12 ? "Good morning" : (h < 18 ? "Good afternoon" : "Good evening")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 28) {
                LiveWatchMirror()
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(greeting).").font(.title3).foregroundStyle(.secondary)
                    Text(store.link.deviceInfo?.name ?? "OHW-11").font(.system(size: 46, weight: .bold, design: .rounded))
                    HStack(spacing: 8) {
                        ConnectionPill(state: store.state, transfer: store.link.transferActive)
                        if let b = store.battery { Label("\(b)%", systemImage: b > 20 ? "battery.75percent" : "battery.25percent").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                        if let d = store.lastSync { Text("Synced \(d.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary) }
                    }
                    Text(summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 360, alignment: .leading)
                    HStack(spacing: 8) {
                        Button { go(.composer) } label: { Label("Design a face", systemImage: "wand.and.stars") }.buttonStyle(PrimaryButtonStyle())
                        Button { go(.workout) } label: { Label("Workout", systemImage: "figure.run") }.buttonStyle(GhostButtonStyle())
                        Button { Task { await store.findWatch() } } label: { Label("Ring", systemImage: "bell.fill") }.buttonStyle(GhostButtonStyle()).disabled(!store.ready)
                    }
                }
                Spacer(minLength: 0)
                ActivityRings(steps: Double(store.todaySteps), stepGoal: Double(store.settings.stepGoal ?? 8000),
                              kcal: store.todayKcal, kcalGoal: Double(ex.calorieGoal ?? 300),
                              km: store.todayKm, kmGoal: ex.distanceGoal ?? 5)
            }
            if store.state == .searching || store.state == .disconnected {
                Card {
                    HStack(spacing: 14) {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Looking for your watch…").font(.headline)
                            Text("Keep it nearby. If CO FIT on your iPhone is connected, turn the iPhone's Bluetooth off — the watch talks to one app at a time.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 14) {
                HeartTile(go: go)
                BatteryHealthTile()
                NextAlarmTile(go: go)
                WorkoutTile(go: go)
            }
            HStack(alignment: .top, spacing: 14) {
                WorldStrip(go: go)
                TickerStrip(go: go)
            }
            HStack(alignment: .top, spacing: 14) {
                NowPlayingCard()
                WeatherMiniCard(go: go)
            }
        }
        .task(id: store.ready) {
            if store.ready {
                if ex.battery == nil { await ex.loadBattery() }
                if !ex.alarmsLoaded { await ex.loadAlarms() }
                if ex.calorieGoal == nil { await ex.loadSettings() }
            }
        }
    }

    var summary: String {
        let pct = Int(Double(store.todaySteps) / Double(max(1, store.settings.stepGoal ?? 8000)) * 100)
        var s = "\(store.todaySteps.formatted()) steps today — \(pct)% of your goal."
        if let a = nextAlarm(ex.alarms) { s += " Next alarm \(a)." }
        if workout.phase != .idle { s += " Workout in progress." }
        return s
    }
}

func nextAlarm(_ alarms: [WatchAlarm]) -> String? {
    let cal = Calendar.current, now = Date()
    var best: Date?
    for a in alarms where a.enabled {
        for d in 0..<8 {
            guard let day = cal.date(byAdding: .day, value: d, to: now),
                  let t = cal.date(bySettingHour: a.hour, minute: a.minute, second: 0, of: day), t > now else { continue }
            let wd = (cal.component(.weekday, from: t) + 5) % 7   // Mon = 0
            if a.repeatDays.isEmpty || a.repeatDays.contains(Weekdays(rawValue: 1 << wd)) { if best == nil || t < best! { best = t }; break }
        }
    }
    guard let b = best else { return nil }
    return cal.isDateInToday(b) ? "at \(b.formatted(date: .omitted, time: .shortened))"
        : "\(b.formatted(.dateTime.weekday(.wide))) \(b.formatted(date: .omitted, time: .shortened))"
}

/// The installed Composer face, rendered live with the real time and today's numbers.
struct LiveWatchMirror: View {
    @EnvironmentObject var store: WatchStore
    @EnvironmentObject var composer: ComposerState
    var body: some View {
        let id = UserDefaults.standard.string(forKey: "installedDesign")
        let doc = composer.designs.first { $0.id.uuidString == id }
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            ZStack(alignment: .bottom) {
                if let doc {
                    WatchMockup(face: composer.engine.preview(doc, sample(ctx.date)).nsImage, height: 300)
                } else {
                    WatchMockup(face: store.installedPreview, height: 300)
                }
                if doc != nil {
                    Label("LIVE", systemImage: "dot.radiowaves.left.and.right").font(.system(size: 9.5, weight: .heavy))
                        .padding(.horizontal, 8).padding(.vertical, 3).background(.ok.opacity(0.85), in: Capsule()).foregroundStyle(.white)
                        .offset(y: 8)
                }
            }
        }
        .help("A live mirror of the face on your watch")
    }
    func sample(_ d: Date) -> Sample {
        var s = Sample.classic.at(d)
        s.steps = store.todaySteps
        s.heart = store.liveHR ?? store.heartRates.last?.bpm ?? 0
        s.kcal = Int(store.todayKcal); s.distance = store.todayKm
        s.battery = store.battery ?? 0
        return s
    }
}

struct ActivityRings: View {
    let steps: Double, stepGoal: Double, kcal: Double, kcalGoal: Double, km: Double, kmGoal: Double
    @State private var appear = false
    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                ring(kcal / max(1, kcalGoal), .heart, 150, 16)
                ring(steps / max(1, stepGoal), .ok, 112, 16)
                ring(km / max(0.1, kmGoal), .sky, 74, 16)
            }
            .frame(width: 160, height: 160)
            VStack(alignment: .leading, spacing: 10) {
                legend(.heart, "Move", "\(Int(kcal))/\(Int(kcalGoal)) kcal")
                legend(.ok, "Steps", "\(Int(steps).formatted())/\(Int(stepGoal).formatted())")
                legend(.sky, "Distance", String(format: "%.1f/%.0f km", km, kmGoal))
            }
        }
        .onAppear { withAnimation(.spring(duration: 1.2).delay(0.1)) { appear = true } }
    }
    func ring(_ p: Double, _ c: Color, _ d: CGFloat, _ w: CGFloat) -> some View {
        ZStack {
            Circle().stroke(c.opacity(0.18), lineWidth: w)
            Circle().trim(from: 0, to: appear ? min(1, max(0.005, p)) : 0)
                .stroke(AngularGradient(colors: [c.opacity(0.75), c], center: .center), style: StrokeStyle(lineWidth: w, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: c.opacity(0.5), radius: 4)
        }
        .frame(width: d, height: d)
    }
    func legend(_ c: Color, _ t: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(t.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(c).kerning(0.6)
            Text(v).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
        }
    }
}

struct TodayTile<Content: View>: View {
    let title: String, icon: String, tint: Color
    var action: (() -> Void)? = nil
    @ViewBuilder var content: Content
    @State private var hover = false
    var body: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
                        .frame(width: 28, height: 28).background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).kerning(0.6)
                    Spacer()
                    if action != nil { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).opacity(hover ? 1 : 0.4) }
                }
                content
            }
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        }
        .contentShape(Rectangle())
        .onTapGesture { action?() }
        .onHover { hover = $0 }
        .scaleEffect(hover && action != nil ? 1.015 : 1).animation(.spring(duration: 0.25), value: hover)
    }
}

struct HeartTile: View {
    @EnvironmentObject var store: WatchStore
    var go: (Page) -> Void
    var body: some View {
        TodayTile(title: "Heart", icon: "heart.fill", tint: .heart, action: { go(.health) }) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text((store.liveHR ?? store.heartRates.last?.bpm).map(String.init) ?? "—")
                    .font(.system(size: 30, weight: .semibold, design: .rounded)).contentTransition(.numericText())
                Text("bpm").foregroundStyle(.secondary)
            }
            if store.heartRates.count > 2 {
                Chart(store.heartRates.suffix(40)) { LineMark(x: .value("t", $0.date), y: .value("b", $0.bpm)).interpolationMethod(.catmullRom).foregroundStyle(Color.heart) }
                    .chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 26)
            } else {
                Text(store.liveHRRunning ? "Measuring…" : "Wear the watch for readings").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct BatteryHealthTile: View {
    @EnvironmentObject var store: WatchStore
    @EnvironmentObject var ex: ExtrasStore
    @State private var showDetail = false
    var body: some View {
        TodayTile(title: "Battery", icon: "battery.100percent.bolt", tint: .ok, action: { showDetail = true }) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(store.battery.map(String.init) ?? "—").font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("%").foregroundStyle(.secondary)
                Spacer()
                if let v = ex.battery?.latest?.volts, v > 0 { Text(String(format: "%.2f V", v)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            if let b = ex.battery {
                Text("Screen on \(Int(b.screenShare * 100))% of the time · tap for details").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
            } else { Text("Tap for battery details").font(.caption).foregroundStyle(.secondary) }
        }
        .sheet(isPresented: $showDetail) { BatteryDetailSheet() }
    }
}

struct BatteryDetailSheet: View {
    @EnvironmentObject var store: WatchStore
    @EnvironmentObject var ex: ExtrasStore
    @Environment(\.dismiss) private var dismiss
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 18) {
                BatteryRing(level: store.battery, size: 110)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Battery").font(.system(size: 26, weight: .bold, design: .rounded))
                    if let v = ex.battery?.latest?.volts, v > 0 {
                        Text(String(format: "%.2f V · %@", v, health(v))).foregroundStyle(.secondary)
                    }
                    if let b = ex.battery { Text("\(BatteryUsage.hm(b.total)) of tracked use").foregroundStyle(.secondary) }
                }
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button { refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(!store.ready || loading)
            }
            if let b = ex.battery {
                VStack(alignment: .leading, spacing: 10) {
                    Text("WHERE THE TIME WENT").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).kerning(0.6)
                    usageBar(b)
                    row("sun.max.fill", .orange, "Screen on", b.screen, b.total)
                    row("moon.zzz.fill", .indigo, "Idle (screen off)", b.idle, b.total)
                    row("figure.run", .sky, "Workouts", b.sport, b.total)
                    row("phone.fill", .ok, "Calls", b.talk, b.total)
                    row("speaker.wave.2.fill", .brand2, "Speaker", b.speaker, b.total)
                    row("iphone.radiowaves.left.and.right", .heart, "Vibration", b.vibration, b.total)
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("VOLTAGE LOG").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).kerning(0.6)
                    rec("power", "Last boot", b.lastBoot)
                    rec("power.dotted", "Last shutdown", b.lastShutdown)
                    rec("bolt.fill", "Latest reading", b.latest)
                }
                if b.total > 0 {
                    let perDay = Double(b.screen) / Double(b.total) * 24
                    Label(String(format: "Your screen is on about %.1f h a day. A shorter screen timeout (Device page) or turning off raise-to-wake (Wellness) saves the most battery.", perDay),
                          systemImage: "lightbulb.fill")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(store.ready ? "Reading battery stats from the watch…" : "Connect the watch to read its battery stats.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24)
        .frame(width: 520)
        .task { refresh() }
    }

    func refresh() {
        guard store.ready, !loading else { return }
        loading = true
        Task { await store.refreshQuick(); await ex.loadBattery(); loading = false }
    }

    func health(_ v: Double) -> String { v >= 4.1 ? "fully charged" : v >= 3.8 ? "healthy" : v >= 3.6 ? "getting low" : "charge soon" }

    func usageBar(_ b: BatteryUsage) -> some View {
        let parts: [(Int, Color)] = [(b.screen, .orange), (b.sport, .sky), (b.talk, .ok), (b.speaker, .brand2), (b.vibration, .heart), (b.idle, .indigo)]
        let sum = max(1, parts.map(\.0).reduce(0, +))
        return GeometryReader { g in
            HStack(spacing: 2) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                    if p.0 > 0 { RoundedRectangle(cornerRadius: 3).fill(p.1.gradient).frame(width: max(3, g.size.width * CGFloat(p.0) / CGFloat(sum))) }
                }
            }
        }
        .frame(height: 14)
    }

    func row(_ icon: String, _ c: Color, _ t: String, _ s: Int, _ total: Int) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(c).frame(width: 22)
            Text(t)
            Spacer()
            Text(BatteryUsage.hm(s)).monospacedDigit()
            Text(total > 0 ? String(format: "%.0f%%", Double(s) / Double(total) * 100) : "—").monospacedDigit()
                .foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
        }.font(.callout)
    }

    func rec(_ icon: String, _ t: String, _ r: BatteryUsage.Record?) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 22)
            Text(t)
            Spacer()
            Text(r?.date?.formatted(date: .abbreviated, time: .shortened) ?? "—").foregroundStyle(.secondary)
            Text(r.map { String(format: "%.2f V", $0.volts) } ?? "—").monospacedDigit().frame(width: 64, alignment: .trailing)
        }.font(.callout)
    }
}

struct NextAlarmTile: View {
    @EnvironmentObject var ex: ExtrasStore
    var go: (Page) -> Void
    var body: some View {
        TodayTile(title: "Next alarm", icon: "alarm.fill", tint: .brand, action: { go(.alarms) }) {
            if let n = nextAlarm(ex.alarms) {
                Text(n.replacingOccurrences(of: "at ", with: "")).font(.system(size: 24, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
                Text("\(ex.alarms.filter(\.enabled).count) active").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("None").font(.system(size: 28, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                Text("Set a vibrating alarm").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct WorkoutTile: View {
    @EnvironmentObject var workout: WorkoutStore
    var go: (Page) -> Void
    var body: some View {
        TodayTile(title: "Workout", icon: "figure.run", tint: .sky, action: { go(.workout) }) {
            if workout.phase != .idle {
                Text(WorkoutStore.clock(workout.elapsed)).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(String(format: "%.2f km · %@", workout.meters / 1000, workout.mode.title)).font(.caption).foregroundStyle(.secondary)
            } else if let last = workout.history.first {
                Text(String(format: "%.2f km", last.meters / 1000)).font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("Last: \(SportMode(rawValue: last.mode)?.title ?? "Workout"), \(last.start.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("Start").font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("Run the watch's sport screen from your Mac").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

struct WorldStrip: View {
    @EnvironmentObject var ex: ExtrasStore
    var go: (Page) -> Void
    var body: some View {
        Card(padding: 14) {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                HStack(spacing: 18) {
                    Image(systemName: "globe").foregroundStyle(.sky)
                    ForEach(ex.cities.prefix(4)) { c in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(c.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Text(time(c.tz, ctx.date)).font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .onTapGesture { go(.worldClock) }
    }
    func time(_ tz: String, _ d: Date) -> String { let f = DateFormatter(); f.timeZone = TimeZone(identifier: tz); f.dateFormat = "HH:mm"; return f.string(from: d) }
}

struct TickerStrip: View {
    @EnvironmentObject var ex: ExtrasStore
    var go: (Page) -> Void
    var body: some View {
        Card(padding: 14) {
            HStack(spacing: 16) {
                Image(systemName: "chart.line.uptrend.xyaxis").foregroundStyle(.ok)
                ForEach(ex.stocks.prefix(4)) { s in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(s.symbol.replacingOccurrences(of: "-USD", with: "")).font(.caption.weight(.semibold))
                        Text(s.updated == nil ? "—" : String(format: "%@%.1f%%", s.change >= 0 ? "▲" : "▼", abs(s.percent)))
                            .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(s.updated == nil ? Color.secondary : (s.change >= 0) == ex.greenUp ? Color.ok : Color.heart)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .onTapGesture { go(.stocks) }
    }
}

// MARK: - extra vitals on the Health page

struct VitalsSection: View {
    @EnvironmentObject var store: WatchStore
    @EnvironmentObject var ex: ExtrasStore
    @State private var loaded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                vital("Blood oxygen", "lungs.fill", .sky, ex.spo2History, unit: "%", range: 80...100)
                vital("Stress", "brain.head.profile", .brand2, ex.stressHistory, unit: "", range: 0...100)
                vital("Blood pressure", "waveform.path.ecg", .heart, ex.bpHistory, unit: "mmHg", range: 50...180)
            }
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Workouts recorded on the watch").font(.headline)
                    if ex.watchWorkouts.isEmpty {
                        EmptyHint(text: loaded ? "No workouts stored on the watch yet." : "Loading…")
                    }
                    ForEach(ex.watchWorkouts) { w in
                        HStack {
                            Image(systemName: SportMode(rawValue: w.mode)?.icon ?? "figure.mixed.cardio").foregroundStyle(.sky).frame(width: 24)
                            Text(w.start.formatted(date: .abbreviated, time: .shortened))
                            Spacer()
                            Text(WorkoutStore.clock(w.seconds)).monospacedDigit()
                            Text(String(format: "%.2f km", w.meters / 1000)).monospacedDigit().frame(width: 80, alignment: .trailing)
                            Text("\(Int(w.kcal)) kcal").monospacedDigit().frame(width: 80, alignment: .trailing)
                            Text(w.avgHR > 0 ? "\(w.avgHR) bpm" : "—").monospacedDigit().frame(width: 70, alignment: .trailing)
                        }.font(.callout)
                    }
                }
            }
        }
        .task(id: store.ready) { if store.ready && !loaded { await ex.loadVitals(); loaded = true } }
    }

    func vital(_ t: String, _ icon: String, _ c: Color, _ data: [VitalSample], unit: String, range: ClosedRange<Int>) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label(t, systemImage: icon).font(.headline).foregroundStyle(c)
                if let last = data.last {
                    Text(last.value2 > 0 ? "\(last.value)/\(last.value2) \(unit)" : "\(last.value)\(unit.isEmpty ? "" : " \(unit)")")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                    Chart(data.suffix(60)) { s in
                        LineMark(x: .value("t", s.date), y: .value("v", s.value)).foregroundStyle(c).interpolationMethod(.catmullRom)
                    }
                    .chartYScale(domain: range).frame(height: 80)
                } else {
                    Text(loaded ? "No readings yet — measure it on the watch." : "Loading…").font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
                }
            }
        }
    }
}

// MARK: - ⌘K command palette

struct PaletteItem: Identifiable {
    let id = UUID()
    let title: String, subtitle: String, icon: String
    let run: () -> Void
}

struct CommandPalette: View {
    @EnvironmentObject var store: WatchStore
    @EnvironmentObject var workout: WorkoutStore
    @Binding var page: Page
    @Binding var shown: Bool
    @State private var query = ""
    @State private var sel = 0
    @FocusState private var focus: Bool

    var items: [PaletteItem] {
        var a: [PaletteItem] = Page.allCases.map { p in PaletteItem(title: p.title, subtitle: "Go to page", icon: p.symbol) { page = p } }
        a += [
            PaletteItem(title: "Ask the assistant", subtitle: "Voice", icon: "waveform.circle.fill") { page = .assistant; store.assistant.toggle() },
            PaletteItem(title: "Ring watch", subtitle: "Action", icon: "bell.and.waves.left.and.right") { Task { await store.findWatch() } },
            PaletteItem(title: "Sync everything", subtitle: "Action", icon: "arrow.triangle.2.circlepath") { Task { await store.refreshAll() } },
            PaletteItem(title: "Sync watch clock", subtitle: "Action", icon: "clock.badge.checkmark") { Task { await store.syncTime() } },
            PaletteItem(title: "Measure heart rate", subtitle: "Action", icon: "heart.fill") { page = .health; Task { await store.toggleLiveHR() } },
            PaletteItem(title: "Start outdoor run", subtitle: "Workout", icon: "figure.run") { page = .workout; workout.setMode(.outdoorRun); Task { await workout.start() } },
            PaletteItem(title: "Start cycling", subtitle: "Workout", icon: "figure.outdoor.cycle") { page = .workout; workout.setMode(.cycling); Task { await workout.start() } },
            PaletteItem(title: "Send a test notification", subtitle: "Action", icon: "bubble.left.fill") { Task { await store.sendNotification(title: "OHW Studio", body: "Hello from your Mac 👋") } },
            PaletteItem(title: "New face from template", subtitle: "Face Composer", icon: "wand.and.stars") { page = .composer },
        ]
        guard !query.isEmpty else { return a }
        return a.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.subtitle.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        let list = items
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Jump to a page or run an action…", text: $query).textFieldStyle(.plain).font(.system(size: 17))
                    .focused($focus)
                    .onSubmit { run(list) }
                    .onKeyPress(.downArrow) { sel = min(sel + 1, list.count - 1); return .handled }
                    .onKeyPress(.upArrow) { sel = max(sel - 1, 0); return .handled }
                    .onKeyPress(.escape) { shown = false; return .handled }
                Text("esc").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, it in
                            HStack(spacing: 12) {
                                Image(systemName: it.icon).frame(width: 22).foregroundStyle(i == sel ? .white : Color.brand)
                                Text(it.title).font(.system(size: 14, weight: .medium))
                                Spacer()
                                Text(it.subtitle).font(.caption).foregroundStyle(i == sel ? .white.opacity(0.8) : .secondary)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background(i == sel ? Color.brand.opacity(0.85) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                            .onTapGesture { sel = i; run(list) }
                            .id(i)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: sel) { _, v in proxy.scrollTo(v) }
            }
            .frame(height: 320)
        }
        .frame(width: 560)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.45), radius: 40, y: 20)
        .onAppear { focus = true; sel = 0 }
        .onChange(of: query) { _, _ in sel = 0 }
    }

    func run(_ list: [PaletteItem]) {
        guard list.indices.contains(sel) else { return }
        list[sel].run()
        shown = false; query = ""
    }
}
