import Foundation
import SwiftUI

// MARK: - Features CO FIT has (or hides) that OHW Studio adds.
// Verified on this OHW-11 (2026-11-05): alarms, world clock and stocks are stored and shown by the
// watch; the reminder/health settings below all read back with real values (captures/probe_all.txt).

extension BleKey {
    static let alarm: UInt16 = 0x0210
    static let unitSet: UInt16 = 0x0211
    static let hrMonitoring: UInt16 = 0x0216
    static let dateFormat: UInt16 = 0x021e
    static let drinkWater: UInt16 = 0x0221
    static let spo2Set: UInt16 = 0x0225
    static let washSet: UInt16 = 0x0226
    static let caloriesGoal: UInt16 = 0x0239
    static let distanceGoal: UInt16 = 0x023a
    static let sleepGoal: UInt16 = 0x023b
    static let batteryUsage: UInt16 = 0x0277
    static let worldClock: UInt16 = 0x0407
    static let stock: UInt16 = 0x0408
    static let log: UInt16 = 0x050b
}

extension BleFlag {
    static let delete: UInt8 = 0x30
}

/// Mon = bit 0 … Sun = bit 6 (BleRepeat: MONDAY = 1, SUNDAY = 64)
struct Weekdays: OptionSet, Codable, Hashable {
    let rawValue: Int
    static let mon = Weekdays(rawValue: 1), tue = Weekdays(rawValue: 2), wed = Weekdays(rawValue: 4), thu = Weekdays(rawValue: 8)
    static let fri = Weekdays(rawValue: 16), sat = Weekdays(rawValue: 32), sun = Weekdays(rawValue: 64)
    static let all: Weekdays = [.mon, .tue, .wed, .thu, .fri, .sat, .sun]
    static let workdays: Weekdays = [.mon, .tue, .wed, .thu, .fri]
    static let weekend: Weekdays = [.sat, .sun]
    static let ordered: [(Weekdays, String)] = [(.mon, "M"), (.tue, "T"), (.wed, "W"), (.thu, "T"), (.fri, "F"), (.sat, "S"), (.sun, "S")]

    var summary: String {
        if self == .all { return "Every day" }
        if self == .workdays { return "Weekdays" }
        if self == .weekend { return "Weekends" }
        if isEmpty { return "Once" }
        let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        return (0..<7).filter { rawValue & (1 << $0) != 0 }.map { names[$0] }.joined(separator: " ")
    }
}

struct WatchAlarm: Identifiable, Codable, Hashable {
    var id = UUID()
    var enabled = true
    var hour = 7, minute = 0
    var repeatDays: Weekdays = .workdays
    var label = "Alarm"
    var date = Date()          // used when repeatDays is empty (one-off)

    func encode(_ index: Int) -> [UInt8] {
        // a one-off alarm fires at its date; keep it in the future
        var d = date
        let cal = Calendar.current
        var target = cal.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
        if repeatDays.isEmpty {
            target = cal.date(bySettingHour: hour, minute: minute, second: 0, of: d) ?? d
            if target < Date() { target = cal.date(byAdding: .day, value: 1, to: target) ?? target }
        }
        d = target
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return [UInt8(index), UInt8((enabled ? 0x80 : 0) | (repeatDays.rawValue & 0x7f)),
                UInt8(clamping: (c.year ?? 2026) - 2000), UInt8(c.month ?? 1), UInt8(c.day ?? 1),
                UInt8(hour), UInt8(minute)] + fixedString(label, 21)
    }

    static func decode(_ b: [UInt8]) -> [WatchAlarm] {
        stride(from: 0, to: b.count - 27, by: 28).map { o in
            var a = WatchAlarm()
            a.enabled = b[o + 1] & 0x80 != 0
            a.repeatDays = Weekdays(rawValue: Int(b[o + 1] & 0x7f))
            var c = DateComponents(); c.year = 2000 + Int(b[o + 2]); c.month = Int(b[o + 3]); c.day = Int(b[o + 4])
            a.hour = Int(b[o + 5]); a.minute = Int(b[o + 6])
            a.date = Calendar.current.date(from: c) ?? Date()
            a.label = String(decoding: b[(o + 7)..<(o + 28)].prefix { $0 != 0 }, as: UTF8.self)
            return a
        }
    }
}

struct WorldCity: Identifiable, Codable, Hashable {
    var id: String { tz }
    var name: String
    var tz: String
    var offsetQuarters: Int {
        (TimeZone(identifier: tz)?.secondsFromGMT(for: Date()) ?? 0) / 900
    }
    static func encode(_ index: Int, name: String, quarters: Int, local: Bool) -> [UInt8] {
        [UInt8((local ? 0x80 : 0) | (index & 0x7f)), UInt8(bitPattern: Int8(clamping: quarters)), 0, 0] + fixedString(name, 62) + [0, 0]
    }
    static var catalog: [WorldCity] {
        TimeZone.knownTimeZoneIdentifiers.compactMap { id in
            guard let city = id.split(separator: "/").last, id.contains("/") else { return nil }
            return WorldCity(name: city.replacingOccurrences(of: "_", with: " "), tz: id)
        }.sorted { $0.name < $1.name }
    }
}

struct StockQuote: Identifiable, Codable, Hashable {
    var id: String { symbol }
    var symbol: String
    var name: String = ""
    var price: Double = 0
    var change: Double = 0
    var percent: Double = 0
    var updated: Date? = nil

    func encode(_ index: Int, greenUp: Bool) -> [UInt8] {
        func f(_ v: Double) -> [UInt8] { withUnsafeBytes(of: Float(v).bitPattern.littleEndian) { Array($0) } }
        let dp = price >= 1000 ? 1 : 2
        let code = symbol.replacingOccurrences(of: "-USD", with: "")
        var out: [UInt8] = [UInt8(index), greenUp ? 0 : 1, UInt8(2 << 4 | dp), 0x02]
        out += fixedString(code, 62)
        out += [0, 0]
        out += f(price); out += f(change); out += f(percent); out += f(0)
        return out
    }
}

/// Repeating reminder (sedentary / drink water / hand-wash): [en<<7 | repeat][sh][sm][eh][em][interval min]
struct ReminderSetting: Hashable {
    var enabled = false
    var days: Weekdays = .all
    var start = 8 * 60, end = 18 * 60
    var interval = 60

    init() {}
    init?(_ b: [UInt8]?) {
        guard let b, b.count >= 6 else { return nil }
        enabled = b[0] & 0x80 != 0; days = Weekdays(rawValue: Int(b[0] & 0x7f))
        start = Int(b[1]) * 60 + Int(b[2]); end = Int(b[3]) * 60 + Int(b[4]); interval = Int(b[5])
    }
    var bytes: [UInt8] {
        [UInt8((enabled ? 0x80 : 0) | (days.rawValue & 0x7f)), UInt8(start / 60), UInt8(start % 60),
         UInt8(end / 60), UInt8(end % 60), UInt8(clamping: interval)]
    }
}

/// BleTimeRange [enabled][sh][sm][eh][em] (+ optional interval byte)
struct RangeSetting: Hashable {
    var enabled = false
    var start = 0, end = 23 * 60 + 59
    var interval: Int? = nil

    init() {}
    init?(_ b: [UInt8]?, interval hasInterval: Bool) {
        guard let b, b.count >= (hasInterval ? 6 : 5) else { return nil }
        enabled = b[0] != 0
        start = Int(b[1]) * 60 + Int(b[2]); end = Int(b[3]) * 60 + Int(b[4])
        if hasInterval { interval = Int(b[5]) }
    }
    var bytes: [UInt8] {
        [enabled ? 1 : 0, UInt8(start / 60), UInt8(start % 60), UInt8(end / 60), UInt8(end % 60)] + (interval.map { [UInt8(clamping: max(1, $0))] } ?? [])
    }
}

struct RawSetting: Identifiable, Hashable { var id: UInt16 { key }; let key: UInt16; let name: String; let hex: String }

// MARK: - store

@MainActor
final class ExtrasStore: ObservableObject {
    unowned let store: WatchStore
    var link: WatchLink { store.link }

    @Published var alarms: [WatchAlarm] = []
    @Published var cycle: CycleSettings?
    @Published var alarmsLoaded = false
    @Published var cities: [WorldCity] = ExtrasStore.load("worldCities") ?? [WorldCity(name: "London", tz: "Europe/London"),
                                                                              WorldCity(name: "New York", tz: "America/New_York"),
                                                                              WorldCity(name: "Tokyo", tz: "Asia/Tokyo")]
    @Published var stocks: [StockQuote] = ExtrasStore.load("stockList") ?? ["AAPL", "TSLA", "NVDA", "BTC-USD"].map { StockQuote(symbol: $0) }
    @Published var stockAuto = UserDefaults.standard.object(forKey: "stockAuto") as? Bool ?? true { didSet { UserDefaults.standard.set(stockAuto, forKey: "stockAuto") } }
    @Published var greenUp = UserDefaults.standard.object(forKey: "stockGreenUp") as? Bool ?? true { didSet { UserDefaults.standard.set(greenUp, forKey: "stockGreenUp") } }
    @Published var stocksUpdated: Date?

    @Published var sedentary: ReminderSetting?
    @Published var drink: ReminderSetting?
    @Published var wash: ReminderSetting?
    @Published var hrMonitor: RangeSetting?
    @Published var spo2: RangeSetting?
    @Published var raiseToWake: RangeSetting?
    @Published var dndEnabled: Bool?
    @Published var dnd: RangeSetting?
    @Published var calorieGoal: Int?      // kcal
    @Published var distanceGoal: Double?  // km
    @Published var sleepGoal: Int?        // minutes
    @Published var metric: Bool?
    @Published var dateFormat: Int?
    @Published var loadingSettings = false

    @Published var body: BodyProfile?
    @Published var sos: SOSContact?
    @Published var battery: BatteryUsage?
    @Published var spo2History: [VitalSample] = []
    @Published var stressHistory: [VitalSample] = []
    @Published var bpHistory: [VitalSample] = []
    @Published var watchWorkouts: [WorkoutRecord] = []

    @Published var log: [String] = []
    @Published var raw: [RawSetting] = []
    @Published var batteryUsage: String?

    private var stockTimer: Timer?

    init(store: WatchStore) {
        self.store = store
        stockTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { guard let self, self.stockAuto else { return }; Task { await self.refreshStocks(push: true) } }
        }
    }

    static func load<T: Decodable>(_ k: String) -> T? {
        UserDefaults.standard.data(forKey: k).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
    static func save<T: Encodable>(_ v: T, _ k: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(v), forKey: k)
    }

    /// Called after every (re)connect.
    func onConnected() async {
        await loadAlarms()
        await pushWorldClock(silent: true)
        if stockAuto { await refreshStocks(push: true) }
    }

    // MARK: list keys: delete-all (id 255) then create each item with ids 0…n
    private func replaceList(_ key: UInt16, _ items: [[UInt8]]) async -> Bool {
        guard store.ready else { return false }
        guard await link.request(key, BleFlag.delete, [0xff]) != nil else { return false }
        for it in items { guard await link.request(key, BleFlag.create, it) != nil else { return false } }
        return true
    }

    // MARK: alarms
    func loadAlarms() async {
        guard store.ready else { return }
        let b = await link.collect(BleKey.alarm, timeout: 4)
        alarms = WatchAlarm.decode(b)
        alarmsLoaded = true
    }

    func saveAlarms() async {
        let items = alarms.prefix(10).enumerated().map { $0.element.encode($0.offset) }
        if await replaceList(BleKey.alarm, Array(items)) {
            store.show(alarms.isEmpty ? "Alarms cleared" : "\(alarms.count) alarm\(alarms.count == 1 ? "" : "s") on your watch", "alarm.fill")
        } else { store.show("Couldn't update alarms", "exclamationmark.triangle.fill", error: true) }
    }

    // MARK: world clock
    func pushWorldClock(silent: Bool = false) async {
        Self.save(cities, "worldCities")
        let here = TimeZone.current
        let localName = here.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? "Local"
        var items = [WorldCity.encode(0, name: localName, quarters: here.secondsFromGMT() / 900, local: true)]
        for (i, c) in cities.prefix(7).enumerated() { items.append(WorldCity.encode(i + 1, name: c.name, quarters: c.offsetQuarters, local: false)) }
        let ok = await replaceList(BleKey.worldClock, items)
        if !silent { store.show(ok ? "World clock updated" : "Couldn't update world clock", ok ? "globe" : "exclamationmark.triangle.fill", error: !ok) }
    }

    // MARK: stocks
    func refreshStocks(push: Bool) async {
        Self.save(stocks.map { StockQuote(symbol: $0.symbol) }, "stockList")
        var out: [StockQuote] = []
        for s in stocks { out.append(await StockService.quote(s.symbol) ?? s) }
        stocks = out
        stocksUpdated = Date()
        if push { await pushStocks(silent: true) }
    }

    func pushStocks(silent: Bool = false) async {
        let items = stocks.prefix(8).enumerated().map { $0.element.encode($0.offset, greenUp: greenUp) }
        let ok = await replaceList(BleKey.stock, Array(items))
        if !silent { store.show(ok ? "Stocks sent to your watch" : "Couldn't send stocks", ok ? "chart.line.uptrend.xyaxis" : "exclamationmark.triangle.fill", error: !ok) }
    }

    // MARK: wellness & system settings
    func loadSettings() async {
        guard store.ready, !loadingSettings else { return }
        loadingSettings = true; defer { loadingSettings = false }
        sedentary = ReminderSetting(await link.request(BleKey.sedentary, BleFlag.read))
        drink = ReminderSetting(await link.request(BleKey.drinkWater, BleFlag.read))
        wash = ReminderSetting(await link.request(BleKey.washSet, BleFlag.read))
        hrMonitor = RangeSetting(await link.request(BleKey.hrMonitoring, BleFlag.read), interval: true)
        spo2 = RangeSetting(await link.request(BleKey.spo2Set, BleFlag.read), interval: true)
        raiseToWake = RangeSetting(await link.request(BleKey.gestureWake, BleFlag.read), interval: false)
        if let d = await link.request(BleKey.noDisturb, BleFlag.read), d.count >= 6 {
            dndEnabled = d[0] != 0; dnd = RangeSetting(Array(d[1...]), interval: false)
        }
        if let v = await link.request(BleKey.caloriesGoal, BleFlag.read), v.count >= 4 { calorieGoal = readBE32(v, 0) / 1000 }
        if let v = await link.request(BleKey.distanceGoal, BleFlag.read), v.count >= 4 { distanceGoal = Double(readBE32(v, 0)) / 1000 }
        if let v = await link.request(BleKey.sleepGoal, BleFlag.read), v.count >= 2 { sleepGoal = Int(v[0]) << 8 | Int(v[1]) }
        if let v = await link.request(BleKey.unitSet, BleFlag.read)?.first { metric = v == 0 }
        if let v = await link.request(BleKey.dateFormat, BleFlag.read)?.first { dateFormat = Int(v) }
        if let v = await link.request(0x021a, BleFlag.read) { cycle = CycleSettings(v) }
    }

    func loadCycle() async {
        guard store.ready, let v = await link.request(0x021a, BleFlag.read) else { return }
        cycle = CycleSettings(v)
    }
    func setCycle(_ c: CycleSettings) async {
        cycle = c
        await write(0x021a, c.bytes, c.enabled ? "Cycle tracking updated" : "Cycle tracking off", "drop.circle.fill")
    }

    func loadBodyAndSafety() async {
        guard store.ready else { return }
        body = BodyProfile(await link.request(BleKey.userProfile, BleFlag.read) ?? [])
        sos = SOSContact(await link.request(BleKey.sosSet, BleFlag.read) ?? [])
    }
    func setBody(_ b: BodyProfile) async { body = b; await write(BleKey.userProfile, b.bytes, "Body profile updated", "person.fill") }
    func setSOS(_ s: SOSContact) async { sos = s; await write(BleKey.sosSet, s.bytes, s.enabled ? "SOS contact saved" : "SOS turned off", "sos") }

    func loadBattery() async {
        guard store.ready, let b = await link.request(BleKey.batteryUsage, BleFlag.read) else { return }
        battery = BatteryUsage(b)
    }

    /// SpO₂ / stress / blood pressure ([time BE32][value…], 6 B) and watch workouts (128 B)
    func loadVitals() async {
        guard store.ready else { return }
        func six(_ k: UInt16, two: Bool = false) async -> [VitalSample] {
            let b = await link.collect(k, timeout: 4)
            return stride(from: 0, to: b.count - 5, by: 6).compactMap { o in
                let v = Int(b[o + 4]); guard v > 0 else { return nil }
                return VitalSample(date: dateFrom2000(readBE32(b, o)), value: v, value2: two ? Int(b[o + 5]) : 0)
            }.sorted { $0.date < $1.date }
        }
        spo2History = await six(BleKey.bloodOxygen)
        stressHistory = await six(BleKey.stress)
        bpHistory = await six(BleKey.bloodPressure, two: true)
        let w = await link.collect(BleKey.workout2, timeout: 4)
        watchWorkouts = stride(from: 0, to: w.count - 127, by: 128).map { o in
            let s = dateFrom2000(readBE32(w, o)), e = dateFrom2000(readBE32(w, o + 4))
            let dur = Int(w[o + 8]) << 8 | Int(w[o + 9])
            return WorkoutRecord(start: s, end: e, mode: Int(w[o + 15]), seconds: dur, meters: Double(readBE32(w, o + 20)),
                                 kcal: Double(readBE32(w, o + 24)) / 1000, steps: readBE32(w, o + 16),
                                 avgHR: Int(w[o + 36]), maxHR: Int(w[o + 37]), source: "watch")
        }
    }

    func write(_ key: UInt16, _ data: [UInt8], _ msg: String, _ icon: String) async {
        guard store.ready else { return }
        if await link.request(key, BleFlag.update, data) != nil { store.show(msg, icon) }
        else { store.show("The watch didn't answer", "exclamationmark.triangle.fill", error: true) }
    }

    func setSedentary(_ r: ReminderSetting) async { sedentary = r; await write(BleKey.sedentary, r.bytes, "Move reminder updated", "figure.walk.motion") }
    func setDrink(_ r: ReminderSetting) async { drink = r; await write(BleKey.drinkWater, r.bytes, "Water reminder updated", "drop.fill") }
    func setWash(_ r: ReminderSetting) async { wash = r; await write(BleKey.washSet, r.bytes, "Hand-wash reminder updated", "hands.sparkles.fill") }
    func setHR(_ r: RangeSetting) async { hrMonitor = r; await write(BleKey.hrMonitoring, r.bytes, "Heart-rate monitoring updated", "heart.fill") }
    func setSpO2(_ r: RangeSetting) async { spo2 = r; await write(BleKey.spo2Set, r.bytes, "Blood-oxygen schedule updated", "lungs.fill") }
    func setWake(_ r: RangeSetting) async { raiseToWake = r; await write(BleKey.gestureWake, r.bytes, "Raise to wake updated", "hand.raised.fill") }
    func setDND(_ on: Bool, _ r: RangeSetting) async {
        dndEnabled = on; dnd = r
        var range = r; range.enabled = on
        await write(BleKey.noDisturb, [on ? 1 : 0] + range.bytes + [UInt8](repeating: 0, count: 10), "Do Not Disturb updated", "moon.fill")
    }
    func setCalorieGoal(_ v: Int) async { calorieGoal = v; await write(BleKey.caloriesGoal, be32(v * 1000), "Calorie goal set to \(v) kcal", "flame.fill") }
    func setDistanceGoal(_ v: Double) async { distanceGoal = v; await write(BleKey.distanceGoal, be32(Int(v * 1000)), "Distance goal set to \(v.formatted()) km", "location.fill") }
    func setSleepGoal(_ m: Int) async { sleepGoal = m; await write(BleKey.sleepGoal, [UInt8(m >> 8), UInt8(m & 0xff)], "Sleep goal set to \(m / 60) h \(m % 60) min", "bed.double.fill") }
    func setMetric(_ v: Bool) async { metric = v; await write(BleKey.unitSet, [v ? 0 : 1], v ? "Metric units" : "Imperial units", "ruler") }
    func setHour24(_ v: Bool) async {
        store.settings.hour24 = v; await write(BleKey.hourSystem, [v ? 0 : 1], v ? "24-hour clock" : "12-hour clock", "clock")
    }
    func setVibration(_ v: Bool) async {
        store.settings.vibration = v; await write(BleKey.vibration, [v ? 1 : 0], v ? "Vibration on" : "Vibration off", "iphone.radiowaves.left.and.right")
    }

    // MARK: internals
    func loadLog() async {
        guard store.ready else { return }
        let b = await link.collect(BleKey.log, timeout: 6)
        log = b.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.filter { !$0.isEmpty }.reversed()
        if let u = await link.request(BleKey.batteryUsage, BleFlag.read) { batteryUsage = u.map { String(format: "%02x", $0) }.joined() }
    }

    static let readable: [(UInt16, String)] = [
        (0x0202, "TIME_ZONE"), (0x0203, "POWER"), (0x0204, "FIRMWARE_VERSION"), (0x0206, "USER_PROFILE"), (0x0207, "STEP_GOAL"),
        (0x0208, "BACK_LIGHT"), (0x0209, "SEDENTARINESS"), (0x020a, "NO_DISTURB_RANGE"), (0x020b, "VIBRATION"), (0x020c, "GESTURE_WAKE"),
        (0x020e, "HOUR_SYSTEM"), (0x020f, "LANGUAGE"), (0x0210, "ALARM"), (0x0211, "UNIT_SET"), (0x0214, "NOTIFICATION_REMINDER"),
        (0x0215, "ANTI_LOST"), (0x0216, "HR_MONITORING"), (0x0217, "UI_PACK_VERSION"), (0x0218, "LANGUAGE_PACK_VERSION"),
        (0x0219, "SLEEP_QUALITY"), (0x021e, "DATE_FORMAT"), (0x0221, "DRINK_WATER"), (0x0225, "BLOOD_OXYGEN_SET"), (0x0226, "WASH_SET"),
        (0x0239, "CALORIES_GOAL"), (0x023a, "DISTANCE_GOAL"), (0x023b, "SLEEP_GOAL"), (0x023e, "DEVICE_INFO"), (0x0241, "STANDBY_SET"),
        (0x0249, "PACKAGE_STATUS"), (0x024f, "DEVICE_LANGUAGES"), (0x0260, "SCREEN_BRIGHTNESS"), (0x0270, "WEAR_WAY"),
        (0x0277, "BATTERY_USAGE"), (0x021a, "GIRL_CARE"), (0x026c, "GIRL_CARE_MONTHLY"), (0x021b, "TEMPERATURE_DETECTING"), (0x021d, "TEMPERATURE_UNIT"),
        (0x0263, "EARPHONE_CALL"), (0x02fe, "RAW_SLEEP"), (0x0213, "FIND_PHONE"), (0x0228, "IBEACON_SET"), (0x0229, "MAC_QRCODE"), (0x0236, "REALTIME_MEASUREMENT"), (0x0402, "MUSIC_CONTROL"), (0x0407, "WORLD_CLOCK"), (0x0408, "STOCK"), (0x0605, "CLASSIC_BT_STATE"),
    ]

    func loadRaw() async {
        guard store.ready else { return }
        var out: [RawSetting] = []
        for (k, n) in Self.readable {
            let v = await link.request(k, BleFlag.read, timeout: 2) ?? []
            out.append(RawSetting(key: k, name: n, hex: v.map { String(format: "%02x", $0) }.joined(separator: " ")))
            raw = out
        }
    }
}

// MARK: - live quotes (Yahoo Finance chart endpoint, no key needed)

enum StockService {
    static func quote(_ symbol: String) async -> StockQuote? {
        let s = symbol.uppercased().addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(s)?range=1d&interval=1d") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Mozilla/5.0 (Macintosh) OHWStudio", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chart = obj["chart"] as? [String: Any], let res = (chart["result"] as? [[String: Any]])?.first,
              let meta = res["meta"] as? [String: Any],
              let price = meta["regularMarketPrice"] as? Double else { return nil }
        let prev = (meta["chartPreviousClose"] as? Double) ?? (meta["previousClose"] as? Double) ?? price
        let name = (meta["shortName"] as? String) ?? (meta["longName"] as? String) ?? symbol.uppercased()
        return StockQuote(symbol: symbol.uppercased(), name: name, price: price, change: price - prev,
                          percent: prev != 0 ? (price - prev) / prev * 100 : 0, updated: Date())
    }
}


/// GIRL_CARE 0x021A (BleGirlCareSettings, 10 B): [reminder<<7 | enabled][hh][mm][period-advance days][ovulation-advance days]
/// [yy-2000][mo][dd last period start][period length][cycle length]. Hidden on the OHW-11: the device-info flags don't
/// advertise it, but writing enabled=1 adds the watch's cycle screen and its reminders (verified 2026-11-05).
struct CycleSettings: Equatable {
    var enabled = false, reminders = true
    var hour = 20, minute = 0
    var periodAdvance = 2, ovulationAdvance = 3
    var lastStart = Date()
    var periodLength = 5, cycleLength = 28

    init() {}
    init?(_ d: [UInt8]) {
        guard d.count >= 10 else { return nil }
        reminders = d[0] & 0x80 != 0; enabled = d[0] & 0x01 != 0
        hour = Int(d[1]); minute = Int(d[2]); periodAdvance = Int(d[3]); ovulationAdvance = Int(d[4])
        lastStart = Calendar.current.date(from: DateComponents(year: 2000 + Int(d[5]), month: max(1, Int(d[6])), day: max(1, Int(d[7])))) ?? Date()
        periodLength = max(1, Int(d[8])); cycleLength = max(15, Int(d[9]))
    }
    var bytes: [UInt8] {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: lastStart)
        return [(reminders ? 0x80 : 0) | (enabled ? 1 : 0), UInt8(hour), UInt8(minute), UInt8(periodAdvance), UInt8(ovulationAdvance),
                UInt8(max(0, (c.year ?? 2026) - 2000)), UInt8(c.month ?? 1), UInt8(c.day ?? 1), UInt8(periodLength), UInt8(cycleLength)]
    }
    /// Next period start on or after today.
    var nextPeriod: Date {
        let cal = Calendar.current; var d = cal.startOfDay(for: lastStart); let today = cal.startOfDay(for: Date())
        while d < today { d = cal.date(byAdding: .day, value: cycleLength, to: d)! }
        return d
    }
    var ovulation: Date { Calendar.current.date(byAdding: .day, value: -14, to: nextPeriod)! }
    var fertileStart: Date { Calendar.current.date(byAdding: .day, value: -5, to: ovulation)! }
}
