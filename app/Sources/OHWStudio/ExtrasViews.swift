import SwiftUI
import Combine

// MARK: - shared bits

struct NotConnectedBanner: View {
    @EnvironmentObject var store: WatchStore
    var body: some View {
        if !store.ready {
            Label("Connect the watch to read and change these settings.", systemImage: "applewatch.slash")
                .font(.callout).foregroundStyle(.secondary)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct DayPicker: View {
    @Binding var days: Weekdays
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(Weekdays.ordered.enumerated()), id: \.offset) { _, d in
                let on = days.contains(d.0)
                Text(d.1).font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 24)
                    .background(on ? Color.brand : Color.white.opacity(0.07), in: Circle())
                    .foregroundStyle(on ? .white : .secondary)
                    .onTapGesture { if on { days.remove(d.0) } else { days.insert(d.0) } }
            }
        }
    }
}

struct TimeField: View {
    let label: String
    @Binding var minutes: Int
    var body: some View {
        DatePicker(label, selection: Binding(
            get: { Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date() },
            set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0) }),
                   displayedComponents: .hourAndMinute)
            .datePickerStyle(.field)
    }
}

func hm(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }

// MARK: - Alarms

struct AlarmsView: View {
    @EnvironmentObject var store: WatchStore
    @EnvironmentObject var ex: ExtrasStore
    struct EditTarget: Identifiable { let alarm: WatchAlarm; let isNew: Bool; var id: UUID { alarm.id } }
    @State private var editing: EditTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .bottom) {
                SectionHeader(title: "Alarms", subtitle: "Silent vibrating alarms on your wrist, set from your Mac. Up to 10.")
                Button { editing = EditTarget(alarm: WatchAlarm(hour: Calendar.current.component(.hour, from: Date()), minute: 0), isNew: true) } label: {
                    Label("New alarm", systemImage: "plus")
                }.buttonStyle(PrimaryButtonStyle()).disabled(!store.ready || ex.alarms.count >= 10)
            }
            NotConnectedBanner()
            if ex.alarms.isEmpty {
                EmptyHint(text: ex.alarmsLoaded ? "No alarms on the watch yet." : "Alarms load when the watch connects.")
            }
            ForEach($ex.alarms) { $a in
                Card {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(format: "%02d:%02d", a.hour, a.minute))
                                .font(.system(size: 40, weight: .light, design: .rounded)).monospacedDigit()
                                .foregroundStyle(a.enabled ? .primary : .tertiary)
                            Text("\(a.label) · \(a.repeatDays.isEmpty ? "Once" : a.repeatDays.summary)")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { editing = EditTarget(alarm: a, isNew: false) } label: { Image(systemName: "slider.horizontal.3") }.buttonStyle(GhostButtonStyle())
                        Toggle("", isOn: Binding(get: { a.enabled }, set: { a.enabled = $0; Task { await ex.saveAlarms() } }))
                            .toggleStyle(.switch).labelsHidden()
                    }
                }
            }
            Text("The watch vibrates at alarm time. Alarms keep working when your Mac is off.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { if store.ready && !ex.alarmsLoaded { await ex.loadAlarms() } }
        .sheet(item: $editing) { t in
            AlarmEditor(alarm: t.alarm, isNew: t.isNew) { result in
                editing = nil
                guard let result else { return }
                switch result {
                case .save(let n):
                    if let i = ex.alarms.firstIndex(where: { $0.id == n.id }) { ex.alarms[i] = n } else { ex.alarms.append(n) }
                case .delete(let id): ex.alarms.removeAll { $0.id == id }
                }
                ex.alarms.sort { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
                Task { await ex.saveAlarms() }
            }
        }
    }
}

enum AlarmEdit { case save(WatchAlarm), delete(UUID) }

struct AlarmEditor: View {
    @State var alarm: WatchAlarm
    let isNew: Bool
    let done: (AlarmEdit?) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "New alarm" : "Edit alarm").font(.title2.bold())
            DatePicker("Time", selection: Binding(
                get: { Calendar.current.date(bySettingHour: alarm.hour, minute: alarm.minute, second: 0, of: Date()) ?? Date() },
                set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); alarm.hour = c.hour ?? 0; alarm.minute = c.minute ?? 0 }),
                       displayedComponents: .hourAndMinute)
                .datePickerStyle(.stepperField).font(.title)
            TextField("Label", text: $alarm.label).textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 8) {
                Text("Repeat").font(.caption).foregroundStyle(.secondary)
                DayPicker(days: $alarm.repeatDays)
                HStack {
                    Button("Once") { alarm.repeatDays = [] }
                    Button("Weekdays") { alarm.repeatDays = .workdays }
                    Button("Weekends") { alarm.repeatDays = .weekend }
                    Button("Every day") { alarm.repeatDays = .all }
                }.controlSize(.small)
            }
            HStack {
                if !isNew { Button("Delete", role: .destructive) { done(.delete(alarm.id)) } }
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Save to watch") { done(.save(alarm)) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 380)
    }
}

// MARK: - World clock

struct WorldClockView: View {
    @EnvironmentObject var store: WatchStore
    @EnvironmentObject var ex: ExtrasStore
    @State private var query = ""
    @State private var now = Date()
    let catalog = WorldCity.catalog
    let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var matches: [WorldCity] {
        guard query.count >= 2 else { return [] }
        return Array(catalog.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.tz.localizedCaseInsensitiveContains(query) }.prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .bottom) {
                SectionHeader(title: "World Clock", subtitle: "Cities shown in the watch's World Clock app. Daylight saving is handled for you.")
                Button { Task { await ex.pushWorldClock() } } label: { Label("Send to watch", systemImage: "arrow.up.circle.fill") }
                    .buttonStyle(PrimaryButtonStyle()).disabled(!store.ready)
            }
            NotConnectedBanner()
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Add a city (e.g. Lagos, Paris, Los Angeles)…", text: $query).textFieldStyle(.roundedBorder)
                    ForEach(matches) { c in
                        Button {
                            if !ex.cities.contains(c) && ex.cities.count < 7 { ex.cities.append(c); Task { await ex.pushWorldClock(silent: true) } }
                            query = ""
                        } label: {
                            HStack { Text(c.name); Text(c.tz).foregroundStyle(.secondary).font(.caption); Spacer(); Text(time(c.tz)).monospacedDigit() }
                        }.buttonStyle(.plain).padding(.vertical, 3)
                    }
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14)], spacing: 14) {
                ForEach(ex.cities) { c in
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(c.name).font(.headline)
                                Spacer()
                                Button { ex.cities.removeAll { $0 == c }; Task { await ex.pushWorldClock(silent: true) } } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                                }.buttonStyle(.plain)
                            }
                            Text(time(c.tz)).font(.system(size: 38, weight: .light, design: .rounded)).monospacedDigit()
                            Text(diff(c.tz)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .onReceive(tick) { now = $0 }
    }

    func time(_ tz: String) -> String {
        let f = DateFormatter(); f.timeZone = TimeZone(identifier: tz); f.dateFormat = "HH:mm"; return f.string(from: now)
    }
    func diff(_ tz: String) -> String {
        let d = ((TimeZone(identifier: tz)?.secondsFromGMT(for: now) ?? 0) - TimeZone.current.secondsFromGMT(for: now)) / 60
        if d == 0 { return "Same time as here" }
        return String(format: "%@%d h%@ %@", d > 0 ? "+" : "−", abs(d) / 60, abs(d) % 60 == 0 ? "" : " \(abs(d) % 60) min", d > 0 ? "ahead" : "behind")
    }
}

// MARK: - Stocks

struct StocksView: View {
    @EnvironmentObject var store: WatchStore
    @EnvironmentObject var ex: ExtrasStore
    @State private var symbol = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .bottom) {
                SectionHeader(title: "Stocks & Crypto", subtitle: "Live quotes in the watch's Stocks app, refreshed every 5 minutes while OHW Studio runs.")
                if busy { ProgressView().controlSize(.small) }
                Button { refresh() } label: { Label("Refresh & send", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(PrimaryButtonStyle()).disabled(busy)
            }
            NotConnectedBanner()
            Card {
                HStack(spacing: 10) {
                    TextField("Add a ticker: AAPL, MSFT, BTC-USD, ETH-USD, ^GSPC…", text: $symbol)
                        .textFieldStyle(.roundedBorder).onSubmit(add)
                    Button("Add", action: add).disabled(symbol.isEmpty || ex.stocks.count >= 8)
                    Divider().frame(height: 18)
                    Toggle("Auto-refresh", isOn: $ex.stockAuto).toggleStyle(.switch).controlSize(.small)
                    Picker("", selection: $ex.greenUp) { Text("Rise = green").tag(true); Text("Rise = red").tag(false) }
                        .labelsHidden().frame(width: 130)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14)], spacing: 14) {
                ForEach(ex.stocks) { s in
                    let up = s.change >= 0
                    let tint: Color = (up == ex.greenUp) ? .ok : .heart
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(s.symbol).font(.headline)
                                Spacer()
                                Button { ex.stocks.removeAll { $0.symbol == s.symbol }; refresh() } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                                }.buttonStyle(.plain)
                            }
                            Text(s.name.isEmpty ? " " : s.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Text(s.updated == nil ? "—" : s.price.formatted(.number.precision(.fractionLength(2))))
                                .font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
                            if s.updated != nil {
                                Label(String(format: "%@%.2f  (%@%.2f%%)", up ? "+" : "", s.change, up ? "+" : "", s.percent),
                                      systemImage: up ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                                    .font(.callout.weight(.semibold)).foregroundStyle(tint)
                            }
                        }
                    }
                }
            }
            if let t = ex.stocksUpdated {
                Text("Updated \(t.formatted(date: .omitted, time: .shortened)) · quotes from Yahoo Finance, may be delayed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { if ex.stocksUpdated == nil { refresh() } }
    }

    func add() {
        let s = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        guard !s.isEmpty, !ex.stocks.contains(where: { $0.symbol == s }) else { symbol = ""; return }
        ex.stocks.append(StockQuote(symbol: s)); symbol = ""; refresh()
    }
    func refresh() {
        busy = true
        Task { await ex.refreshStocks(push: store.ready); busy = false }
    }
}

// MARK: - Wellness

struct WellnessView: View {
    @EnvironmentObject var store: WatchStore
    @EnvironmentObject var ex: ExtrasStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .bottom) {
                SectionHeader(title: "Wellness", subtitle: "Reminders and background health monitoring — settings CO FIT hides or buries.")
                if ex.loadingSettings { ProgressView().controlSize(.small) }
                Button { Task { await ex.loadSettings() } } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    .buttonStyle(GhostButtonStyle()).disabled(!store.ready)
            }
            NotConnectedBanner()
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], alignment: .leading, spacing: 14) {
                if let r = ex.sedentary {
                    ReminderCard(title: "Move reminder", icon: "figure.walk.motion", tint: .ok, value: r,
                                 intervals: [30, 45, 60, 90, 120, 180]) { n in Task { await ex.setSedentary(n) } }.id(r)
                }
                if let r = ex.drink {
                    ReminderCard(title: "Drink water", icon: "drop.fill", tint: .sky, value: r,
                                 intervals: [30, 45, 60, 90, 120, 180]) { n in Task { await ex.setDrink(n) } }.id(r)
                }
                if let r = ex.wash {
                    ReminderCard(title: "Wash hands", icon: "hands.sparkles.fill", tint: .brand2, value: r,
                                 intervals: [30, 60, 90, 120, 180]) { n in Task { await ex.setWash(n) } }.id(r)
                }
                if let r = ex.hrMonitor {
                    RangeCard(title: "Heart-rate monitoring", subtitle: "Automatic background measurements", icon: "heart.fill", tint: .heart,
                              value: r, intervals: [5, 10, 15, 30, 60]) { n in Task { await ex.setHR(n) } }.id(r)
                }
                if let r = ex.spo2 {
                    RangeCard(title: "Blood oxygen", subtitle: "Automatic SpO₂ checks", icon: "lungs.fill", tint: .sky,
                              value: r, intervals: [30, 60, 120, 180]) { n in Task { await ex.setSpO2(n) } }.id(r)
                }
                if let r = ex.raiseToWake {
                    RangeCard(title: "Raise to wake", subtitle: "Screen turns on when you lift your wrist", icon: "hand.raised.fill",
                              tint: .brand, value: r, intervals: nil) { n in Task { await ex.setWake(n) } }.id(r)
                }
                if let r = ex.dnd, let on = ex.dndEnabled {
                    RangeCard(title: "Do Not Disturb", subtitle: "No vibrations for notifications", icon: "moon.fill", tint: .indigo,
                              value: { var x = r; x.enabled = on; return x }(), intervals: nil) { n in Task { await ex.setDND(n.enabled, n) } }.id("\(r.hashValue)\(on)")
                }
            }
            HStack(alignment: .top, spacing: 14) {
                if let b = ex.body { BodyCard(p: b).id(b.heightCm + b.weightKg + Double(b.age)) }
                if let s = ex.sos { SOSCard(s: s).id(s.phone + "\(s.enabled)") }
            }
            if let c = ex.cycle { CycleCard(c: c).id(c.bytes) }
            if ex.calorieGoal != nil || ex.sleepGoal != nil {
                GoalsCard()
            }
            SystemCard()
        }
        .task(id: store.ready) { if store.ready && ex.sedentary == nil { await ex.loadSettings() }; if store.ready && ex.body == nil { await ex.loadBodyAndSafety() } }
        .onChange(of: store.ready) { _, r in if r && ex.sedentary == nil { Task { await ex.loadSettings() } } }
    }
}

struct ReminderCard: View {
    let title: String, icon: String, tint: Color
    @State var value: ReminderSetting
    let intervals: [Int]
    let apply: (ReminderSetting) -> Void
    @State private var dirty = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: icon).foregroundStyle(tint).frame(width: 28, height: 28).background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.headline)
                        Text(value.enabled ? "Every \(value.interval) min, \(hm(value.start))–\(hm(value.end))" : "Off").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { value.enabled }, set: { value.enabled = $0; apply(value) })).toggleStyle(.switch).labelsHidden()
                }
                if value.enabled {
                    DayPicker(days: Binding(get: { value.days }, set: { value.days = $0; dirty = true }))
                    HStack {
                        TimeField(label: "From", minutes: Binding(get: { value.start }, set: { value.start = $0; dirty = true }))
                        TimeField(label: "to", minutes: Binding(get: { value.end }, set: { value.end = $0; dirty = true }))
                    }
                    Picker("Every", selection: Binding(get: { value.interval }, set: { value.interval = $0; dirty = true })) {
                        ForEach(Array(Set(intervals + [value.interval])).sorted(), id: \.self) { Text("\($0) min").tag($0) }
                    }.frame(maxWidth: 200)
                    if dirty { Button("Apply") { dirty = false; apply(value) }.buttonStyle(PrimaryButtonStyle(tint: tint)) }
                }
            }
        }
    }
}

struct RangeCard: View {
    let title: String, subtitle: String, icon: String, tint: Color
    @State var value: RangeSetting
    let intervals: [Int]?
    let apply: (RangeSetting) -> Void
    @State private var dirty = false

    var allDay: Bool { value.start == value.end || (value.start == 0 && value.end >= 23 * 60 + 59) }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: icon).foregroundStyle(tint).frame(width: 28, height: 28).background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.headline)
                        Text(value.enabled ? (allDay ? "All day" : "\(hm(value.start))–\(hm(value.end))") + (value.interval.map { " · every \($0) min" } ?? "") : subtitle)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { value.enabled }, set: { value.enabled = $0; apply(value) })).toggleStyle(.switch).labelsHidden()
                }
                if value.enabled {
                    HStack {
                        TimeField(label: "From", minutes: Binding(get: { value.start }, set: { value.start = $0; dirty = true }))
                        TimeField(label: "to", minutes: Binding(get: { value.end }, set: { value.end = $0; dirty = true }))
                        Button("All day") { value.start = 0; value.end = 23 * 60 + 59; dirty = true }.controlSize(.small)
                    }
                    if let iv = intervals, let cur = value.interval {
                        Picker("Every", selection: Binding(get: { cur }, set: { value.interval = $0; dirty = true })) {
                            ForEach(Array(Set(iv + [cur])).sorted(), id: \.self) { Text("\($0) min").tag($0) }
                        }.frame(maxWidth: 200)
                    }
                    if dirty { Button("Apply") { dirty = false; apply(value) }.buttonStyle(PrimaryButtonStyle(tint: tint)) }
                }
            }
        }
    }
}

struct GoalsCard: View {
    @EnvironmentObject var ex: ExtrasStore
    @EnvironmentObject var store: WatchStore
    @State private var kcal = 300.0
    @State private var km = 5.0
    @State private var sleepH = 8.0
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Text("Daily goals").font(.headline)
                goal("flame.fill", .orange, "Calories", "\(Int(kcal)) kcal", $kcal, 50...2000, 10) { Task { await ex.setCalorieGoal(Int(kcal)) } }
                goal("location.fill", .sky, "Distance", String(format: "%.1f km", km), $km, 0.5...42, 0.5) { Task { await ex.setDistanceGoal(km) } }
                goal("bed.double.fill", .indigo, "Sleep", String(format: "%.1f h", sleepH), $sleepH, 4...12, 0.5) { Task { await ex.setSleepGoal(Int(sleepH * 60)) } }
                Text("The step goal lives on the Device page.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if let v = ex.calorieGoal { kcal = Double(v) }
            if let v = ex.distanceGoal { km = v }
            if let v = ex.sleepGoal { sleepH = Double(v) / 60 }
        }
    }
    func goal(_ icon: String, _ tint: Color, _ name: String, _ text: String, _ v: Binding<Double>, _ r: ClosedRange<Double>, _ step: Double,
              _ commit: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 22)
            Text(name).frame(width: 70, alignment: .leading)
            Slider(value: v, in: r, step: step, onEditingChanged: { if !$0 { commit() } })
            Text(text).monospacedDigit().frame(width: 80, alignment: .trailing)
        }
    }
}

struct SystemCard: View {
    @EnvironmentObject var ex: ExtrasStore
    @EnvironmentObject var store: WatchStore
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Watch system").font(.headline)
                HStack(spacing: 24) {
                    Picker("Clock", selection: Binding(get: { store.settings.hour24 ?? true }, set: { v in Task { await ex.setHour24(v) } })) {
                        Text("24-hour").tag(true); Text("12-hour").tag(false)
                    }.pickerStyle(.segmented).frame(width: 220)
                    Picker("Units", selection: Binding(get: { ex.metric ?? true }, set: { v in Task { await ex.setMetric(v) } })) {
                        Text("Metric").tag(true); Text("Imperial").tag(false)
                    }.pickerStyle(.segmented).frame(width: 220)
                    Toggle("Vibration", isOn: Binding(get: { store.settings.vibration ?? true }, set: { v in Task { await ex.setVibration(v) } }))
                        .toggleStyle(.switch)
                }
                .disabled(!store.ready)
            }
        }
    }
}

// MARK: - Internals

struct InternalsView: View {
    @EnvironmentObject var store: WatchStore
    @EnvironmentObject var ex: ExtrasStore
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: "Watch Internals", subtitle: "The watch's own firmware log and every setting it will report, decoded live. Read-only.")
            NotConnectedBanner()
            HStack {
                Button { busy = true; Task { await ex.loadLog(); await ex.loadRaw(); busy = false } } label: {
                    Label("Read from watch", systemImage: "arrow.down.doc.fill")
                }.buttonStyle(PrimaryButtonStyle()).disabled(!store.ready || busy)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                if !ex.log.isEmpty || !ex.raw.isEmpty {
                    Button { export() } label: { Label("Export report", systemImage: "square.and.arrow.up") }.buttonStyle(GhostButtonStyle())
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Firmware log", systemImage: "list.bullet.rectangle.portrait").font(.headline)
                    if ex.log.isEmpty { Text("Not read yet.").foregroundStyle(.secondary) }
                    ForEach(Array(ex.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Settings registers", systemImage: "cpu").font(.headline)
                    if ex.raw.isEmpty { Text("Not read yet.").foregroundStyle(.secondary) }
                    ForEach(ex.raw) { r in
                        HStack(alignment: .top) {
                            Text(String(format: "%04X", r.key)).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.brand).frame(width: 44, alignment: .leading)
                            Text(r.name).font(.system(size: 11.5, design: .monospaced)).frame(width: 190, alignment: .leading)
                            Text(r.hex.isEmpty ? "—" : r.hex).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                                .textSelection(.enabled).lineLimit(3)
                        }
                    }
                }
            }
        }
    }

    func export() {
        var s = "OHW-11 internals — \(Date())\n\n== Firmware log\n" + ex.log.joined(separator: "\n")
        s += "\n\n== Registers\n" + ex.raw.map { String(format: "%04X %-28@ %@", $0.key, $0.name as NSString, $0.hex) }.joined(separator: "\n")
        if let b = ex.batteryUsage { s += "\n\n== Battery usage\n\(b)" }
        let p = NSSavePanel(); p.nameFieldStringValue = "OHW-11 internals.txt"
        if p.runModal() == .OK, let u = p.url { try? s.write(to: u, atomically: true, encoding: .utf8) }
    }
}


/// Hidden cycle tracking (GIRL_CARE 0x021A).
struct CycleCard: View {
    @EnvironmentObject var ex: ExtrasStore
    @EnvironmentObject var store: WatchStore
    @State var c: CycleSettings
    @State private var dirty = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Cycle tracking", systemImage: "drop.circle.fill").font(.headline).foregroundStyle(Color.pink)
                    Text("HIDDEN").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.pink.opacity(0.2), in: Capsule()).foregroundStyle(Color.pink)
                    Spacer()
                    Toggle("", isOn: bind(\.enabled)).toggleStyle(.switch).labelsHidden()
                }
                Text("A period and fertility tracker built into the watch but hidden by CO FIT for this model. Turning it on adds the cycle screen to the watch.")
                    .font(.caption).foregroundStyle(.secondary)
                if c.enabled {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 10) {
                            DatePicker("Last period started", selection: bind(\.lastStart), in: ...Date(), displayedComponents: .date)
                            Stepper("Period lasts \(c.periodLength) days", value: bind(\.periodLength), in: 2...10)
                            Stepper("Cycle length \(c.cycleLength) days", value: bind(\.cycleLength), in: 20...45)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Reminders on the watch", isOn: bind(\.reminders))
                            if c.reminders {
                                DatePicker("Remind at", selection: timeBinding, displayedComponents: .hourAndMinute)
                                Stepper("Period: \(c.periodAdvance) day\(c.periodAdvance == 1 ? "" : "s") before", value: bind(\.periodAdvance), in: 0...7)
                                Stepper("Ovulation: \(c.ovulationAdvance) day\(c.ovulationAdvance == 1 ? "" : "s") before", value: bind(\.ovulationAdvance), in: 0...7)
                            }
                        }
                    }
                    HStack(spacing: 18) {
                        stat("Next period", c.nextPeriod, .pink)
                        stat("Fertile window", c.fertileStart, .purple, end: Calendar.current.date(byAdding: .day, value: 1, to: c.ovulation))
                        stat("Ovulation", c.ovulation, .orange)
                    }
                    .padding(.top, 4)
                }
                if dirty {
                    HStack { Spacer(); Button("Apply to watch") { dirty = false; Task { await ex.setCycle(c) } }
                        .buttonStyle(PrimaryButtonStyle(tint: .pink)).disabled(!store.ready) }
                }
            }
        }
    }

    func stat(_ title: String, _ d: Date, _ tint: Color, end: Date? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(end.map { "\(d.formatted(.dateTime.month(.abbreviated).day()))–\($0.formatted(.dateTime.day()))" } ?? d.formatted(.dateTime.month(.abbreviated).day()))
                .font(.title3.bold()).foregroundStyle(tint)
            Text(relative(d)).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    func relative(_ d: Date) -> String {
        let n = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: d).day ?? 0
        return n == 0 ? "today" : n > 0 ? "in \(n) day\(n == 1 ? "" : "s")" : "\(-n) day\(n == -1 ? "" : "s") ago"
    }
    func bind<T>(_ kp: WritableKeyPath<CycleSettings, T>) -> Binding<T> {
        Binding(get: { c[keyPath: kp] }, set: { c[keyPath: kp] = $0; dirty = true
            if kp == \CycleSettings.enabled { dirty = false; Task { await ex.setCycle(c) } } })
    }
    var timeBinding: Binding<Date> {
        Binding(get: { Calendar.current.date(from: DateComponents(hour: c.hour, minute: c.minute)) ?? Date() },
                set: { let x = Calendar.current.dateComponents([.hour, .minute], from: $0); c.hour = x.hour ?? 20; c.minute = x.minute ?? 0; dirty = true })
    }
}
