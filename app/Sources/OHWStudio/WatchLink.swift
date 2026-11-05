import Foundation
import CoreBluetooth
import Combine

enum LinkState: Equatable {
    case bluetoothOff, searching, connecting, handshaking, ready, disconnected

    var label: String {
        switch self {
        case .bluetoothOff: return "Bluetooth off"
        case .searching: return "Searching"
        case .connecting: return "Connecting"
        case .handshaking: return "Pairing"
        case .ready: return "Connected"
        case .disconnected: return "Disconnected"
        }
    }
    var isBusy: Bool { self == .searching || self == .connecting || self == .handshaking }
}

enum WatchEvent {
    case music(UInt8)
    case camera(UInt8)
    case findPhone(Bool)
    case weatherRequest
    case heartRate(Int)
    case other(UInt16, UInt8, [UInt8])
}

struct LogLine: Identifiable {
    let id = UUID()
    let date = Date()
    let outgoing: Bool
    let text: String
}

enum LinkError: LocalizedError {
    case notConnected, noReply, rejected(Int)
    var errorDescription: String? {
        switch self {
        case .notConnected: return "The watch isn't connected."
        case .noReply: return "The watch stopped responding."
        case .rejected(let e):
            switch e {
            case 1: return "The watch rejected this face (try a different design)."
            case 2: return "The watch is out of space for faces."
            case 4: return "The watch is busy — try again in a moment."
            default: return "The watch rejected the upload (error \(e))."
            }
        }
    }
}

/// CoreBluetooth link to the OHW-11. All state lives on the main actor; CoreBluetooth
/// delivers callbacks on the main queue.
@MainActor
final class WatchLink: NSObject, ObservableObject {
    static let nus = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let rxUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    static let txUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    static let jlService = CBUUID(string: "AE00"), jlWriteUUID = CBUUID(string: "AE01"), jlNotifyUUID = CBUUID(string: "AE02")

    @Published private(set) var state: LinkState = .disconnected
    @Published private(set) var deviceInfo: DeviceInfo?
    @Published private(set) var rawDeviceInfo: [UInt8] = []
    var writeMTU: Int { peripheral.map { $0.maximumWriteValueLength(for: .withoutResponse) } ?? 0 }
    var peripheralID: String { peripheral?.identifier.uuidString ?? "—" }
    @Published private(set) var rssi: Int?
    @Published private(set) var transferActive = false

    let events = PassthroughSubject<WatchEvent, Never>()
    var onLog: ((LogLine) -> Void)?
    var onReady: (() -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private(set) var jlWrite: CBCharacteristic?
    private(set) var jlNotify: CBCharacteristic?
    /// Raw notifications from the JieLi RCSP channel (AE02).
    var onJieLi: (([UInt8]) -> Void)?
    var jieliAvailable: Bool { jlWrite != nil && jlNotify != nil }

    func jieliListen(_ on: Bool) { if let p = peripheral, let n = jlNotify { p.setNotifyValue(on, for: n) } }
    func jieliWrite(_ bytes: [UInt8]) {
        guard let p = peripheral, let w = jlWrite else { return }
        let mtu = max(20, p.maximumWriteValueLength(for: .withoutResponse))
        var i = 0
        while i < bytes.count { p.writeValue(Data(bytes[i..<min(i + mtu, bytes.count)]), for: w, type: .withoutResponse); i += mtu }
    }
    private let parser = FrameParser()
    private var outbox: [Data] = []
    private var waiters: [Waiter] = []
    private var wantConnection = true
    private var reconnectWork: DispatchWorkItem?

    private final class Waiter {
        let match: (Frame) -> Bool
        let collect: Bool
        var acc: [UInt8] = []
        var resume: (([UInt8]?) -> Void)?
        var idle: DispatchWorkItem?
        init(match: @escaping (Frame) -> Bool, collect: Bool) { self.match = match; self.collect = collect }
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: lifecycle
    func connect() {
        wantConnection = true
        startSearch()
    }

    func disconnect() {
        wantConnection = false
        reconnectWork?.cancel()
        central.stopScan()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        state = .disconnected
    }

    private func startSearch() {
        guard central.state == .poweredOn else { state = .bluetoothOff; return }
        if let p = peripheral, p.state == .connected || p.state == .connecting { return }
        state = .searching
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func scheduleReconnect(after s: Double = 3) {
        reconnectWork?.cancel()
        guard wantConnection else { return }
        let w = DispatchWorkItem { [weak self] in self?.startSearch() }
        reconnectWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: w)
    }

    private func log(_ out: Bool, _ s: String) { onLog?(LogLine(outgoing: out, text: s)) }

    // MARK: writing
    func send(_ key: UInt16, _ flag: UInt8, _ data: [UInt8] = [], header: UInt8 = 0x01) {
        guard let p = peripheral, let rx = rx else { return }
        let bytes = Codec.frame(key: key, flag: flag, data: data, header: header)
        if key != BleKey.watchFace {
            log(true, "\(BleKey.name(key)) flag \(String(format: "%02x", flag)) \(hex(data))")
        }
        let mtu = max(20, p.maximumWriteValueLength(for: .withoutResponse))
        var i = 0
        while i < bytes.count {
            outbox.append(Data(bytes[i..<min(i + mtu, bytes.count)]))
            i += mtu
        }
        _ = rx
        pump()
    }

    private func pump() {
        guard let p = peripheral, let rx = rx else { outbox.removeAll(); return }
        while !outbox.isEmpty && p.canSendWriteWithoutResponse {
            p.writeValue(outbox.removeFirst(), for: rx, type: .withoutResponse)
        }
    }

    /// Send a command and wait for the watch's reply frame with the same key.
    func request(_ key: UInt16, _ flag: UInt8, _ data: [UInt8] = [], timeout: Double = 4) async -> [UInt8]? {
        guard state == .ready || state == .handshaking else { return nil }
        return await wait(match: { !$0.isCommand && $0.key == key }, collect: false, timeout: timeout) {
            self.send(key, flag, data)
        }
    }

    /// Send a read and gather every reply frame for `key` until the stream goes quiet.
    func collect(_ key: UInt16, _ flag: UInt8 = BleFlag.read, timeout: Double = 10) async -> [UInt8] {
        guard state == .ready else { return [] }
        return await wait(match: { !$0.isCommand && $0.key == key }, collect: true, timeout: timeout) {
            self.send(key, flag)
        } ?? []
    }

    private func wait(match: @escaping (Frame) -> Bool, collect: Bool, timeout: Double,
                      then action: @escaping () -> Void) async -> [UInt8]? {
        await withCheckedContinuation { (cont: CheckedContinuation<[UInt8]?, Never>) in
            let w = Waiter(match: match, collect: collect)
            w.resume = { cont.resume(returning: $0) }
            waiters.append(w)
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(w, collect ? w.acc : nil)
            }
        }
    }

    private func finish(_ w: Waiter, _ value: [UInt8]?) {
        guard let r = w.resume else { return }
        w.resume = nil
        w.idle?.cancel()
        waiters.removeAll { $0 === w }
        r(value)
    }

    // MARK: incoming
    private func handle(_ frames: [Frame]) {
        for f in frames {
            if f.key != BleKey.watchFace {
                log(false, "\(f.isCommand ? "⇠ " : "")\(BleKey.name(f.key)) flag \(String(format: "%02x", f.flag)) \(hex(f.data))")
            }
            if f.isCommand { handleCommand(f) }
            if f.key == BleKey.realtimeHR {
                // BleHeartRate: [time BE32][bpm]; older pushes are a bare [bpm]
                let v = f.data.count >= 5 ? f.data[4] : (f.data.last ?? 0)
                if v > 0 { events.send(.heartRate(Int(v))) }
            }
            for w in waiters where w.match(f) {
                if w.collect {
                    w.acc += f.data
                    w.idle?.cancel()
                    let item = DispatchWorkItem { [weak self] in self?.finish(w, w.acc) }
                    w.idle = item
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: item)
                } else {
                    finish(w, f.data)
                }
            }
        }
    }

    /// The watch sent us a command: answer like the watch answers ours, then surface it.
    private func handleCommand(_ f: Frame) {
        var extra: [UInt8] = []
        if f.key == BleKey.camera, let s = f.data.first { extra = [s] }   // app echoes camera state
        send(f.key, f.flag, extra, header: 0x11)
        switch f.key {
        case BleKey.identity:
            rawDeviceInfo = f.data
            if let info = DeviceInfo.parse(f.data) { deviceInfo = info }
        case BleKey.musicControl:
            if let c = f.data.first { events.send(.music(c)) }
        case BleKey.camera:
            if let c = f.data.first { events.send(.camera(c)) }
        case BleKey.findPhone:
            events.send(.findPhone((f.data.first ?? 0) != 0))
        case BleKey.weatherRealtime, BleKey.weatherForecast:
            events.send(.weatherRequest)
        default:
            events.send(.other(f.key, f.flag, f.data))
        }
    }

    private func handshake() async {
        state = .handshaking
        let ack = await wait(match: { !$0.isCommand && $0.key == BleKey.identity }, collect: false, timeout: 5) {
            self.send(BleKey.identity, BleFlag.create, [0x28, 0x46, 0x67, 0xc2])
        }
        guard ack != nil else {
            log(false, "handshake: no answer, retrying")
            if let p = peripheral { central.cancelPeripheralConnection(p) }
            return
        }
        // the watch pushes its device info as a command; we answer it in handleCommand
        _ = await wait(match: { $0.isCommand && $0.key == BleKey.identity }, collect: false, timeout: 7) {}
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        state = .ready
        onReady?()
    }

    // MARK: watch-face stream (BleConnector.sendStream)
    func uploadFace(_ blob: [UInt8], progress: @escaping (Double) -> Void) async throws {
        try await uploadStream(BleKey.watchFace, blob, progress: progress)
    }

    /// Generic sendStream upload (watch faces 0x0701, contacts 0x0704). Busy replies (error 4) are retried.
    func uploadStream(_ key: UInt16, _ blob: [UInt8], settle: Double = 1.5, progress: @escaping (Double) -> Void = { _ in }) async throws {
        guard state == .ready else { throw LinkError.notConnected }
        transferActive = true
        defer { transferActive = false }
        log(true, "\(BleKey.name(key)) stream \(blob.count) bytes")
        try await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
        let chunk = deviceInfo?.ioBuffer ?? 1018
        var off = 0, busyRetries = 0
        while true {
            let part = Array(blob[off..<min(off + chunk, blob.count)])
            let data: [UInt8] = [0] + be32(blob.count) + be32(off) + part
            guard let r = await request(key, BleFlag.update, data, timeout: 12), r.count >= 9 else {
                throw LinkError.noReply
            }
            let status = Int(r[0] >> 4), err = Int(r[0] & 0x0f)
            let total = readBE32(r, 1), done = readBE32(r, 5)
            progress(Double(done) / Double(max(total, 1)))
            if status != 0 {
                if err == 4 && busyRetries < 5 {
                    busyRetries += 1
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    off = 0
                    continue
                }
                throw LinkError.rejected(err)
            }
            if done >= total { log(false, "\(BleKey.name(key)) stream complete"); return }
            off = done
        }
    }
}

// MARK: - CoreBluetooth delegates (main queue → main actor)
extension WatchLink: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            if central.state == .poweredOn { if wantConnection { startSearch() } } else { state = .bluetoothOff }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                                    advertisementData ad: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
            let mfr = ad[CBAdvertisementDataManufacturerDataKey] as? Data
            let isJL = mfr.map { $0.count >= 2 && $0[0] == 0xD6 && $0[1] == 0x05 } ?? false
            guard name.hasPrefix("OHW") || (isJL && name.isEmpty == false) else { return }
            central.stopScan()
            rssi = RSSI.intValue
            peripheral = p
            p.delegate = self
            state = .connecting
            log(false, "found \(name) rssi \(RSSI)")
            central.connect(p, options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        MainActor.assumeIsolated {
            p.discoverServices([WatchLink.nus, WatchLink.jlService])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { state = .disconnected; scheduleReconnect() }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            log(false, "disconnected")
            rx = nil; jlWrite = nil; jlNotify = nil
            outbox.removeAll()
            for w in waiters { finish(w, w.collect ? w.acc : nil) }
            state = .disconnected
            scheduleReconnect()
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            if let j = p.services?.first(where: { $0.uuid == WatchLink.jlService }) {
                p.discoverCharacteristics([WatchLink.jlWriteUUID, WatchLink.jlNotifyUUID], for: j)
            }
            guard let s = p.services?.first(where: { $0.uuid == WatchLink.nus }) else {
                central.cancelPeripheralConnection(p); return
            }
            p.discoverCharacteristics([WatchLink.rxUUID, WatchLink.txUUID], for: s)
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        MainActor.assumeIsolated {
            if s.uuid == WatchLink.jlService {
                jlWrite = s.characteristics?.first { $0.uuid == WatchLink.jlWriteUUID }
                jlNotify = s.characteristics?.first { $0.uuid == WatchLink.jlNotifyUUID }
                return
            }
            rx = s.characteristics?.first { $0.uuid == WatchLink.rxUUID }
            if let tx = s.characteristics?.first(where: { $0.uuid == WatchLink.txUUID }) {
                p.setNotifyValue(true, for: tx)
            }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard c.isNotifying, c.uuid == WatchLink.txUUID else { return }
            p.readRSSI()
            Task { await self.handshake() }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard let v = c.value else { return }
            if c.uuid == WatchLink.jlNotifyUUID { onJieLi?([UInt8](v)); return }
            handle(parser.feed([UInt8](v)))
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        MainActor.assumeIsolated { pump() }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        MainActor.assumeIsolated { rssi = RSSI.intValue }
    }
}
