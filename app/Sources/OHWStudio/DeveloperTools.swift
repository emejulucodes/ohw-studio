import Foundation
import SwiftUI
import Combine

// MARK: - Developer section engine
// Everything here talks to the watch below the level CO FIT exposes to users. Sources:
// CO FIT's hidden Developer menu (com.sma.smartv3.ui.me.Developer*), BleFactoryTest, BleBtName.
// Verified on this OHW-11: factory ENTER/GSENSOR/EXIT round-trip (tools/factory_test.py).

extension BleKey {
    static let timeZone: UInt16 = 0x0202
    static let language: UInt16 = 0x020f
    static let antiLost: UInt16 = 0x0215
    static let temperatureUnit: UInt16 = 0x021d
    static let shutdown: UInt16 = 0x0222
    static let btName: UInt16 = 0x0242
    static let deviceLanguages: UInt16 = 0x024f
    static let classicBT: UInt16 = 0x0605
    static let factoryTest: UInt16 = 0x0609
}

enum FactoryTest: UInt8, CaseIterable, Identifiable {
    case firmware = 1, ui = 2, battery = 3, gsensor = 4, touch = 5, key = 6, motor = 7, speaker = 8, microphone = 9
    case hrLeak = 10, hrPS = 11, hrBio = 12, flash = 14, rssi = 19, hrValue = 23, voltage = 26, light = 30
    var id: UInt8 { rawValue }
    var title: String {
        switch self {
        case .firmware: return "Firmware version"; case .ui: return "UI version"; case .battery: return "Battery level"
        case .gsensor: return "Accelerometer"; case .touch: return "Touch panel"; case .key: return "Buttons"
        case .motor: return "Vibration motor"; case .speaker: return "Speaker"; case .microphone: return "Microphone"
        case .hrLeak: return "HR light leak"; case .hrPS: return "HR proximity"; case .hrBio: return "HR bio sensor"
        case .flash: return "Flash memory"; case .rssi: return "Bluetooth RSSI"; case .hrValue: return "HR value"
        case .voltage: return "Battery voltage"; case .light: return "Light sensor"
        }
    }
    var icon: String {
        switch self {
        case .firmware, .ui: return "number"; case .battery, .voltage: return "battery.75percent"; case .gsensor: return "move.3d"
        case .touch: return "hand.tap"; case .key: return "button.programmable"; case .motor: return "iphone.radiowaves.left.and.right"
        case .speaker: return "speaker.wave.2"; case .microphone: return "mic"; case .hrLeak, .hrPS, .hrBio, .hrValue: return "heart.text.square"
        case .flash: return "memorychip"; case .rssi: return "antenna.radiowaves.left.and.right"; case .light: return "sun.max"
        }
    }

    /// Human-readable decode of a factory test reply ([type][payload…]).
    func describe(_ r: [UInt8]) -> String {
        let p = Array(r.dropFirst())
        func le16(_ i: Int) -> Int { p.count > i + 1 ? Int(Int16(bitPattern: UInt16(p[i]) | UInt16(p[i + 1]) << 8)) : 0 }
        func be16(_ i: Int) -> Int { p.count > i + 1 ? Int(p[i]) << 8 | Int(p[i + 1]) : 0 }
        switch self {
        case .firmware, .ui: return p.count >= 3 ? "\(p[0]).\(p[1]).\(p[2])" : hex(p)
        case .battery: return p.first.map { "\($0) %" } ?? "—"
        case .gsensor: return p.count >= 7 ? "x \(le16(1))  y \(le16(3))  z \(le16(5))" : hex(p)
        case .voltage: return p.count >= 2 ? String(format: "%.2f V", Double(be16(0)) / 10_000) : hex(p)
        case .rssi: return p.first.map { "\(Int8(bitPattern: $0)) dBm" } ?? "—"
        case .hrValue: return p.first.map { "\($0) bpm" } ?? "—"
        default: return p.isEmpty ? "OK (no data)" : (p.first == 0 ? "Pass · " : "Result · ") + hex(p)
        }
    }
}

struct LabEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let key: UInt16, flag: UInt8, payload: [UInt8]
    var reply: [UInt8]?
    var pending = true
}

struct ScanRow: Identifiable { var id: UInt16 { key }; let key: UInt16; let name: String; let data: [UInt8] }

@MainActor
final class DevStore: ObservableObject {
    unowned let store: WatchStore
    var link: WatchLink { store.link }

    @Published var enabled = UserDefaults.standard.bool(forKey: "devMode") { didSet { UserDefaults.standard.set(enabled, forKey: "devMode") } }
    @Published var allowDangerous = false

    // factory
    @Published var factoryActive = false
    @Published var hardware: [(String, String)] = []
    @Published var testResults: [FactoryTest: String] = [:]
    @Published var accel: (x: Double, y: Double, z: Double)?
    @Published var accelLive = false
    private var accelTask: Task<Void, Never>?

    // lab / scanner
    @Published var history: [LabEntry] = []
    @Published var scan: [ScanRow] = []
    @Published var scanProgress: Double?
    private var scanTask: Task<Void, Never>?

    // device
    @Published var languages: [Int] = []
    @Published var currentLanguage: Int?

    @Published var sniffed: [(date: Date, text: String)] = []
    @Published var packages: String?
    private var bag = Set<AnyCancellable>()

    init(store: WatchStore) {
        self.store = store
        store.link.events.receive(on: RunLoop.main).sink { [weak self] e in
            let t: String
            switch e {
            case .music(let c): t = "MUSIC_CONTROL \(c)"
            case .camera(let c): t = "CAMERA \(c)"
            case .findPhone(let on): t = "FIND_PHONE \(on ? "start" : "stop")"
            case .weatherRequest: t = "WEATHER request"
            case .heartRate(let v): t = "REAL_TIME_HEART_RATE \(v) bpm"
            case .other(let k, let f, let d): t = String(format: "%04X %@ flag %02X ", k, KeyCatalog.name(k), f) + hex(d, max: 80)
            }
            self?.sniffed.insert((Date(), t), at: 0)
            if (self?.sniffed.count ?? 0) > 200 { self?.sniffed.removeLast() }
        }.store(in: &bag)
    }

    func loadPackages() async {
        guard let d = await link.request(BleKey.packageStatus, BleFlag.read) else { packages = "No reply"; return }
        func st(_ v: UInt8) -> String { v == 0 ? "OK" : "status \(v)" }
        packages = d.count >= 3 ? "Font \(st(d[0])) · UI \(st(d[1])) · Language \(st(d[2])) · \(hex(Array(d.dropFirst(3))))" : hex(d)
    }

    func sport(_ mode: Int, _ state: Int) async {
        _ = await link.request(BleKey.appSportState, BleFlag.update, [UInt8(mode), UInt8(state)])
    }

    /// Keys that can brick, wipe or lock the watch, or start file streams with the wrong data.
    static let dangerous: Set<UInt16> = [0x0101, 0x0102, 0x0222, 0x0235, 0x024c, 0x0279, 0x0282, 0x0301, 0x0302]
    static func isDangerous(_ k: UInt16) -> Bool { dangerous.contains(k) || k >> 8 == 0x07 }

    // MARK: device controls
    func rename(_ name: String) async {
        let b = Array(name.utf8.prefix(29))
        let data = [UInt8(b.count)] + b + [UInt8](repeating: 0, count: 29 - b.count) + [0]
        if await link.request(BleKey.btName, BleFlag.update, data) != nil {
            store.show("Renamed to \(name). It shows up after the watch restarts or re-advertises.", "character.cursor.ibeam")
        } else { store.show("The watch didn't accept the name", "exclamationmark.triangle.fill", error: true) }
    }

    func shutdown() async {
        _ = await link.request(BleKey.shutdown, BleFlag.update, [0], timeout: 2)
        store.show("Shutdown sent — hold the side button to turn the watch back on", "power")
    }

    func setClassicBT(_ on: Bool) async {
        if await link.request(BleKey.classicBT, BleFlag.update, [on ? 1 : 0]) != nil {
            store.show(on ? "Calls & audio Bluetooth on" : "Calls & audio Bluetooth off", "headphones")
        }
    }

    func setClock(_ d: Date) async {
        if await link.request(BleKey.time, BleFlag.update, bleTime(d)) != nil {
            store.show("Watch clock set to \(d.formatted(date: .abbreviated, time: .shortened))", "clock.arrow.2.circlepath")
        }
    }

    func setTimeZone(quarters: Int) async {
        if await link.request(BleKey.timeZone, BleFlag.update, [UInt8(bitPattern: Int8(clamping: quarters))]) != nil {
            store.show("Time zone set to UTC\(quarters >= 0 ? "+" : "−")\(String(format: "%.2g", Double(abs(quarters)) / 4))", "globe")
        }
    }

    func simpleWrite(_ key: UInt16, _ v: UInt8, _ msg: String) async {
        if await link.request(key, BleFlag.update, [v]) != nil { store.show(msg, "checkmark.circle.fill") }
        else { store.show("No reply from the watch", "exclamationmark.triangle.fill", error: true) }
    }

    func loadLanguages() async {
        guard let d = await link.request(BleKey.deviceLanguages, BleFlag.read), d.count >= 6 else { return }
        currentLanguage = Int(d[0])
        let n = Int(d[5])
        languages = Array(d.dropFirst(6).prefix(n)).map(Int.init)
    }

    static let languageCodes: [Int: String] = [0: "zh", 1: "en", 2: "tr", 4: "ru", 5: "es", 6: "it", 7: "ko", 8: "pt", 9: "de", 10: "fr",
        11: "nl", 12: "pl", 13: "cs", 14: "hu", 15: "sk", 16: "ja", 17: "da", 18: "fi", 19: "no", 20: "sv", 21: "sr", 22: "th", 23: "hi",
        24: "el", 25: "zh-Hant", 26: "lt", 27: "vi", 28: "ar", 29: "id", 30: "uk", 32: "he", 33: "bn", 35: "sl", 36: "fa", 37: "ro",
        38: "bg", 39: "hr", 40: "ur", 41: "ms", 48: "jv", 49: "mr", 50: "lv", 51: "la", 53: "mn", 54: "ta", 55: "te", 56: "kn", 57: "ne",
        64: "lo", 65: "km", 67: "uz", 68: "az", 69: "ku", 70: "kk", 71: "sw", 72: "ka", 73: "zu", 80: "pt-BR", 82: "ps", 83: "ha",
        84: "is", 88: "am", 89: "tg", 96: "hy", 97: "si", 98: "mi", 99: "tk"]
    static func languageName(_ c: Int) -> String {
        guard let code = languageCodes[c] else { return "Language \(c)" }
        return Locale(identifier: "en").localizedString(forIdentifier: code) ?? code
    }

    // MARK: factory self-test
    func enterFactory() async {
        guard let r = await link.request(BleKey.factoryTest, BleFlag.update, [0x80], timeout: 4) else {
            store.show("Factory mode didn't answer", "exclamationmark.triangle.fill", error: true); return
        }
        factoryActive = true
        hardware = Self.decodeSupport(Array(r.dropFirst()))
    }

    func exitFactory() async {
        accelLive = false; accelTask?.cancel()
        _ = await link.request(BleKey.factoryTest, BleFlag.update, [0x83], timeout: 3)
        factoryActive = false
    }

    func run(_ t: FactoryTest) async {
        if !factoryActive { await enterFactory() }
        if let r = await link.request(BleKey.factoryTest, BleFlag.update, [t.rawValue], timeout: 5) {
            testResults[t] = t.describe(r)
            if t == .gsensor { updateAccel(r) }
        } else { testResults[t] = "No reply (not fitted or not supported)" }
    }

    private func updateAccel(_ r: [UInt8]) {
        guard r.count >= 8 else { return }
        func le(_ i: Int) -> Double { Double(Int16(bitPattern: UInt16(r[i]) | UInt16(r[i + 1]) << 8)) / 1024 }
        accel = (le(2), le(4), le(6))
    }

    func toggleAccelLive() {
        accelLive.toggle()
        accelTask?.cancel()
        guard accelLive else { return }
        accelTask = Task {
            if !factoryActive { await enterFactory() }
            while !Task.isCancelled && accelLive && store.ready {
                if let r = await link.request(BleKey.factoryTest, BleFlag.update, [FactoryTest.gsensor.rawValue], timeout: 1.5) {
                    updateAccel(r); testResults[.gsensor] = FactoryTest.gsensor.describe(r)
                }
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }

    static func decodeSupport(_ p: [UInt8]) -> [(String, String)] {
        var i = 0, out: [(String, String)] = []
        func u8() -> Int? { guard i < p.count else { return nil }; defer { i += 1 }; return Int(p[i]) }
        func str() -> String { guard i < p.count else { return "" }; let j = p[i...].firstIndex(of: 0) ?? p.count
            defer { i = min(p.count, j + 1) }; return String(decoding: p[i..<j], as: UTF8.self) }
        func bytes(_ n: Int) -> [UInt8] { guard i + n <= p.count else { i = p.count; return [] }; defer { i += n }; return Array(p[i..<(i + n)]) }
        func yes(_ v: Int?) -> String { v.map { $0 != 0 ? "Yes" : "No" } ?? "—" }
        out.append(("Buttons", u8().map(String.init) ?? "—"))
        out.append(("Microphone", yes(u8()))); out.append(("Speaker", yes(u8()))); out.append(("Bio (HR) sensor", yes(u8())))
        out.append(("Bio self-check", yes(u8()))); out.append(("SD card", yes(u8()))); out.append(("Compass", yes(u8())))
        out.append(("Tuya", yes(u8())))
        out.append(("Bluetooth name", str())); out.append(("Firmware flag", str()))
        let fw = bytes(3), ui = bytes(3)
        out.append(("Firmware", fw.map(String.init).joined(separator: "."))); out.append(("UI pack", ui.map(String.init).joined(separator: ".")))
        out.append(("Battery", u8().map { "\($0) %" } ?? "—"))
        let g = bytes(7)
        if g.count == 7 {
            func le(_ k: Int) -> Int { Int(Int16(bitPattern: UInt16(g[k]) | UInt16(g[k + 1]) << 8)) }
            out.append(("Accelerometer", "x \(le(1)) · y \(le(3)) · z \(le(5))"))
        }
        out.append(("Flash", u8().map { $0 == 0 ? "OK" : "Error \($0)" } ?? "—"))
        out.append(("RSSI", u8().map { "\(Int8(bitPattern: UInt8($0))) dBm" } ?? "—"))
        if i + 1 < p.count {
            let n = Int(p[i]) << 8 | Int(p[i + 1]); i += 2
            out.append(("Hardware IDs", hex(bytes(n), max: 64)))
        }
        if let v = u8() { out.append(("GoMore", "\(v)")) }
        if i + 1 < p.count { out.append(("Voltage", String(format: "%.2f V", Double(Int(p[i]) << 8 | Int(p[i + 1])) / 10_000))); i += 2 }
        return out
    }

    // MARK: command lab
    func send(key: UInt16, flag: UInt8, payload: [UInt8]) async {
        var e = LabEntry(key: key, flag: flag, payload: payload)
        history.insert(e, at: 0)
        let r = await link.request(key, flag, payload, timeout: 4)
        e.reply = r; e.pending = false
        if let i = history.firstIndex(where: { $0.id == e.id }) { history[i] = e }
    }

    static func parseHex(_ s: String) -> [UInt8]? {
        let clean = s.lowercased().filter { "0123456789abcdef".contains($0) }
        guard clean.count % 2 == 0 else { return nil }
        var out: [UInt8] = [], idx = clean.startIndex
        while idx < clean.endIndex {
            let n = clean.index(idx, offsetBy: 2)
            guard let b = UInt8(clean[idx..<n], radix: 16) else { return nil }
            out.append(b); idx = n
        }
        return out
    }

    // MARK: scanner
    func startScan() {
        scanTask?.cancel()
        scan = []
        let keys = KeyCatalog.all.filter { !Self.isDangerous($0.key) && $0.key != 0x0609 && $0.key != 0x0000 && $0.key != 0xffff }
        scanTask = Task {
            for (n, k) in keys.enumerated() {
                guard !Task.isCancelled, store.ready else { break }
                scanProgress = Double(n) / Double(keys.count)
                if let d = await link.request(k.key, BleFlag.read, timeout: 1.2), !d.isEmpty {
                    scan.append(ScanRow(key: k.key, name: k.name, data: d))
                }
            }
            scanProgress = nil
        }
    }
    func stopScan() { scanTask?.cancel(); scanProgress = nil }

    // MARK: capabilities
    var capabilities: [(name: String, value: String, support: Bool)] {
        let raw = Array(link.rawDeviceInfo.dropFirst())
        guard !raw.isEmpty else { return [] }
        var i = 0, out: [(String, String, Bool)] = []
        for f in DeviceInfoSpec.fields {
            guard i < raw.count else { out.append((f.name, "—", f.support)); continue }
            switch f.type {
            case "i32": out.append((f.name, hex(Array(raw[i..<min(raw.count, i + 4)])), false)); i += 4
            case "bytes0", "str0":
                let j = raw[i...].firstIndex(of: 0) ?? raw.count
                let v = Array(raw[i..<j]); i = min(raw.count, j + 1)
                out.append((f.name, f.type == "str0" ? String(decoding: v, as: UTF8.self) : hex(v), false))
            case "u16": out.append((f.name, "\(i + 1 < raw.count ? Int(raw[i]) << 8 | Int(raw[i + 1]) : 0)", false)); i += 2
            default: out.append((f.name, "\(raw[i])", f.support)); i += 1
            }
        }
        return out
    }
}
