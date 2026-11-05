import Foundation

// SMA "AB" protocol over Nordic UART, as reverse-engineered in FINDINGS.md.
// Frame: AB | header | len BE16 | crc16-ARC BE16 | [key BE16][flag][data]
// header 0x01 = command, 0x11 = reply.

enum BleKey {
    static let time: UInt16 = 0x0201
    static let power: UInt16 = 0x0203
    static let firmware: UInt16 = 0x0204
    static let bleAddress: UInt16 = 0x0205
    static let stepGoal: UInt16 = 0x0207
    static let backlight: UInt16 = 0x0208
    static let sedentary: UInt16 = 0x0209
    static let noDisturb: UInt16 = 0x020a
    static let vibration: UInt16 = 0x020b
    static let gestureWake: UInt16 = 0x020c
    static let hourSystem: UInt16 = 0x020e
    static let findPhone: UInt16 = 0x0213
    static let realtimeHR: UInt16 = 0x0224
    static let brightness: UInt16 = 0x0260
    static let identity: UInt16 = 0x0301
    static let notification: UInt16 = 0x0401
    static let musicControl: UInt16 = 0x0402
    static let weatherRealtime: UInt16 = 0x0404
    static let weatherForecast: UInt16 = 0x0405
    static let activity: UInt16 = 0x0502
    static let heartRate: UInt16 = 0x0503
    static let sleep: UInt16 = 0x0505
    static let bloodOxygen: UInt16 = 0x0509
    static let camera: UInt16 = 0x0601
    static let watchFace: UInt16 = 0x0701
    static let contact: UInt16 = 0x0704

    static func name(_ k: UInt16) -> String {
        switch k {
        case time: return "TIME"; case power: return "POWER"; case firmware: return "FIRMWARE"
        case bleAddress: return "BLE_ADDRESS"; case stepGoal: return "STEP_GOAL"; case backlight: return "BACK_LIGHT"
        case findPhone: return "FIND_PHONE"; case realtimeHR: return "REAL_TIME_HR"; case brightness: return "BRIGHTNESS"
        case identity: return "IDENTITY"; case notification: return "NOTIFICATION"; case musicControl: return "MUSIC_CONTROL"
        case weatherRealtime: return "WEATHER"; case weatherForecast: return "FORECAST"; case activity: return "ACTIVITY"
        case heartRate: return "HEART_RATE"; case sleep: return "SLEEP"; case camera: return "CAMERA"
        case watchFace: return "WATCH_FACE"; case hourSystem: return "HOUR_SYSTEM"
        default: return String(format: "0x%04X", k)
        }
    }
}

enum BleFlag {
    static let update: UInt8 = 0x00
    static let read: UInt8 = 0x10
    static let create: UInt8 = 0x20
}

struct Frame {
    let header: UInt8
    let key: UInt16
    let flag: UInt8
    let data: [UInt8]
    var isCommand: Bool { header == 0x01 }
}

enum Codec {
    static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for b in bytes {
            crc ^= UInt16(b)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1 }
        }
        return crc
    }

    static func frame(key: UInt16, flag: UInt8, data: [UInt8] = [], header: UInt8 = 0x01) -> [UInt8] {
        let p: [UInt8] = [UInt8(key >> 8), UInt8(key & 0xff), flag] + data
        let c = crc16(p), n = p.count
        return [0xAB, header, UInt8((n >> 8) & 0xff), UInt8(n & 0xff), UInt8(c >> 8), UInt8(c & 0xff)] + p
    }
}

final class FrameParser {
    private var buf: [UInt8] = []

    func feed(_ d: [UInt8]) -> [Frame] {
        buf += d
        var out: [Frame] = []
        while true {
            guard let i = buf.firstIndex(of: 0xAB) else { buf.removeAll(); break }
            if i > 0 { buf.removeFirst(i) }
            guard buf.count >= 6 else { break }
            let n = Int(buf[2]) << 8 | Int(buf[3])
            guard buf.count >= 6 + n else { break }
            let hdr = buf[1]
            let p = Array(buf[6..<(6 + n)])
            buf.removeFirst(6 + n)
            if n >= 3 {
                out.append(Frame(header: hdr, key: UInt16(p[0]) << 8 | UInt16(p[1]), flag: p[2], data: Array(p[3...])))
            }
        }
        return out
    }
}

// MARK: byte helpers
func be32(_ v: Int) -> [UInt8] { [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
func readBE32(_ b: [UInt8], _ i: Int) -> Int {
    guard b.count >= i + 4 else { return 0 }
    return Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
}
func hex(_ b: [UInt8], max: Int = 48) -> String {
    let s = b.prefix(max).map { String(format: "%02x", $0) }.joined(separator: " ")
    return b.count > max ? s + " … (\(b.count) B)" : s
}

/// 6-byte BleTime: [year-2000, month, day, hour, minute, second]
func bleTime(_ date: Date = Date()) -> [UInt8] {
    let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    return [UInt8((c.year ?? 2000) - 2000), UInt8(c.month ?? 1), UInt8(c.day ?? 1),
            UInt8(c.hour ?? 0), UInt8(c.minute ?? 0), UInt8(c.second ?? 0)]
}

/// Watch timestamps are seconds since 2000-01-01 00:00:00 local time.
func dateFrom2000(_ s: Int) -> Date {
    var c = DateComponents(); c.year = 2000; c.month = 1; c.day = 1
    let base = Calendar.current.date(from: c) ?? Date(timeIntervalSince1970: 946_684_800)
    return base.addingTimeInterval(TimeInterval(s))
}

func fixedString(_ s: String, _ n: Int) -> [UInt8] {
    var b = Array(s.utf8.prefix(n - 1))
    b += Array(repeating: 0, count: n - b.count)
    return b
}

// MARK: device info (BleDeviceInfo.decode order, see tools/devinfo.py)
struct DeviceInfo {
    var name = "", address = "", platform = "", prototype = "", firmwareFlag = "", classicAddress = ""
    var ioBuffer = 1018
    var watchFaceType = 0
    var dataKeys: [UInt16] = []
    var flags: [String: Int] = [:]

    static let flagOrderA = ["HideDigitalPower", "ShowAntiLostSwitch", "SleepAlgorithmType", "DateFormat", "ReadDeviceInfo",
        "TemperatureUnit", "DrinkWater", "ChangeClassicBluetoothState", "AppSport", "BloodOxygenSet", "WashSet",
        "RequestRealtimeWeather", "HID", "IBeacon", "WatchFaceId", "NewTransportMode", "JLTransport", "FindWatch",
        "WorldClock", "Stock", "SMSQuickReply", "NoDisturb", "WatchPassword", "RealTimeMeasurement", "PowerSaveMode",
        "LoveTap", "Newsfeed", "MedicationReminder", "Qrcode", "Weather2", "Alipay", "StandbySet", "2DAcceleration",
        "TuyaKey", "MedicationAlarm", "ReadPackageStatus", "ContactSize", "Voice", "Navigation", "HrWarn"]
    static let flagOrderB = ["MusicTransfer", "NoDisturb2", "SOS", "ReadLanguages", "GirlCare", "AppPushSwitch",
        "ReceiptCode", "GameTimeReminder", "MyCardCode", "DeviceSportData", "EbookTransfer", "DoubleScreen",
        "CustomLogo", "PressureTiming", "TimerStandby", "SOS2", "FallSet", "WalkAndBike", "ConnectReminder",
        "SDCardInfo", "IncomingCallRing", "NotificationLightScreen", "BloodPressureCalibration", "OTAFile",
        "GPSFirmwareFile", "GoMore", "RingVibration", "Network", "ContactSort", "QrcodeSize", "QrcodeContentSize",
        "StringQrcode", "WatchFaceIndex", "SosContact", "GirlCareMonthly", "WearWay", "GestureWake2", "NavImage",
        "VoiceMaxLength", "AudioBooks", "StudyCards", "AppStore", "SHSYAlgorithm", "Qibla", "BloodGlucose",
        "GameControls", "BatteryUsage", "AITranslation", "SimultaneousTranslation", "TouchSet", "IMEI", "Quran",
        "SyncAGPSBackground", "RestoreFactory", "RecordNote", "SleepScore", "Watchface2"]

    static func parse(_ d: [UInt8]) -> DeviceInfo? {
        guard d.count > 20 else { return nil }
        var i = 1   // first byte is a status/marker
        func u8() -> Int { defer { i += 1 }; return i < d.count ? Int(d[i]) : 0 }
        func cstr() -> String {
            guard i < d.count else { return "" }
            let end = d[i...].firstIndex(of: 0) ?? d.count
            let s = String(decoding: d[i..<end], as: UTF8.self)
            i = end + 1
            return s
        }
        var info = DeviceInfo()
        i += 4 // id
        let kEnd = d[i...].firstIndex(of: 0) ?? d.count
        let kb = Array(d[i..<kEnd]); i = kEnd + 1
        info.dataKeys = stride(from: 0, to: kb.count - 1, by: 2).map { UInt16(kb[$0]) << 8 | UInt16(kb[$0 + 1]) }
        info.name = cstr(); info.address = cstr(); info.platform = cstr(); info.prototype = cstr(); info.firmwareFlag = cstr()
        _ = u8()                                     // AGPS type
        info.ioBuffer = (u8() << 8) | u8()
        info.watchFaceType = u8()
        info.classicAddress = cstr()
        for n in flagOrderA { info.flags[n] = u8() }
        _ = cstr()                                   // default BLE name
        for n in flagOrderB { info.flags[n] = u8() }
        if info.ioBuffer < 128 || info.ioBuffer > 4096 { info.ioBuffer = 1018 }
        return info
    }

    func has(_ f: String) -> Bool { (flags[f] ?? 0) != 0 }
}
