import SwiftUI
import UniformTypeIdentifiers

// MARK: - Developer section

enum DevTab: String, CaseIterable, Identifiable {
    case device, selftest, lab, scanner, capabilities, chip, simulate, link
    var id: String { rawValue }
    var title: String {
        switch self {
        case .device: return "Device"; case .selftest: return "Self-test"; case .lab: return "Command lab"
        case .scanner: return "Scanner"; case .capabilities: return "Capabilities"; case .chip: return "JieLi chip"; case .simulate: return "Simulate"; case .link: return "Link"
        }
    }
    var icon: String {
        switch self {
        case .device: return "wrench.and.screwdriver.fill"; case .selftest: return "stethoscope"; case .lab: return "terminal"
        case .scanner: return "dot.radiowaves.left.and.right"; case .capabilities: return "checklist"; case .chip: return "cpu.fill"
        case .simulate: return "play.square.stack"; case .link: return "point.3.connected.trianglepath.dotted"
        }
    }
}

struct DeveloperView: View {
    @EnvironmentObject var store: WatchStore
    @EnvironmentObject var dev: DevStore
    @State private var tab: DevTab = .device
    @State private var ack = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: "Developer", subtitle: "Low-level access to the OHW-11 — the controls CO FIT keeps in its hidden developer menu, and more.")
            if !dev.enabled { gate } else {
                DevWarningStrip()
                Picker("", selection: $tab) { ForEach(DevTab.allCases) { Label($0.title, systemImage: $0.icon).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
                NotConnectedBanner()
                switch tab {
                case .device: DevDeviceTab()
                case .selftest: DevSelfTestTab()
                case .lab: DevLabTab()
                case .scanner: DevScannerTab()
                case .capabilities: DevCapabilitiesTab()
                case .chip: DevChipTab()
                case .simulate: DevSimulateTab()
                case .link: DevLinkTab()
                }
            }
        }
    }

    var gate: some View {
        Card(padding: 26) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 34)).foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Here be dragons").font(.title2.bold())
                        Text("These tools send raw commands straight to the watch firmware.").foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    bullet("power", "Some actions shut the watch down, rename it, or change settings CO FIT can't see.")
                    bullet("arrow.triangle.2.circlepath", "Renaming can make CO FIT on your iPhone lose the watch until you pair it again.")
                    bullet("cpu", "Factory self-test puts the watch into a manufacturer test mode. OHW Studio always sends the exit command; a restart also clears it.")
                    bullet("terminal", "The command lab can send anything. Firmware update, file-transfer and address commands stay locked unless you unlock them.")
                    bullet("shield.lefthalf.filled", "Nothing here can update or erase the firmware; those commands are never sent automatically.")
                }
                Toggle("I understand these tools can misconfigure my watch, and I'm using them at my own risk.", isOn: $ack)
                    .toggleStyle(.checkbox)
                Button { dev.enabled = true } label: { Label("Enable developer mode", systemImage: "hammer.fill") }
                    .buttonStyle(PrimaryButtonStyle(tint: .orange)).disabled(!ack)
            }
        }
    }

    func bullet(_ icon: String, _ s: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(.orange)
            Text(s).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct DevWarningStrip: View {
    @EnvironmentObject var dev: DevStore
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Developer mode is on. Commands here go straight to the firmware.").font(.callout)
            Spacer()
            Button("Turn off") { dev.enabled = false; dev.allowDangerous = false }.controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.orange.opacity(0.35)))
    }
}

struct DangerTag: View {
    let level: Int   // 1 caution, 2 risky
    var body: some View {
        Text(level == 2 ? "RISKY" : "CAUTION").font(.system(size: 9.5, weight: .heavy)).kerning(0.6)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background((level == 2 ? Color.red : .orange).opacity(0.18), in: Capsule())
            .foregroundStyle(level == 2 ? .red : .orange)
    }
}

struct DevCard<Content: View>: View {
    let title: String, icon: String
    var level = 0
    @ViewBuilder var content: Content
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: icon).foregroundStyle(.brand).frame(width: 20)
                    Text(title).font(.headline)
                    if level > 0 { DangerTag(level: level) }
                    Spacer()
                }
                content
            }
        }
    }
}

// MARK: Device tab

struct DevDeviceTab: View {
    @EnvironmentObject var store: WatchStore
    @EnvironmentObject var dev: DevStore
    @State private var name = ""
    @State private var clock = Date()
    @State private var tzQuarters = TimeZone.current.secondsFromGMT() / 900
    @State private var confirmShutdown = false
    @State private var confirmRename = false

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], alignment: .leading, spacing: 14) {
            DevCard(title: "Rename watch", icon: "character.cursor.ibeam", level: 2) {
                Text("Changes the Bluetooth name the watch advertises (max 29 bytes). OHW Studio still finds it by its JieLi maker ID.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField(store.link.deviceInfo?.name ?? "OHW-11", text: $name).textFieldStyle(.roundedBorder)
                    Button("Rename…") { confirmRename = true }.disabled(name.isEmpty || name.utf8.count > 29 || !store.ready)
                }
                Button("Restore “OHW-11”") { Task { await dev.rename("OHW-11") } }.controlSize(.small).disabled(!store.ready)
            }
            DevCard(title: "Power", icon: "power", level: 2) {
                Text("Turns the watch off. Hold the side button to switch it back on.").font(.caption).foregroundStyle(.secondary)
                Button(role: .destructive) { confirmShutdown = true } label: { Label("Shut down watch", systemImage: "power") }
                    .disabled(!store.ready)
            }
            DevCard(title: "Calls & audio Bluetooth", icon: "headphones", level: 1) {
                Text("The classic Bluetooth radio used for calls and the watch speaker. Turning it off saves battery.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Turn on") { Task { await dev.setClassicBT(true) } }
                    Button("Turn off") { Task { await dev.setClassicBT(false) } }
                }.disabled(!store.ready)
            }
            DevCard(title: "Time travel", icon: "clock.arrow.2.circlepath", level: 1) {
                Text("Set the watch to any date and time — handy for testing faces and alarms. Sync puts it back.")
                    .font(.caption).foregroundStyle(.secondary)
                DatePicker("", selection: $clock).labelsHidden()
                HStack {
                    Button("Set watch clock") { Task { await dev.setClock(clock) } }
                    Button("Sync to Mac") { Task { await store.syncTime() } }
                }.disabled(!store.ready)
            }
            DevCard(title: "Time zone register", icon: "globe", level: 1) {
                Stepper("UTC\(tzQuarters >= 0 ? "+" : "−")\(abs(tzQuarters) / 4):\(String(format: "%02d", abs(tzQuarters) % 4 * 15))  (\(tzQuarters) × 15 min)",
                        value: $tzQuarters, in: -48...56)
                Button("Write") { Task { await dev.setTimeZone(quarters: tzQuarters) } }.disabled(!store.ready)
            }
            DevCard(title: "Watch language", icon: "character.bubble", level: 1) {
                if dev.languages.isEmpty {
                    Button("Read supported languages") { Task { await dev.loadLanguages() } }.disabled(!store.ready)
                } else {
                    Picker("Language", selection: Binding(get: { dev.currentLanguage ?? 1 }, set: { c in
                        dev.currentLanguage = c
                        Task { await dev.simpleWrite(BleKey.language, UInt8(c), "Watch language: \(DevStore.languageName(c))") }
                    })) {
                        ForEach(dev.languages, id: \.self) { Text(DevStore.languageName($0)).tag($0) }
                    }
                    Text("\(dev.languages.count) languages installed on this watch.").font(.caption).foregroundStyle(.secondary)
                }
            }
            DevCard(title: "Formats", icon: "textformat.123") {
                HStack {
                    Text("Temperature").frame(width: 90, alignment: .leading)
                    Button("°C") { Task { await dev.simpleWrite(BleKey.temperatureUnit, 0, "Temperature in °C") } }
                    Button("°F") { Task { await dev.simpleWrite(BleKey.temperatureUnit, 1, "Temperature in °F") } }
                }
                HStack {
                    Text("Date format").frame(width: 90, alignment: .leading)
                    ForEach(0..<3) { v in Button("Style \(v)") { Task { await dev.simpleWrite(BleKey.dateFormat, UInt8(v), "Date format \(v)") } } }
                }
            }.disabled(!store.ready)
            DevCard(title: "Anti-lost alert", icon: "wave.3.right") {
                Text("Vibrate when the watch loses its connection to this Mac or your phone.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("On") { Task { await dev.simpleWrite(BleKey.antiLost, 1, "Anti-lost alert on") } }
                    Button("Off") { Task { await dev.simpleWrite(BleKey.antiLost, 0, "Anti-lost alert off") } }
                }.disabled(!store.ready)
            }
            DevCard(title: "Custom boot logo", icon: "photo.badge.exclamationmark") {
                Label("Not supported by this firmware", systemImage: "xmark.octagon").foregroundStyle(.secondary)
                Text("The watch reports SupportCustomLogo = 0, so CO FIT's logo uploader (LOGO_FILE 0x070C) is disabled for it. Forcing it could leave a broken image at power-on, so OHW Studio doesn't offer it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Shut down the watch?", isPresented: $confirmShutdown) {
            Button("Shut down", role: .destructive) { Task { await dev.shutdown() } }
        } message: { Text("It disconnects immediately. Hold the side button to turn it back on.") }
        .confirmationDialog("Rename the watch to “\(name)”?", isPresented: $confirmRename) {
            Button("Rename") { Task { await dev.rename(name) } }
        } message: { Text("CO FIT on your iPhone may need to pair again afterwards.") }
    }
}

// MARK: Self-test tab

struct DevSelfTestTab: View {
    @EnvironmentObject var store: WatchStore
    @EnvironmentObject var dev: DevStore
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card {
                HStack(spacing: 12) {
                    Image(systemName: dev.factoryActive ? "cpu.fill" : "cpu").font(.title2).foregroundStyle(dev.factoryActive ? .orange : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack { Text("Factory test mode").font(.headline); DangerTag(level: 1) }
                        Text(dev.factoryActive ? "Active — the watch is in its manufacturer test mode." : "Off. Running any test enters it; leaving this page exits it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if dev.factoryActive {
                        Button("Exit test mode") { Task { await dev.exitFactory() } }.buttonStyle(PrimaryButtonStyle(tint: .orange))
                    } else {
                        Button("Enter & read hardware") { Task { await dev.enterFactory() } }.buttonStyle(PrimaryButtonStyle()).disabled(!store.ready)
                    }
                }
            }
            HStack(alignment: .top, spacing: 14) {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Hardware report", systemImage: "list.bullet.rectangle").font(.headline)
                        if dev.hardware.isEmpty { Text("Enter test mode to read it.").foregroundStyle(.secondary) }
                        ForEach(Array(dev.hardware.enumerated()), id: \.offset) { _, kv in
                            HStack(alignment: .top) {
                                Text(kv.0).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
                                Text(kv.1).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            }.font(.callout)
                        }
                    }
                }
                AccelCard()
            }
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Component tests").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 10)], spacing: 10) {
                        ForEach(FactoryTest.allCases) { t in
                            HStack(spacing: 10) {
                                Image(systemName: t.icon).frame(width: 22).foregroundStyle(.brand)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.title).font(.system(size: 13, weight: .semibold))
                                    Text(dev.testResults[t] ?? "Not run").font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer()
                                Button("Run") { Task { await dev.run(t) } }.controlSize(.small).disabled(!store.ready)
                            }
                            .padding(10).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
        }
        .onDisappear { if dev.factoryActive { Task { await dev.exitFactory() } } }
    }
}

struct AccelCard: View {
    @EnvironmentObject var dev: DevStore
    @EnvironmentObject var store: WatchStore
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Live accelerometer", systemImage: "move.3d").font(.headline)
                    Spacer()
                    Button(dev.accelLive ? "Stop" : "Start") { dev.toggleAccelLive() }.disabled(!store.ready)
                }
                ZStack {
                    Circle().stroke(.white.opacity(0.15), lineWidth: 1).frame(width: 150, height: 150)
                    Circle().stroke(.white.opacity(0.08), lineWidth: 1).frame(width: 75, height: 75)
                    Path { p in p.move(to: CGPoint(x: 75, y: 0)); p.addLine(to: CGPoint(x: 75, y: 150)); p.move(to: CGPoint(x: 0, y: 75)); p.addLine(to: CGPoint(x: 150, y: 75)) }
                        .stroke(.white.opacity(0.08)).frame(width: 150, height: 150)
                    let a = dev.accel ?? (0, 0, 1)
                    Circle().fill(Color.brand.gradient).frame(width: 22, height: 22)
                        .shadow(color: .brand.opacity(0.7), radius: 8)
                        .offset(x: CGFloat(max(-1, min(1, a.x))) * 64, y: CGFloat(max(-1, min(1, -a.y))) * 64)
                        .animation(.spring(duration: 0.18), value: a.x + a.y)
                }
                .frame(maxWidth: .infinity)
                if let a = dev.accel {
                    Text(String(format: "x %+.2f g   y %+.2f g   z %+.2f g", a.x, a.y, a.z)).font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity)
                    Text(String(format: "tilt %.0f°", acos(max(-1, min(1, a.z / max(0.01, sqrt(a.x * a.x + a.y * a.y + a.z * a.z))))) * 180 / .pi))
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                } else {
                    Text("Tilt the watch and watch the bubble move. Polls the factory G-sensor test (~6 Hz).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 300)
    }
}

// MARK: Command lab

struct DevLabTab: View {
    @EnvironmentObject var store: WatchStore
    @EnvironmentObject var dev: DevStore
    @State private var query = ""
    @State private var keyText = "0203"
    @State private var flag: UInt8 = BleFlag.read
    @State private var payload = ""

    var key: UInt16? { UInt16(keyText.replacingOccurrences(of: "0x", with: ""), radix: 16) }
    var matches: [(key: UInt16, name: String)] {
        query.isEmpty ? [] : Array(KeyCatalog.all.filter { $0.name.localizedCaseInsensitiveContains(query) || String(format: "%04x", $0.key).contains(query.lowercased()) }.prefix(10))
    }
    var locked: Bool { key.map { DevStore.isDangerous($0) && !dev.allowDangerous } ?? true }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Search 318 commands by name or hex (e.g. ALARM, weather, 0605)…", text: $query).textFieldStyle(.roundedBorder)
                    if !matches.isEmpty {
                        FlowList(items: matches.map { ($0.key, $0.name) }) { k in keyText = String(format: "%04X", k); query = "" }
                    }
                    HStack(spacing: 10) {
                        Text("Key 0x").foregroundStyle(.secondary)
                        TextField("0203", text: $keyText).textFieldStyle(.roundedBorder).frame(width: 70).font(.system(.body, design: .monospaced))
                        Text(key.map { KeyCatalog.name($0) } ?? "invalid").font(.system(size: 12, design: .monospaced)).foregroundStyle(.brand)
                        if let k = key, DevStore.isDangerous(k) { DangerTag(level: 2) }
                        Spacer()
                        Picker("", selection: $flag) {
                            Text("READ").tag(BleFlag.read); Text("UPDATE").tag(BleFlag.update); Text("CREATE").tag(BleFlag.create)
                            Text("DELETE").tag(BleFlag.delete); Text("RESET").tag(UInt8(0x40))
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 360)
                    }
                    HStack(spacing: 10) {
                        Text("Data").foregroundStyle(.secondary)
                        TextField("hex bytes, e.g. 01 ff 0a", text: $payload).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                        Button { send() } label: { Label("Send", systemImage: "paperplane.fill") }
                            .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.return, modifiers: .command)
                            .disabled(key == nil || DevStore.parseHex(payload) == nil || !store.ready || locked)
                    }
                    HStack {
                        Toggle("Unlock dangerous commands (OTA, XMODEM, shutdown, passwords, addresses, file streams)", isOn: $dev.allowDangerous)
                            .toggleStyle(.checkbox).foregroundStyle(dev.allowDangerous ? .red : .secondary)
                        Spacer()
                        if locked, key != nil { Text("Locked").font(.caption).foregroundStyle(.red) }
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text("History").font(.headline); Spacer(); Button("Clear") { dev.history = [] }.controlSize(.small) }
                    if dev.history.isEmpty { Text("Replies show here. Tip: READ any key to see what the watch stores.").foregroundStyle(.secondary) }
                    ForEach(dev.history) { e in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(e.date.formatted(date: .omitted, time: .standard)).foregroundStyle(.tertiary)
                                Text(String(format: "→ %04X %@ flag %02X", e.key, KeyCatalog.name(e.key), e.flag)).foregroundStyle(.brand)
                                Text(hex(e.payload, max: 40)).foregroundStyle(.secondary)
                                Spacer()
                                Button { keyText = String(format: "%04X", e.key); flag = e.flag; payload = hex(e.payload, max: 4096) } label: {
                                    Image(systemName: "arrow.uturn.left")
                                }.buttonStyle(.plain).help("Load into the composer")
                            }
                            Text(e.pending ? "← waiting…" : e.reply.map { $0.isEmpty ? "← ack (no data)" : "← \($0.count) B  " + hex($0, max: 600) } ?? "← no reply")
                                .foregroundStyle(e.pending ? Color.secondary : e.reply == nil ? Color.red : Color.primary).textSelection(.enabled)
                        }
                        .font(.system(size: 11.5, design: .monospaced))
                        .padding(.vertical, 4)
                        Divider().opacity(0.3)
                    }
                }
            }
        }
    }

    func send() {
        guard let k = key, let p = DevStore.parseHex(payload) else { return }
        Task { await dev.send(key: k, flag: flag, payload: p) }
    }
}

struct FlowList: View {
    let items: [(UInt16, String)]
    let pick: (UInt16) -> Void
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.0) { k in
                Button { pick(k.0) } label: {
                    HStack(spacing: 6) {
                        Text(String(format: "%04X", k.0)).foregroundStyle(.brand)
                        Text(k.1).lineLimit(1)
                        if DevStore.isDangerous(k.0) { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                    }
                    .font(.system(size: 11.5, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain)
            }
        }
    }
}

// MARK: Scanner

struct DevScannerTab: View {
    @EnvironmentObject var store: WatchStore
    @EnvironmentObject var dev: DevStore
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Command scanner").font(.headline)
                        Text("Sends a READ for every safe key (~300) and lists the ones that return data. Takes about 5 minutes.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let p = dev.scanProgress {
                        ProgressView(value: p).frame(width: 140)
                        Text("\(Int(p * 100))%").monospacedDigit()
                        Button("Stop") { dev.stopScan() }
                    } else {
                        Button { dev.startScan() } label: { Label("Scan watch", systemImage: "dot.radiowaves.left.and.right") }
                            .buttonStyle(PrimaryButtonStyle()).disabled(!store.ready)
                    }
                    if !dev.scan.isEmpty && dev.scanProgress == nil { Button("Export…") { export() } }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(dev.scan.count) keys returned data").font(.headline)
                    ForEach(dev.scan) { r in
                        HStack(alignment: .top) {
                            Text(String(format: "%04X", r.key)).foregroundStyle(.brand).frame(width: 44, alignment: .leading)
                            Text(r.name).frame(width: 220, alignment: .leading)
                            Text("\(r.data.count) B").foregroundStyle(.tertiary).frame(width: 50, alignment: .trailing)
                            Text(hex(r.data, max: 200)).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
                        }.font(.system(size: 11.5, design: .monospaced))
                    }
                }
            }
        }
    }
    func export() {
        let s = dev.scan.map { String(format: "%04X %-32@ %@", $0.key, $0.name as NSString, $0.data.map { String(format: "%02x", $0) }.joined()) }.joined(separator: "\n")
        let p = NSSavePanel(); p.nameFieldStringValue = "OHW-11 key scan.txt"
        if p.runModal() == .OK, let u = p.url { try? s.write(to: u, atomically: true, encoding: .utf8) }
    }
}

// MARK: Capabilities

struct DevCapabilitiesTab: View {
    static func on(_ v: String) -> Bool { (Int(v) ?? 0) != 0 }
    @EnvironmentObject var store: WatchStore
    @EnvironmentObject var dev: DevStore
    @State private var onlySupported = false
    var body: some View {
        let caps = dev.capabilities
        let flags = caps.filter { $0.support }
        let present = flags.filter { $0.value != "—" }
        let shown = present.filter { !onlySupported || Self.on($0.value) }
        VStack(alignment: .leading, spacing: 14) {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Identity").font(.headline)
                    if caps.isEmpty { Text("Connect the watch: it sends this report during pairing.").foregroundStyle(.secondary) }
                    ForEach(Array(caps.filter { !$0.support }.enumerated()), id: \.offset) { _, c in
                        if !c.value.isEmpty && c.value != "0" && c.value != "—" {
                            HStack { Text(c.name).foregroundStyle(.secondary).frame(width: 200, alignment: .leading)
                                Text(c.value).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }.font(.callout)
                        }
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Feature flags").font(.headline)
                        Text("\(present.filter { Self.on($0.value) }.count) of \(present.count) supported").foregroundStyle(.secondary)
                        Spacer()
                        Toggle("Supported only", isOn: $onlySupported).toggleStyle(.switch).controlSize(.small)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 6)], alignment: .leading, spacing: 6) {
                        ForEach(Array(shown.enumerated()), id: \.offset) { _, c in
                            let on = c.value != "0" && c.value != "—"
                            HStack(spacing: 6) {
                                Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? Color.ok : Color.secondary.opacity(0.5))
                                Text(c.name).font(.system(size: 12)).foregroundStyle(on ? .primary : .secondary).lineLimit(1)
                                if on && c.value != "1" { Text(c.value).font(.caption2).foregroundStyle(.tertiary) }
                            }
                        }
                    }
                    Text("Decoded from the device-info packet with CO FIT's own field order. CO FIT hides any feature marked unsupported.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: Simulate

struct DevSimulateTab: View {
    @EnvironmentObject var store: WatchStore
    @EnvironmentObject var dev: DevStore
    @State private var app = "com.whatsapp"
    @State private var title = "Ada"
    @State private var bodyText = "Are we still on for tonight?"
    @State private var caller = "Mum"

    static let apps: [(String, String)] = [
        ("Messages", "com.apple.MobileSMS"), ("WhatsApp", "com.whatsapp"), ("Telegram", "org.telegram.messenger"),
        ("Instagram", "com.burbn.instagram"), ("Facebook", "com.facebook.Facebook"), ("Messenger", "com.facebook.Messenger"),
        ("X / Twitter", "com.atebits.Tweetie2"), ("Gmail", "com.google.Gmail"), ("Mail", "com.apple.mobilemail"),
        ("Snapchat", "com.toyopagroup.picaboo"), ("Skype", "com.skype.skype"), ("LinkedIn", "com.linkedin.LinkedIn"),
        ("YouTube", "com.google.ios.youtube"), ("WeChat", "com.tencent.xin"), ("Line", "jp.naver.line"), ("Calendar", "com.apple.mobilecal"),
    ]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], alignment: .leading, spacing: 14) {
            DevCard(title: "Notification icon lab", icon: "app.badge") {
                Text("The watch picks the notification icon from the app's bundle ID. Try them all.").font(.caption).foregroundStyle(.secondary)
                Picker("App", selection: $app) { ForEach(Self.apps, id: \.1) { Text($0.0).tag($0.1) } }
                TextField("Bundle ID", text: $app).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                TextField("Title", text: $title).textFieldStyle(.roundedBorder)
                TextField("Message", text: $bodyText).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Send") { Task { await store.sendNotification(title: title, body: bodyText, app: app) } }
                    Button("Send all \(Self.apps.count) apps") {
                        Task { for a in Self.apps { await store.sendNotification(title: a.0, body: "Icon test", app: a.1); try? await Task.sleep(nanoseconds: 900_000_000) } }
                    }
                }.disabled(!store.ready)
            }
            DevCard(title: "Fake incoming call", icon: "phone.arrow.down.left") {
                Text("Rings the watch with any caller name.").font(.caption).foregroundStyle(.secondary)
                TextField("Caller", text: $caller).textFieldStyle(.roundedBorder)
                Button("Ring watch") { Task { await store.sendNotification(title: caller, body: "", call: true) } }.disabled(!store.ready)
            }
            DevCard(title: "Simulate watch buttons", icon: "hand.point.up.left") {
                Text("Inject events as if they came from the watch — tests your Remote mappings without touching it.")
                    .font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], spacing: 6) {
                    ForEach([("Play/pause", WatchEvent.music(2)), ("Next", .music(3)), ("Previous", .music(4)), ("Vol +", .music(5)),
                             ("Vol −", .music(6)), ("Camera open", .camera(1)), ("Shutter", .camera(2)), ("Find phone", .findPhone(true))],
                            id: \.0) { e in
                        Button(e.0) { store.link.events.send(e.1) }.frame(maxWidth: .infinity)
                    }
                }
            }
            SportExplorer()
            DevCard(title: "Factory vibration test", icon: "iphone.radiowaves.left.and.right", level: 1) {
                Text("Pulses the vibration motor through the factory test channel.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Buzz") { Task { await dev.run(.motor); await dev.exitFactory() } }
                    Button("Ring via notification") { Task { await store.findWatch() } }
                }.disabled(!store.ready)
            }
        }
    }
}

// MARK: Link

struct DevLinkTab: View {
    @EnvironmentObject var store: WatchStore
    @EnvironmentObject var dev: DevStore
    @State private var uploading: Double?
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], alignment: .leading, spacing: 14) {
            DevCard(title: "Connection", icon: "antenna.radiowaves.left.and.right") {
                row("State", store.state.label)
                row("Peripheral", store.link.peripheralID)
                row("RSSI", store.link.rssi.map { "\($0) dBm" } ?? "—")
                row("Write MTU", "\(store.link.writeMTU) B")
                row("IO buffer", "\(store.link.deviceInfo?.ioBuffer ?? 0) B")
                row("Frames logged", "\(store.log.count)")
                HStack {
                    Button("Disconnect") { store.link.disconnect() }
                    Button("Reconnect") { store.link.disconnect(); DispatchQueue.main.asyncAfter(deadline: .now() + 1) { store.link.connect() } }
                }
            }
            DevCard(title: "Protocol log", icon: "doc.text.magnifyingglass") {
                Text("Every AB frame this session, with timestamps and direction.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Export log…") { exportLog() }
                    Button("Clear") { store.log.removeAll() }
                }
            }
            DevCard(title: "Upload raw face file", icon: "square.and.arrow.up.on.square", level: 1) {
                Text("Send any .bin face container (from tools/face.py, the Composer's export, or elsewhere) straight to the watch.")
                    .font(.caption).foregroundStyle(.secondary)
                if let u = uploading { ProgressView(value: u) } else {
                    Button("Choose .bin…") { upload() }.disabled(!store.ready)
                }
            }
            DevCard(title: "Firmware packages", icon: "shippingbox") {
                Text("Health of the font, UI and language packs installed on the watch (PACKAGE_STATUS).").font(.caption).foregroundStyle(.secondary)
                Text(dev.packages ?? "Not read").font(.system(size: 12, design: .monospaced))
                Button("Read") { Task { await dev.loadPackages() } }.disabled(!store.ready)
            }
            DevCard(title: "Event sniffer", icon: "ear") {
                Text("Every frame the watch sends on its own — press buttons on the watch and watch them arrive.").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        if dev.sniffed.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
                        ForEach(Array(dev.sniffed.enumerated()), id: \.offset) { _, e in
                            HStack(alignment: .top) {
                                Text(e.date.formatted(date: .omitted, time: .standard)).foregroundStyle(.tertiary)
                                Text(e.text).textSelection(.enabled)
                            }.font(.system(size: 11, design: .monospaced))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 150)
                Button("Clear") { dev.sniffed = [] }.controlSize(.small)
            }
            DevCard(title: "Re-run pairing", icon: "arrow.triangle.2.circlepath") {
                Text("Re-syncs clock, settings, weather, track, world clock and stocks — what happens on connect.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Sync everything") { Task { await store.syncTime(); await store.refreshAll(); await store.extras.onConnected() } }.disabled(!store.ready)
            }
        }
    }
    func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary).frame(width: 110, alignment: .leading); Text(v).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }
    }
    func exportLog() {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        let s = store.log.map { "\(f.string(from: $0.date)) \($0.outgoing ? "→" : "←") \($0.text)" }.joined(separator: "\n")
        let p = NSSavePanel(); p.nameFieldStringValue = "OHW-11 protocol log.txt"
        if p.runModal() == .OK, let u = p.url { try? s.write(to: u, atomically: true, encoding: .utf8) }
    }
    func upload() {
        let p = NSOpenPanel(); p.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data, .data]
        guard p.runModal() == .OK, let u = p.url, let d = try? Data(contentsOf: u) else { return }
        uploading = 0
        Task {
            do { try await store.link.uploadFace([UInt8](d)) { uploading = $0 }; store.show("Face file installed", "checkmark.seal.fill") }
            catch { store.show(error.localizedDescription, "exclamationmark.triangle.fill", error: true) }
            uploading = nil
        }
    }
}


struct SportExplorer: View {
    @EnvironmentObject var store: WatchStore
    @EnvironmentObject var dev: DevStore
    @State private var mode = 9
    var body: some View {
        DevCard(title: "Sport mode explorer", icon: "figure.mixed.cardio", level: 1) {
            Text("Open the watch's sport screen in any mode number (CO FIT names 8 indoor, 9 outdoor, 10 cycling, 13 climbing). Try others to find hidden sports.")
                .font(.caption).foregroundStyle(.secondary)
            Stepper("Mode \(mode)\(SportMode(rawValue: mode).map { " · \($0.title)" } ?? "")", value: $mode, in: 0...40)
            HStack {
                Button("Start") { Task { await dev.sport(mode, 1) } }
                Button("Pause") { Task { await dev.sport(mode, 3) } }
                Button("Resume") { Task { await dev.sport(mode, 2) } }
                Button("End") { Task { await dev.sport(mode, 4) } }
            }.disabled(!store.ready)
        }
    }
}


struct DevChipTab: View {
    @EnvironmentObject var store: WatchStore
    @EnvironmentObject var chip: JieLiChip

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("JieLi RCSP channel", systemImage: "cpu.fill").font(.headline)
                        Spacer()
                        if chip.busy { ProgressView().controlSize(.small) }
                        if chip.authed {
                            Label("Authenticated", systemImage: "lock.open.fill").foregroundStyle(Color.ok).font(.callout)
                            Button("Refresh") { Task { await chip.readInfo() } }
                            Button("Close") { chip.disconnect() }
                        } else {
                            Button { Task { await chip.connect() } } label: { Label("Open channel", systemImage: "key.fill") }
                                .buttonStyle(PrimaryButtonStyle()).disabled(!store.ready || chip.busy)
                        }
                    }
                    Text("The watch's chip maker (JieLi, Zhuhai) runs its own protocol next to the SMA one. It is locked behind a challenge–response handshake: Bluetooth E1 / SAFER+ with a key baked into CO FIT's libjl_auth.so. OHW Studio answers it itself.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let e = chip.error { Text(e).font(.caption).foregroundStyle(.orange) }
                }
            }
            if chip.authed {
                HStack(alignment: .top, spacing: 14) {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Chip report").font(.headline)
                            ForEach(chip.facts) { f in
                                HStack { Text(f.name).foregroundStyle(.secondary); Spacer(); Text(f.value).font(.callout.monospaced()).textSelection(.enabled) }
                            }
                        }
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Chip clock & tones").font(.headline)
                            if let c = chip.chipClock {
                                HStack { Text("Chip RTC").foregroundStyle(.secondary); Spacer(); Text(c).font(.callout.monospaced()) }
                                Text("The JieLi side keeps its own clock, separate from the watch time the SMA protocol sets — it has never been synced.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if !chip.tones.isEmpty {
                                Text("Built-in alarm tones: " + chip.tones.joined(separator: ", ")).font(.callout)
                            }
                            Divider()
                            Text("Answered “not supported”: external-flash read/write, file browsing, device config, health data, error log. This firmware keeps its storage closed over Bluetooth.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
