import AppKit
import Combine
import Foundation

struct ActivityRecord: Identifiable { let id = UUID(); let date: Date; let steps: Int; let kcal: Double; let meters: Double }
struct HRSample: Identifiable { let id = UUID(); let date: Date; let bpm: Int }
struct SleepRecord: Identifiable { let id = UUID(); let date: Date; let mode: Int
    var stage: String { [1: "Deep", 2: "Light", 3: "Awake", 9: "REM"][mode] ?? "Other" } }

struct DeviceSettings {
    var backlight: Int?        // seconds
    var brightness: Int?       // level
    var stepGoal: Int?
    var hour24: Bool?
    var vibration: Bool?
}

struct Toast: Identifiable, Equatable { let id = UUID(); let text: String; let symbol: String; var isError = false }

@MainActor
final class WatchStore: ObservableObject {
    let link = WatchLink()
    let media = MediaBridge()
    let weather = WeatherService()
    lazy var extras = ExtrasStore(store: self)
    lazy var dev = DevStore(store: self)
    lazy var chip = JieLiChip(link: link)
    lazy var workout = WorkoutStore(store: self)
    lazy var assistant = AssistantStore(store: self)
    lazy var contacts = ContactsStore(store: self)

    @Published var battery: Int?
    @Published var firmware: String?
    @Published var mac: String?
    @Published var settings = DeviceSettings()
    @Published var activity: [ActivityRecord] = []
    @Published var heartRates: [HRSample] = []
    @Published var sleep: [SleepRecord] = []
    @Published var liveHR: Int?
    @Published var liveHRRunning = false
    @Published var lastSync: Date?
    @Published var syncing = false
    @Published var log: [LogLine] = []
    @Published var remoteFeed: [(Date, String, String)] = []
    @Published var toast: Toast?
    @Published var installedPreview: NSImage?

    @Published var trackSync = UserDefaults.standard.object(forKey: "trackSync") as? Bool ?? true {
        didSet { UserDefaults.standard.set(trackSync, forKey: "trackSync") }
    }
    @Published var weatherAuto = UserDefaults.standard.object(forKey: "weatherAuto") as? Bool ?? true {
        didSet { UserDefaults.standard.set(weatherAuto, forKey: "weatherAuto") }
    }
    @Published var mapping: [WatchTrigger: RemoteAction] = WatchStore.loadMapping() {
        didSet { saveMapping() }
    }
    @Published var shortcuts: [WatchTrigger: String] = (UserDefaults.standard.dictionary(forKey: "remoteShortcuts") as? [String: String] ?? [:])
        .reduce(into: [:]) { if let t = WatchTrigger(rawValue: $1.key) { $0[t] = $1.value } } {
        didSet { UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) }), forKey: "remoteShortcuts") }
    }

    private var bag = Set<AnyCancellable>()
    private var timers: [Timer] = []
    private var lastPushed: [String: String] = [:]

    init() {
        link.onLog = { [weak self] l in
            guard let self else { return }
            self.log.append(l)
            if self.log.count > 600 { self.log.removeFirst(self.log.count - 600) }
        }
        link.onReady = { [weak self] in Task { await self?.onConnected() } }
        link.events.receive(on: RunLoop.main).sink { [weak self] e in self?.handle(e) }.store(in: &bag)
        link.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        media.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        weather.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        if let d = try? Data(contentsOf: Self.previewURL) { installedPreview = NSImage(data: d) }
        link.connect()
        timers.append(Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tickNowPlaying() } })
        timers.append(Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshQuick() } })
        timers.append(Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.pushWeather(refresh: true) } })
    }

    var state: LinkState { link.state }
    var ready: Bool { link.state == .ready && !link.transferActive }

    nonisolated static var supportDir: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OHW Studio")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var previewURL: URL { supportDir.appendingPathComponent("installed-face.png") }

    func show(_ text: String, _ symbol: String = "checkmark.circle.fill", error: Bool = false) {
        toast = Toast(text: text, symbol: symbol, isError: error)
        let id = toast?.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { [weak self] in if self?.toast?.id == id { self?.toast = nil } }
    }

    // MARK: connection
    private func onConnected() async {
        lastPushed.removeAll()
        await syncTime(silent: true)
        await refreshAll()
        await tickNowPlaying()
        await pushWeather(refresh: weather.now == nil)
        await extras.onConnected()
        await contacts.onConnected()
    }

    func refreshQuick() async {
        guard ready else { return }
        if let b = await link.request(BleKey.power, BleFlag.read)?.first { battery = Int(b) }
    }

    func refreshAll() async {
        guard ready, !syncing else { return }
        syncing = true; defer { syncing = false }
        if let b = await link.request(BleKey.power, BleFlag.read)?.first { battery = Int(b) }
        if let f = await link.request(BleKey.firmware, BleFlag.read), f.count >= 3 { firmware = "\(f[0]).\(f[1]).\(f[2])" }
        if let m = await link.request(BleKey.bleAddress, BleFlag.read), m.count >= 6 {
            mac = m.prefix(6).reversed().map { String(format: "%02X", $0) }.joined(separator: ":")
        }
        if let v = await link.request(BleKey.backlight, BleFlag.read)?.first { settings.backlight = Int(v) }
        if let v = await link.request(BleKey.brightness, BleFlag.read)?.first { settings.brightness = Int(v) }
        if let v = await link.request(BleKey.stepGoal, BleFlag.read), v.count >= 4 { settings.stepGoal = readBE32(v, 0) }
        if let v = await link.request(BleKey.hourSystem, BleFlag.read)?.first { settings.hour24 = v == 0 }
        if let v = await link.request(BleKey.vibration, BleFlag.read)?.first { settings.vibration = v != 0 }
        await refreshHealth()
        lastSync = Date()
    }

    func refreshHealth() async {
        guard ready else { return }
        let a = await link.collect(BleKey.activity)
        activity = stride(from: 0, to: a.count - 15, by: 16).map {
            ActivityRecord(date: dateFrom2000(readBE32(a, $0)), steps: readBE32(a, $0 + 4) & 0xFFFFFF,   // byte 4 = mode(5)|state(3), steps are 24-bit
                          
                           kcal: Double(readBE32(a, $0 + 8)) / 10_000, meters: Double(readBE32(a, $0 + 12)) / 10_000)
        }.sorted { $0.date < $1.date }
        let h = await link.collect(BleKey.heartRate)
        heartRates = stride(from: 0, to: h.count - 5, by: 6).compactMap {
            let v = Int(h[$0 + 4]); return v > 0 ? HRSample(date: dateFrom2000(readBE32(h, $0)), bpm: v) : nil
        }.sorted { $0.date < $1.date }
        let s = await link.collect(BleKey.sleep)
        sleep = stride(from: 0, to: s.count - 6, by: 7).map {
            SleepRecord(date: dateFrom2000(readBE32(s, $0)), mode: Int(s[$0 + 4]))
        }.sorted { $0.date < $1.date }
    }

    // today's totals (records are cumulative within a day)
    var todaySteps: Int { activity.filter { Calendar.current.isDateInToday($0.date) }.map(\.steps).max() ?? 0 }
    var todayKcal: Double { activity.filter { Calendar.current.isDateInToday($0.date) }.map(\.kcal).max() ?? 0 }
    var todayKm: Double { (activity.filter { Calendar.current.isDateInToday($0.date) }.map(\.meters).max() ?? 0) / 1000 }

    // MARK: commands
    func syncTime(silent: Bool = false) async {
        guard ready else { return }
        _ = await link.request(BleKey.time, BleFlag.update, bleTime())
        if !silent { show("Watch clock synced", "clock.badge.checkmark") }
    }

    func setBacklight(_ s: Int) async {
        guard ready else { return }
        if await link.request(BleKey.backlight, BleFlag.update, [UInt8(clamping: s)]) != nil {
            settings.backlight = s; show("Screen timeout set to \(s) s", "sun.max")
        }
    }

    func setBrightness(_ v: Int) async {
        guard ready else { return }
        if await link.request(BleKey.brightness, BleFlag.update, [UInt8(clamping: v)]) != nil {
            settings.brightness = v; show("Brightness set to \(v)", "sun.max.fill")
        }
    }

    func setStepGoal(_ v: Int) async {
        guard ready else { return }
        if await link.request(BleKey.stepGoal, BleFlag.update, be32(v)) != nil {
            settings.stepGoal = v; show("Step goal set to \(v.formatted())", "figure.walk")
        }
    }

    func sendNotification(title: String, body: String, call: Bool = false, app: String = "com.apple.MobileSMS") async {
        guard ready else { show("Watch not connected", "exclamationmark.triangle.fill", error: true); return }
        let data: [UInt8] = [call ? 1 : 127] + bleTime() + fixedString(call ? "com.apple.mobilephone" : app, 32)
            + fixedString(title, 32) + Array(body.utf8.prefix(250))
        _ = await link.request(BleKey.notification, BleFlag.update, data)
        show(call ? "Ringing your watch" : "Sent to watch", call ? "bell.and.waves.left.and.right.fill" : "paperplane.fill")
    }

    func findWatch() async { await sendNotification(title: "Found me!", body: "", call: true) }

    func toggleLiveHR() async {
        guard ready else { return }
        liveHRRunning.toggle()
        _ = await link.request(BleKey.realtimeHR, BleFlag.update, [liveHRRunning ? 1 : 0])
        if !liveHRRunning { liveHR = nil }
    }

    func install(_ build: FaceBuild, progress: @escaping (Double) -> Void) async throws {
        try await link.uploadFace(build.blob, progress: progress)
        if let png = build.preview.pngData() { try? png.write(to: Self.previewURL) }
        installedPreview = build.preview.nsImage
    }

    // MARK: now playing → watch
    func tickNowPlaying(force: Bool = false) async {
        guard trackSync else { return }
        let np = await media.poll()
        guard ready, let np else { return }
        let items: [(String, UInt8, UInt8, String)] = [
            ("title", 2, 2, String((np.artist.isEmpty ? np.title : "\(np.title) - \(np.artist)").prefix(60))),
            ("state", 0, 1, "\(np.playing ? 1 : 0),\(np.playing ? "1.0" : "0.0"),\(np.position)"),
            ("volume", 0, 2, String(format: "%.2f", Double(np.volume) / 100)),
        ]
        for (k, ent, attr, val) in items {
            let cmp = k == "state" ? String(val.split(separator: ",").prefix(2).joined(separator: ",")) : val
            if force || lastPushed[k] != cmp {
                lastPushed[k] = cmp
                link.send(BleKey.musicControl, BleFlag.update, [ent, attr] + Array(val.utf8))
            }
        }
    }

    func pushWeather(refresh: Bool = false) async {
        if refresh || weather.now == nil { await weather.refresh() }
        guard ready, weatherAuto || !refresh, let w = weather.now else { return }
        _ = await link.request(BleKey.weatherRealtime, BleFlag.update, w.realtimePayload)
        _ = await link.request(BleKey.weatherForecast, BleFlag.update, w.forecastPayload)
    }

    // MARK: watch → Mac
    private func handle(_ e: WatchEvent) {
        switch e {
        case .music(let c):
            let t: WatchTrigger? = [0: .playPause, 1: .playPause, 2: .playPause, 3: .next, 4: .previous, 5: .volumeUp, 6: .volumeDown][c]
            if let t { fire(t) }
            Task { try? await Task.sleep(nanoseconds: 700_000_000); await tickNowPlaying() }
        case .camera(let s):
            if s == 2 { fire(.shutter) } else { feed(s == 1 ? "Camera remote opened" : "Camera remote closed", "camera") }
        case .findPhone(let on):
            if on { fire(.findPhone) } else { feed("Find phone stopped", "iphone.slash") }
        case .weatherRequest:
            feed("Watch asked for weather", "cloud.sun")
            Task { await pushWeather() }
        case .heartRate(let v):
            liveHR = v
            heartRates.append(HRSample(date: Date(), bpm: v))
        case .other(let k, let f, let d):
            if k != BleKey.identity { feed("\(BleKey.name(k)) \(String(format: "%02x", f)) \(hex(d, max: 8))", "dot.radiowaves.left.and.right") }
        }
    }

    private func feed(_ text: String, _ symbol: String) {
        remoteFeed.insert((Date(), text, symbol), at: 0)
        if remoteFeed.count > 60 { remoteFeed.removeLast() }
    }

    private var lastFire: [WatchTrigger: Date] = [:]

    func fire(_ t: WatchTrigger) {
        // the watch repeats frames while a button is held; debounce bursts
        if let l = lastFire[t], Date().timeIntervalSince(l) < 0.25 { return }
        lastFire[t] = Date()
        let a = mapping[t] ?? t.defaultAction
        feed("\(t.title) → \(a.title)", t.symbol)
        Task { await perform(a, shortcut: shortcuts[t]) }
    }

    func perform(_ a: RemoteAction, shortcut: String? = nil) async {
        switch a {
        case .none: break
        case .playPause: await media.control("playpause")
        case .nextTrack: await media.control("next")
        case .previousTrack: await media.control("previous")
        case .volumeUp: await media.systemVolume(delta: 6)
        case .volumeDown: await media.systemVolume(delta: -6)
        case .screenshot:
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
            let path = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Watch Shot \(f.string(from: Date())).png").path
            _ = await Shell.run("/usr/sbin/screencapture", ["-x", path])
            NSSound(named: "Pop")?.play()
            show("Screenshot saved to Desktop", "camera.fill")
        case .lockScreen: _ = await Shell.run("/usr/bin/pmset", ["displaysleepnow"])
        case .nextSlide: _ = await Shell.osascript("tell application \"System Events\" to key code 124")
        case .previousSlide: _ = await Shell.osascript("tell application \"System Events\" to key code 123")
        case .chime:
            NSSound(named: "Glass")?.play()
            NSApp.requestUserAttention(.criticalRequest)
            show("Your watch is looking for this Mac", "iphone.radiowaves.left.and.right")
        case .assistant: assistant.toggle()
        case .shortcut:
            if let s = shortcut, !s.isEmpty { _ = await Shell.run("/usr/bin/shortcuts", ["run", s], timeout: 60) }
        }
    }

    private static func loadMapping() -> [WatchTrigger: RemoteAction] {
        let raw = UserDefaults.standard.dictionary(forKey: "remoteMapping") as? [String: String] ?? [:]
        var m: [WatchTrigger: RemoteAction] = [:]
        for t in WatchTrigger.allCases { m[t] = raw[t.rawValue].flatMap(RemoteAction.init(rawValue:)) ?? t.defaultAction }
        return m
    }
    private func saveMapping() {
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: mapping.map { ($0.key.rawValue, $0.value.rawValue) }), forKey: "remoteMapping")
    }
}
