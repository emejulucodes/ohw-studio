import Foundation
import SwiftUI
import Combine

// MARK: - Second research round (2026-11-05)
// Verified on the OHW-11: APP_SPORT_STATE 0x0604 [mode][state] opens a live workout screen on the watch,
// and APP_SPORT_DATA 0x0223 (32 B, little-endian) updates its numbers every second; the watch pushes
// REAL_TIME_HEART_RATE 0x0224 frames during the session. BATTERY_USAGE / USER_PROFILE / SOS_SET decode
// with CO FIT's entity layouts.

extension BleKey {
    static let userProfile: UInt16 = 0x0206
    static let sosSet: UInt16 = 0x024e
    static let appSportData: UInt16 = 0x0223
    static let appSportState: UInt16 = 0x0604
    static let bloodPressure: UInt16 = 0x0504
    static let stress: UInt16 = 0x050d
    static let workout2: UInt16 = 0x050e
    static let sleepQuality: UInt16 = 0x0219
    static let packageStatus: UInt16 = 0x0249
}

private func le32(_ b: [UInt8], _ i: Int) -> Int {
    guard b.count >= i + 4 else { return 0 }
    return Int(Int32(bitPattern: UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24))
}
private func le16(_ b: [UInt8], _ i: Int) -> Int { b.count >= i + 2 ? Int(b[i]) | Int(b[i + 1]) << 8 : 0 }
private func f32le(_ b: [UInt8], _ i: Int) -> Double {
    guard b.count >= i + 4 else { return 0 }
    return Double(Float(bitPattern: UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24))
}
private func f32bytes(_ v: Double) -> [UInt8] { withUnsafeBytes(of: Float(v).bitPattern.littleEndian) { Array($0) } }

// MARK: battery usage (BleBatteryUsage, 52 B)

struct BatteryUsage {
    struct Record { let date: Date?; let volts: Double }
    var total = 0, screen = 0, talk = 0, speaker = 0, sport = 0, vibration = 0, idle = 0   // seconds
    var lastBoot: Record?, lastShutdown: Record?, latest: Record?

    init?(_ b: [UInt8]) {
        guard b.count >= 28 else { return nil }
        total = le32(b, 0); screen = le32(b, 4); talk = le32(b, 8); speaker = le32(b, 12)
        sport = le32(b, 16); vibration = le32(b, 20); idle = le32(b, 24)
        func rec(_ o: Int) -> Record? {
            guard b.count >= o + 8 else { return nil }
            var c = DateComponents(); c.year = 2000 + Int(b[o]); c.month = Int(b[o + 1]); c.day = Int(b[o + 2])
            c.hour = Int(b[o + 3]); c.minute = Int(b[o + 4]); c.second = Int(b[o + 5])
            return Record(date: Calendar.current.date(from: c), volts: Double(le16(b, o + 6)) / 10_000)
        }
        lastBoot = rec(28); lastShutdown = rec(36); latest = rec(44)
    }
    var screenShare: Double { total > 0 ? Double(screen) / Double(total) : 0 }
    static func hm(_ s: Int) -> String { s >= 3600 ? "\(s / 3600) h \(s % 3600 / 60) min" : s >= 60 ? "\(s / 60) min" : "\(s) s" }
}

// MARK: body profile (BleUserProfile, 15 B)

struct BodyProfile: Equatable {
    var metric = true
    var male = true
    var age = 30
    var heightCm = 170.0
    var weightKg = 70.0
    var userId = 0

    init() {}
    init?(_ b: [UInt8]) {
        guard b.count >= 11 else { return nil }
        metric = b[0] == 0; male = b[1] == 1; age = Int(b[2])
        heightCm = f32le(b, 3); weightKg = f32le(b, 7); userId = le32(b, 11)
    }
    var bytes: [UInt8] {
        // this watch stores the 11-byte form (no user id)
        [metric ? 0 : 1, male ? 1 : 0, UInt8(clamping: age)] + f32bytes(heightCm) + f32bytes(weightKg)
    }
}

// MARK: SOS contact (BleSOSSettings, 20 B)

struct SOSContact: Equatable {
    var enabled = false
    var phone = ""
    init() {}
    init?(_ b: [UInt8]) {
        guard b.count >= 2 else { return nil }
        enabled = b[0] != 0
        let n = min(Int(b[1]), b.count - 2)
        phone = String(decoding: b[2..<(2 + n)], as: UTF8.self)
    }
    var bytes: [UInt8] {
        let p = Array(phone.utf8.prefix(18))
        return [enabled ? 1 : 0, UInt8(p.count)] + p + [UInt8](repeating: 0, count: 18 - p.count)
    }
}

// MARK: health histories

struct VitalSample: Identifiable { let id = UUID(); let date: Date; let value: Int; var value2: Int = 0 }

struct WorkoutRecord: Identifiable, Codable {
    var id = UUID()
    var start: Date, end: Date
    var mode: Int
    var seconds: Int
    var meters: Double
    var kcal: Double
    var steps: Int
    var avgHR: Int, maxHR: Int
    var source: String       // "watch" or "mac"
}

// MARK: - workouts driven from the Mac

enum SportMode: Int, CaseIterable, Identifiable {
    case outdoorRun = 9, indoorRun = 8, cycling = 10, climbing = 13
    var id: Int { rawValue }
    var title: String {
        switch self { case .outdoorRun: return "Outdoor run"; case .indoorRun: return "Treadmill"; case .cycling: return "Cycling"; case .climbing: return "Climbing" }
    }
    var icon: String {
        switch self { case .outdoorRun: return "figure.run"; case .indoorRun: return "figure.run.treadmill"; case .cycling: return "figure.outdoor.cycle"; case .climbing: return "figure.climbing" }
    }
    var defaultSpeed: Double { switch self { case .cycling: return 22; case .climbing: return 3; default: return 10 } }
    var defaultCadence: Int { switch self { case .cycling: return 0; case .climbing: return 90; default: return 165 } }
    /// rough MET at the default speed, scaled with speed
    func met(_ kmh: Double) -> Double {
        switch self {
        case .cycling: return max(4, kmh * 0.36)
        case .climbing: return 8
        default: return max(3, kmh * 1.0)
        }
    }
}

@MainActor
final class WorkoutStore: ObservableObject {
    enum Phase { case idle, running, paused }
    unowned let store: WatchStore
    var link: WatchLink { store.link }

    @Published var mode: SportMode = .outdoorRun
    @Published var phase: Phase = .idle
    @Published var speedKmh = 10.0
    @Published var cadence = 165
    @Published var elapsed = 0
    @Published var meters = 0.0
    @Published var kcal = 0.0
    @Published var steps = 0.0
    @Published var hr: [VitalSample] = []
    @Published var history: [WorkoutRecord] = ExtrasStore.load("workoutHistory") ?? []
    private var started = Date()
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()

    init(store: WatchStore) {
        self.store = store
        store.link.events.receive(on: RunLoop.main).sink { [weak self] e in
            guard let self, self.phase != .idle, case .heartRate(let v) = e else { return }
            self.hr.append(VitalSample(date: Date(), value: v))
        }.store(in: &bag)
    }

    var weight: Double { store.extras.body?.weightKg ?? 70 }
    var paceSecPerKm: Int { speedKmh > 0.1 ? Int(3600 / speedKmh) : 0 }
    var avgHR: Int { hr.isEmpty ? 0 : hr.map(\.value).reduce(0, +) / hr.count }

    func setMode(_ m: SportMode) { mode = m; speedKmh = m.defaultSpeed; cadence = m.defaultCadence }

    func start() async {
        guard phase == .idle else { return }
        elapsed = 0; meters = 0; kcal = 0; steps = 0; hr = []; started = Date()
        guard await link.request(BleKey.appSportState, BleFlag.update, [UInt8(mode.rawValue), 1]) != nil else {
            store.show("The watch didn't start the workout", "exclamationmark.triangle.fill", error: true); return
        }
        phase = .running
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func pause() async { guard phase == .running else { return }; phase = .paused; _ = await link.request(BleKey.appSportState, BleFlag.update, [UInt8(mode.rawValue), 3]) }
    func resume() async { guard phase == .paused else { return }; phase = .running; _ = await link.request(BleKey.appSportState, BleFlag.update, [UInt8(mode.rawValue), 2]) }

    func end() async {
        guard phase != .idle else { return }
        timer?.invalidate(); timer = nil
        _ = await link.request(BleKey.appSportState, BleFlag.update, [UInt8(mode.rawValue), 4])
        phase = .idle
        if elapsed >= 10 {
            history.insert(WorkoutRecord(start: started, end: Date(), mode: mode.rawValue, seconds: elapsed, meters: meters, kcal: kcal,
                                         steps: Int(steps), avgHR: avgHR, maxHR: hr.map(\.value).max() ?? 0, source: "mac"), at: 0)
            ExtrasStore.save(Array(history.prefix(200)), "workoutHistory")
            store.show("Workout saved — \(String(format: "%.2f", meters / 1000)) km in \(Self.clock(elapsed))", "flag.checkered")
        }
    }

    private func tick() {
        guard phase == .running else { return }
        elapsed += 1
        meters += speedKmh / 3.6
        kcal += mode.met(speedKmh) * weight / 3600
        steps += Double(cadence) / 60
        guard store.ready else { return }
        var d: [UInt8] = []
        func i32(_ v: Int) { d += withUnsafeBytes(of: Int32(clamping: v).littleEndian) { Array($0) } }
        func i16(_ v: Int) { d += withUnsafeBytes(of: Int16(clamping: v).littleEndian) { Array($0) } }
        i32(Int(steps)); i32(Int(meters)); i32(Int(kcal * 1000)); i16(elapsed); i16(cadence); i16(0); i16(0)
        i32(paceSecPerKm); d += f32bytes(speedKmh); d.append(UInt8(mode.rawValue)); d += [0, 0, 0]
        link.send(BleKey.appSportData, BleFlag.update, d)
    }

    static func clock(_ s: Int) -> String { s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60) }
    static func pace(_ s: Int) -> String { s > 0 && s < 3600 ? String(format: "%d'%02d\"", s / 60, s % 60) : "—" }
}
