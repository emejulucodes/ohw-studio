import AppKit
import Foundation

// MARK: - shell helpers
enum Shell {
    /// Run osascript off the main thread; returns trimmed stdout.
    static func osascript(_ source: String, timeout: Double = 6) async -> String {
        await run("/usr/bin/osascript", ["-e", source], timeout: timeout)
    }

    static func run(_ path: String, _ args: [String], timeout: Double = 10) async -> String {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
                do { try p.run() } catch { cont.resume(returning: ""); return }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit(); killer.cancel()
                cont.resume(returning: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }
}

// MARK: - now playing (Spotify / Music)
struct NowPlaying: Equatable {
    var player: String
    var playing: Bool
    var title: String
    var artist: String
    var position: Int
    var volume: Int
}

@MainActor
final class MediaBridge: ObservableObject {
    @Published private(set) var now: NowPlaying?

    private static let script = """
    set sep to "|"
    if application "Spotify" is running then
      tell application "Spotify"
        try
          return "Spotify" & sep & (player state as string) & sep & (name of current track) & sep & (artist of current track) & sep & ((player position) as integer) & sep & sound volume
        end try
      end tell
    end if
    if application "Music" is running then
      tell application "Music"
        try
          return "Music" & sep & (player state as string) & sep & (name of current track) & sep & (artist of current track) & sep & ((player position) as integer) & sep & sound volume
        end try
      end tell
    end if
    return ""
    """

    func poll() async -> NowPlaying? {
        let out = await Shell.osascript(Self.script)
        let p = out.components(separatedBy: "|")
        let np: NowPlaying? = p.count >= 6
            ? NowPlaying(player: p[0], playing: p[1] == "playing", title: p[2], artist: p[3],
                         position: Int(p[4]) ?? 0, volume: Int(p[5]) ?? 0)
            : nil
        now = np
        return np
    }

    func control(_ verb: String) async {
        let player = now?.player ?? "Spotify"
        let cmd = ["playpause": "playpause", "play": "play", "pause": "pause", "next": "next track", "previous": "previous track"][verb] ?? verb
        _ = await Shell.osascript("if application \"\(player)\" is running then tell application \"\(player)\" to \(cmd)")
    }

    func systemVolume(delta: Int) async {
        _ = await Shell.osascript("set volume output volume ((output volume of (get volume settings)) + \(delta))")
    }
}

// MARK: - remote actions
enum WatchTrigger: String, CaseIterable, Identifiable, Codable {
    case playPause, next, previous, volumeUp, volumeDown, shutter, findPhone
    var id: String { rawValue }
    var title: String {
        switch self {
        case .playPause: return "Play / Pause"; case .next: return "Next track"; case .previous: return "Previous track"
        case .volumeUp: return "Volume up"; case .volumeDown: return "Volume down"
        case .shutter: return "Camera shutter"; case .findPhone: return "Find phone"
        }
    }
    var symbol: String {
        switch self {
        case .playPause: return "playpause.fill"; case .next: return "forward.fill"; case .previous: return "backward.fill"
        case .volumeUp: return "speaker.wave.3.fill"; case .volumeDown: return "speaker.wave.1.fill"
        case .shutter: return "camera.shutter.button.fill"; case .findPhone: return "iphone.radiowaves.left.and.right"
        }
    }
    var defaultAction: RemoteAction {
        switch self {
        case .playPause: return .playPause; case .next: return .nextTrack; case .previous: return .previousTrack
        case .volumeUp: return .volumeUp; case .volumeDown: return .volumeDown
        case .shutter: return .screenshot; case .findPhone: return .chime
        }
    }
}

enum RemoteAction: String, CaseIterable, Identifiable, Codable {
    case none, playPause, nextTrack, previousTrack, volumeUp, volumeDown, screenshot, lockScreen,
         nextSlide, previousSlide, chime, shortcut, assistant
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "Do nothing"; case .playPause: return "Play / Pause music"
        case .nextTrack: return "Next track"; case .previousTrack: return "Previous track"
        case .volumeUp: return "Volume up"; case .volumeDown: return "Volume down"
        case .screenshot: return "Take a screenshot"; case .lockScreen: return "Lock the Mac"
        case .nextSlide: return "Next slide (→)"; case .previousSlide: return "Previous slide (←)"
        case .chime: return "Ring the Mac"; case .shortcut: return "Run a Shortcut…"; case .assistant: return "Talk to the assistant"
        }
    }
}

// MARK: - weather (Open-Meteo, no API key)
struct WeatherNow: Equatable {
    var place: String
    var temp: Int, high: Int, low: Int
    var code: Int            // WMO
    var wind: Int, humidity: Int, uv: Int, precip: Int
    var days: [(code: Int, high: Int, low: Int)]
    static func == (a: WeatherNow, b: WeatherNow) -> Bool { a.place == b.place && a.temp == b.temp && a.code == b.code }

    /// WMO → watch weather code (BleWeather constants).
    static func smaCode(_ wmo: Int) -> Int {
        switch wmo {
        case 0, 1: return 1
        case 2: return 2
        case 3: return 3
        case 45, 48: return 9
        case 51...67, 80...82: return 4
        case 71...77, 85, 86: return 8
        case 95: return 5
        case 96, 99: return 6
        default: return 0
        }
    }
    static func symbol(_ wmo: Int) -> String {
        switch wmo {
        case 0, 1: return "sun.max.fill"; case 2: return "cloud.sun.fill"; case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"; case 51...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"; case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }
    static func describe(_ wmo: Int) -> String {
        switch wmo {
        case 0: return "Clear"; case 1: return "Mostly clear"; case 2: return "Partly cloudy"; case 3: return "Overcast"
        case 45, 48: return "Fog"; case 51...57: return "Drizzle"; case 61...67: return "Rain"; case 71...77: return "Snow"
        case 80...82: return "Showers"; case 85, 86: return "Snow showers"; case 95...99: return "Thunderstorm"
        default: return "—"
        }
    }

    private static func wx(_ cur: Int, _ hi: Int, _ lo: Int, _ code: Int, wind: Int, hum: Int, uv: Int, precip: Int) -> [UInt8] {
        func s8(_ v: Int) -> UInt8 { UInt8(bitPattern: Int8(clamping: v)) }
        return [s8(cur), s8(hi), s8(lo), UInt8(smaCode(code)), UInt8(clamping: wind), UInt8(clamping: hum),
                10, UInt8(clamping: uv), UInt8(precip & 0xff), UInt8((precip >> 8) & 0xff)]
    }
    var realtimePayload: [UInt8] { bleTime() + Self.wx(temp, high, low, code, wind: wind, hum: humidity, uv: uv, precip: precip) }
    var forecastPayload: [UInt8] {
        var p = bleTime()
        for i in 0..<3 {
            let d = i < days.count ? days[i] : (code: code, high: high, low: low)
            p += Self.wx((d.high + d.low) / 2, d.high, d.low, d.code, wind: wind, hum: humidity, uv: uv, precip: 0)
        }
        return p
    }
}

@MainActor
final class WeatherService: ObservableObject {
    @Published var city: String = UserDefaults.standard.string(forKey: "weatherCity") ?? ""
    @Published private(set) var now: WeatherNow?
    @Published private(set) var error: String?
    @Published private(set) var loading = false

    func setCity(_ c: String) {
        city = c.trimmingCharacters(in: .whitespaces)
        UserDefaults.standard.set(city, forKey: "weatherCity")
        UserDefaults.standard.removeObject(forKey: "weatherLat")
    }

    func refresh() async {
        guard !city.isEmpty else { return }
        loading = true; defer { loading = false }
        error = nil
        do {
            var lat = UserDefaults.standard.object(forKey: "weatherLat") as? Double
            var lon = UserDefaults.standard.object(forKey: "weatherLon") as? Double
            var place = UserDefaults.standard.string(forKey: "weatherPlace") ?? city
            if lat == nil || lon == nil {
                var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
                c.queryItems = [.init(name: "name", value: city), .init(name: "count", value: "1")]
                let (d, _) = try await URLSession.shared.data(from: c.url!)
                guard let j = try JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let r = (j["results"] as? [[String: Any]])?.first,
                      let la = r["latitude"] as? Double, let lo = r["longitude"] as? Double
                else { error = "Couldn't find “\(city)”."; return }
                lat = la; lon = lo
                place = [r["name"] as? String, r["country_code"] as? String].compactMap { $0 }.joined(separator: ", ")
                UserDefaults.standard.set(la, forKey: "weatherLat"); UserDefaults.standard.set(lo, forKey: "weatherLon")
                UserDefaults.standard.set(place, forKey: "weatherPlace")
            }
            var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
            c.queryItems = [.init(name: "latitude", value: String(lat!)), .init(name: "longitude", value: String(lon!)),
                            .init(name: "current", value: "temperature_2m,relative_humidity_2m,weather_code,wind_speed_10m,precipitation"),
                            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min,weather_code,uv_index_max"),
                            .init(name: "timezone", value: "auto"), .init(name: "forecast_days", value: "3")]
            let (d, _) = try await URLSession.shared.data(from: c.url!)
            guard let j = try JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let cur = j["current"] as? [String: Any], let daily = j["daily"] as? [String: Any] else {
                error = "Weather service returned no data."; return
            }
            func num(_ v: Any?) -> Double { (v as? Double) ?? Double((v as? Int) ?? 0) }
            let maxs = (daily["temperature_2m_max"] as? [Any])?.map(num) ?? []
            let mins = (daily["temperature_2m_min"] as? [Any])?.map(num) ?? []
            let codes = (daily["weather_code"] as? [Any])?.map { Int(num($0)) } ?? []
            let uvs = (daily["uv_index_max"] as? [Any])?.map(num) ?? []
            let days = (0..<min(3, maxs.count, mins.count, codes.count)).map {
                (code: codes[$0], high: Int(maxs[$0].rounded()), low: Int(mins[$0].rounded()))
            }
            now = WeatherNow(place: place, temp: Int(num(cur["temperature_2m"]).rounded()),
                             high: days.first?.high ?? 0, low: days.first?.low ?? 0,
                             code: Int(num(cur["weather_code"])), wind: Int(num(cur["wind_speed_10m"]).rounded()),
                             humidity: Int(num(cur["relative_humidity_2m"])), uv: Int((uvs.first ?? 0).rounded()),
                             precip: Int(num(cur["precipitation"]) * 10), days: days)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
