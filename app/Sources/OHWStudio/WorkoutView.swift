import SwiftUI
import Charts

struct WorkoutView: View {
    @EnvironmentObject var store: WatchStore
    @EnvironmentObject var w: WorkoutStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: "Workout", subtitle: "Start the watch's sport screen from your Mac. OHW Studio keeps time, distance, pace and calories; the watch adds live heart rate.")
            NotConnectedBanner()
            if w.phase == .idle { modePicker }
            live
            HStack(alignment: .top, spacing: 14) {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Pace").font(.headline)
                        HStack {
                            Text("Speed").frame(width: 70, alignment: .leading).foregroundStyle(.secondary)
                            Slider(value: $w.speedKmh, in: w.mode == .cycling ? 5...45 : 1...22, step: 0.1)
                            Text(String(format: "%.1f km/h", w.speedKmh)).monospacedDigit().frame(width: 80, alignment: .trailing)
                        }
                        if w.mode != .cycling {
                            HStack {
                                Text("Cadence").frame(width: 70, alignment: .leading).foregroundStyle(.secondary)
                                Slider(value: Binding(get: { Double(w.cadence) }, set: { w.cadence = Int($0) }), in: 0...210, step: 1)
                                Text("\(w.cadence) spm").monospacedDigit().frame(width: 80, alignment: .trailing)
                            }
                        }
                        Text("Set these to match your treadmill or bike. Change them any time; the watch updates every second.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text("Heart rate").font(.headline); Spacer(); if w.avgHR > 0 { Text("avg \(w.avgHR) bpm").foregroundStyle(.secondary) } }
                        if w.hr.isEmpty {
                            Text(w.phase == .idle ? "The watch streams heart rate during a workout." : "Waiting for the watch's sensor…")
                                .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
                        } else {
                            Chart(w.hr) { s in
                                LineMark(x: .value("t", s.date), y: .value("bpm", s.value)).foregroundStyle(Color.heart).interpolationMethod(.catmullRom)
                                AreaMark(x: .value("t", s.date), y: .value("bpm", s.value)).interpolationMethod(.catmullRom)
                                    .foregroundStyle(LinearGradient(colors: [.heart.opacity(0.3), .clear], startPoint: .top, endPoint: .bottom))
                            }
                            .chartYScale(domain: 50...200).frame(height: 110)
                        }
                    }
                }
            }
            if !w.history.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("History").font(.headline)
                        ForEach(w.history.prefix(12)) { r in
                            HStack {
                                Image(systemName: SportMode(rawValue: r.mode)?.icon ?? "figure.run").foregroundStyle(.sky).frame(width: 24)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(SportMode(rawValue: r.mode)?.title ?? "Workout").font(.callout.weight(.semibold))
                                    Text(r.start.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                stat(WorkoutStore.clock(r.seconds), "time")
                                stat(String(format: "%.2f", r.meters / 1000), "km")
                                stat("\(Int(r.kcal))", "kcal")
                                stat(r.avgHR > 0 ? "\(r.avgHR)" : "—", "bpm")
                            }
                            Divider().opacity(0.3)
                        }
                    }
                }
            }
        }
    }

    func stat(_ v: String, _ u: String) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(v).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(u).font(.caption2).foregroundStyle(.secondary)
        }.frame(width: 70, alignment: .trailing)
    }

    var modePicker: some View {
        HStack(spacing: 12) {
            ForEach(SportMode.allCases) { m in
                Button { w.setMode(m) } label: {
                    VStack(spacing: 8) {
                        Image(systemName: m.icon).font(.system(size: 26, weight: .semibold))
                        Text(m.title).font(.system(size: 13, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity).frame(height: 86)
                    .background(w.mode == m ? Color.sky.opacity(0.22) : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(w.mode == m ? Color.sky : .clear, lineWidth: 2))
                    .foregroundStyle(w.mode == m ? Color.sky : .primary)
                }.buttonStyle(.plain)
            }
        }
    }

    var live: some View {
        Card(padding: 22) {
            HStack(alignment: .center, spacing: 26) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(w.mode.title, systemImage: w.mode.icon).font(.headline).foregroundStyle(.sky)
                    Text(WorkoutStore.clock(w.elapsed)).font(.system(size: 64, weight: .bold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText())
                    Text(w.phase == .running ? "In progress" : w.phase == .paused ? "Paused" : "Ready").foregroundStyle(.secondary)
                }
                Spacer()
                metric(String(format: "%.2f", w.meters / 1000), "km", .sky)
                metric(WorkoutStore.pace(w.paceSecPerKm), "/km", .ok)
                metric("\(Int(w.kcal))", "kcal", .brand)
                metric(w.hr.last.map { "\($0.value)" } ?? "—", "bpm", .heart)
                VStack(spacing: 8) {
                    switch w.phase {
                    case .idle:
                        Button { Task { await w.start() } } label: { Label("Start", systemImage: "play.fill").frame(width: 110) }
                            .buttonStyle(PrimaryButtonStyle(tint: .ok)).disabled(!store.ready)
                    case .running:
                        Button { Task { await w.pause() } } label: { Label("Pause", systemImage: "pause.fill").frame(width: 110) }.buttonStyle(PrimaryButtonStyle(tint: .orange))
                        Button { Task { await w.end() } } label: { Label("End", systemImage: "stop.fill").frame(width: 110) }.buttonStyle(PrimaryButtonStyle(tint: .heart))
                    case .paused:
                        Button { Task { await w.resume() } } label: { Label("Resume", systemImage: "play.fill").frame(width: 110) }.buttonStyle(PrimaryButtonStyle(tint: .ok))
                        Button { Task { await w.end() } } label: { Label("End", systemImage: "stop.fill").frame(width: 110) }.buttonStyle(PrimaryButtonStyle(tint: .heart))
                    }
                }
            }
        }
    }

    func metric(_ v: String, _ u: String, _ c: Color) -> some View {
        VStack(spacing: 2) {
            Text(v).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit().contentTransition(.numericText())
            Text(u).font(.caption.weight(.semibold)).foregroundStyle(c)
        }.frame(minWidth: 80)
    }
}

// MARK: - Wellness additions

struct BodyCard: View {
    @EnvironmentObject var ex: ExtrasStore
    @State var p: BodyProfile
    @State private var dirty = false
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "person.fill").foregroundStyle(.brand).frame(width: 28, height: 28).background(Color.brand.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Body profile").font(.headline)
                        Text("The watch uses this for calories and distance.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Picker("", selection: Binding(get: { p.male }, set: { p.male = $0; dirty = true })) { Text("Male").tag(true); Text("Female").tag(false) }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                Stepper("Age  \(p.age)", value: Binding(get: { p.age }, set: { p.age = $0; dirty = true }), in: 5...110)
                HStack { Text("Height").frame(width: 60, alignment: .leading); Slider(value: Binding(get: { p.heightCm }, set: { p.heightCm = $0.rounded(); dirty = true }), in: 100...230)
                    Text("\(Int(p.heightCm)) cm").monospacedDigit().frame(width: 60, alignment: .trailing) }
                HStack { Text("Weight").frame(width: 60, alignment: .leading); Slider(value: Binding(get: { p.weightKg }, set: { p.weightKg = ($0 * 2).rounded() / 2; dirty = true }), in: 30...200)
                    Text(String(format: "%.1f kg", p.weightKg)).monospacedDigit().frame(width: 60, alignment: .trailing) }
                if dirty { Button("Apply") { dirty = false; Task { await ex.setBody(p) } }.buttonStyle(PrimaryButtonStyle()) }
            }
        }
    }
}

struct SOSCard: View {
    @EnvironmentObject var ex: ExtrasStore
    @State var s: SOSContact
    @State private var dirty = false
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "sos").foregroundStyle(.heart).frame(width: 28, height: 28).background(Color.heart.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Emergency SOS").font(.headline)
                        Text("The number the watch calls from its SOS shortcut.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { s.enabled }, set: { s.enabled = $0; dirty = true })).toggleStyle(.switch).labelsHidden()
                }
                TextField("+234 …", text: Binding(get: { s.phone }, set: { s.phone = String($0.filter { "+0123456789- ".contains($0) }.prefix(18)); dirty = true }))
                    .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                if dirty { Button("Save to watch") { dirty = false; Task { await ex.setSOS(s) } }.buttonStyle(PrimaryButtonStyle(tint: .heart)) }
            }
        }
    }
}
