import AppKit
import AVFoundation
import CoreAudio
import AudioToolbox
import Speech
import Security

// MARK: - Wrist voice assistant
// The OHW-11's microphone and speaker are the Mac's Bluetooth hands-free audio device (HFP), so OHW Studio
// can listen through the watch, transcribe on the Mac (Apple Speech), act on commands, ask Claude for
// everything else, then answer through the watch speaker and on the watch screen (notification).

struct AssistantTurn: Identifiable {
    let id = UUID()
    let date = Date()
    let fromUser: Bool
    let text: String
    var source: String = ""      // "command", "claude", "error"
}

enum Keychain {
    static let service = "dev.emejulu.ohwstudio.anthropic"
    static func read() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func write(_ v: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        guard let v, !v.isEmpty else { return }
        var add = base; add[kSecValueData as String] = Data(v.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Raw HTTP client for the Claude Messages API (no official Swift SDK).
enum ClaudeClient {
    struct Failure: Error, LocalizedError { let message: String; var errorDescription: String? { message } }

    static func ask(_ history: [(user: Bool, text: String)], system: String, key: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        let body: [String: Any] = [
            "model": "claude-opus-5-5",
            "max_tokens": 2048,
            "output_config": ["effort": "low"],       // quick spoken answers
            "fallbacks": "default",                    // route policy refusals to a suitable fallback model
            "system": system,
            "messages": history.map { ["role": $0.user ? "user" : "assistant", "content": $0.text] },
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let msg = ((obj["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(status)"
            throw Failure(message: status == 401 ? "The Claude API key was rejected." : msg)
        }
        if obj["stop_reason"] as? String == "refusal" { return "Sorry, I can't help with that one." }
        let text = (obj["content"] as? [[String: Any]] ?? [])
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "I don't have an answer for that." : text
    }
}

@MainActor
final class AssistantStore: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    enum Phase: Equatable { case idle, listening, thinking, speaking }
    unowned let store: WatchStore

    @Published var phase: Phase = .idle
    @Published var partial = ""
    @Published var turns: [AssistantTurn] = []
    @Published var level: Float = 0
    @Published var micName = "—"
    @Published var useClaude = UserDefaults.standard.object(forKey: "assistClaude") as? Bool ?? true { didSet { UserDefaults.standard.set(useClaude, forKey: "assistClaude") } }
    @Published var speakReplies = UserDefaults.standard.object(forKey: "assistSpeak") as? Bool ?? true { didSet { UserDefaults.standard.set(speakReplies, forKey: "assistSpeak") } }
    @Published var showOnWatch = UserDefaults.standard.object(forKey: "assistShow") as? Bool ?? true { didSet { UserDefaults.standard.set(showOnWatch, forKey: "assistShow") } }
    @Published var preferWatchMic = UserDefaults.standard.object(forKey: "assistWatchMic") as? Bool ?? true { didSet { UserDefaults.standard.set(preferWatchMic, forKey: "assistWatchMic") } }
    @Published var hasKey = Keychain.read() != nil
    @Published var lastError: String?

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var hardStop: Timer?
    private let synth = AVSpeechSynthesizer()
    private var finished = false

    init(store: WatchStore) {
        self.store = store
        super.init()
        synth.delegate = self
    }

    func setKey(_ k: String?) { Keychain.write(k?.trimmingCharacters(in: .whitespacesAndNewlines)); hasKey = Keychain.read() != nil }

    // MARK: listening

    func toggle() { if phase == .listening { stopListening() } else { Task { await listen() } } }

    func listen() async {
        guard phase == .idle || phase == .speaking else { return }
        synth.stopSpeaking(at: .immediate)
        lastError = nil
        guard await permissions() else { return }
        guard let recognizer, recognizer.isAvailable else { fail("Speech recognition isn't available right now."); return }

        if preferWatchMic, let id = Self.inputDevice(containing: "OHW") {
            Self.setInput(id, on: engine); micName = "OHW-11 watch"
        } else {
            micName = Self.defaultInputName() ?? "Mac microphone"
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        req.addsPunctuation = true
        request = req
        partial = ""; finished = false

        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { fail("No microphone input is available."); return }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            req.append(buf)
            let n = Int(buf.frameLength)
            if let ch = buf.floatChannelData?[0], n > 0 {
                var s: Float = 0
                for i in 0..<n { s += ch[i] * ch[i] }
                let rms = sqrt(s / Float(n))
                Task { @MainActor in self?.level = min(1, rms * 12) }
            }
        }
        do { engine.prepare(); try engine.start() } catch { fail("Couldn't start the microphone: \(error.localizedDescription)"); return }

        NSSound(named: "Tink")?.play()       // audible cue on the watch speaker
        phase = .listening
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self, !self.finished else { return }
                if let r = result {
                    self.partial = r.bestTranscription.formattedString
                    self.armSilence()
                    if r.isFinal { self.finish() }
                } else if error != nil {
                    self.finish()
                }
            }
        }
        // stop if nothing is said, or after a long sentence
        hardStop?.invalidate()
        hardStop = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
    }

    private func armSilence() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
    }

    func stopListening() { finish() }

    private func finish() {
        guard phase == .listening, !finished else { return }
        finished = true
        silenceTimer?.invalidate(); hardStop?.invalidate()
        engine.stop(); engine.inputNode.removeTap(onBus: 0)
        request?.endAudio(); task?.cancel()
        level = 0
        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { phase = .idle; return }
        turns.append(AssistantTurn(fromUser: true, text: text))
        phase = .thinking
        Task { await answer(text) }
    }

    private func permissions() async -> Bool {
        let speech: Bool = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard speech else { fail("Allow Speech Recognition for OHW Studio in System Settings › Privacy & Security."); return false }
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        guard mic else { fail("Allow Microphone access for OHW Studio in System Settings › Privacy & Security."); return false }
        return true
    }

    private func fail(_ s: String) { lastError = s; phase = .idle; store.show(s, "exclamationmark.triangle.fill", error: true) }

    // MARK: answering

    func ask(_ text: String) {
        guard phase == .idle || phase == .speaking else { return }
        synth.stopSpeaking(at: .immediate)
        turns.append(AssistantTurn(fromUser: true, text: text))
        phase = .thinking
        Task { await answer(text) }
    }

    private func answer(_ text: String) async {
        if let local = await AssistantCommands.handle(text, store: store) {
            await reply(local, source: "command")
            return
        }
        guard useClaude else {
            await reply("I can tell you your steps, heart rate, battery, weather and the time, set alarms, control music, or start a workout. Add a Claude API key for anything else.", source: "command")
            return
        }
        guard let key = Keychain.read() else {
            await reply("Add a Claude API key on the Assistant page so I can answer questions like that.", source: "error"); return
        }
        let history = turns.suffix(10).map { (user: $0.fromUser, text: $0.text) }
        do {
            let a = try await ClaudeClient.ask(history, system: systemPrompt(), key: key)
            await reply(a, source: "claude")
        } catch {
            await reply("I couldn't reach Claude. \(error.localizedDescription)", source: "error")
        }
    }

    private func systemPrompt() -> String {
        let s = store
        var ctx = "Today: \(Date().formatted(date: .complete, time: .shortened)). Watch: OHW-11."
        ctx += " Steps today \(s.todaySteps), energy \(Int(s.todayKcal)) kcal, distance \(String(format: "%.1f", s.todayKm)) km."
        if let g = s.settings.stepGoal { ctx += " Step goal \(g)." }
        if let b = s.battery { ctx += " Watch battery \(b)%." }
        if let hr = s.liveHR ?? s.heartRates.last?.bpm { ctx += " Latest heart rate \(hr) bpm." }
        if let w = s.weather.now { ctx += " Weather in \(w.place): \(w.temp)°C, \(WeatherNow.describe(w.code))." }
        return """
        You are the voice assistant on the user's OHW-11 smartwatch. Your answer is spoken aloud through the watch speaker \
        and shown on its small screen, so reply in one to three short, plain sentences with no markdown, lists or emoji. \
        Be warm and direct. If a question needs live information you don't have, say so briefly.
        Context: \(ctx)
        """
    }

    func reply(_ text: String, source: String) async {
        turns.append(AssistantTurn(fromUser: false, text: text, source: source))
        if showOnWatch && store.ready {
            await store.sendNotification(title: "Assistant", body: String(text.prefix(240)), app: "com.apple.siri")
        }
        if speakReplies {
            phase = .speaking
            let u = AVSpeechUtterance(string: text)
            u.voice = AVSpeechSynthesisVoice(language: "en-US")
            u.rate = 0.52
            synth.speak(u)
        } else {
            phase = .idle
        }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in if self.phase == .speaking { self.phase = .idle } }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in if self.phase == .speaking { self.phase = .idle } }
    }

    // MARK: Core Audio device helpers

    static func devices() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }
    static func name(_ id: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf) == noErr, let s = cf?.takeRetainedValue() else { return nil }
        return s as String
    }
    static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }
    static func inputDevice(containing s: String) -> AudioDeviceID? {
        devices().first { hasInput($0) && (name($0)?.localizedCaseInsensitiveContains(s) ?? false) }
    }
    static func defaultInputName() -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return nil }
        return name(id)
    }
    static func setInput(_ id: AudioDeviceID, on engine: AVAudioEngine) {
        guard let unit = engine.inputNode.audioUnit else { return }
        var dev = id
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
    }
    var watchMicAvailable: Bool { Self.inputDevice(containing: "OHW") != nil }
}

// MARK: - built-in commands (answered without the network)

enum AssistantCommands {
    @MainActor
    static func handle(_ raw: String, store s: WatchStore) async -> String? {
        let t = raw.lowercased()
        func has(_ words: String...) -> Bool { words.contains { t.contains($0) } }
        let ex = s.extras, w = s.workout

        // time & date
        if has("what time", "the time") && !has("london", "new york", "tokyo", " in ") {
            return "It's \(Date().formatted(date: .omitted, time: .shortened))."
        }
        if has("what's the date", "what is the date", "what day is it", "today's date") {
            return "Today is \(Date().formatted(date: .complete, time: .omitted))."
        }
        // world clock
        if has("time in ") {
            let after = t.components(separatedBy: "time in ").last?.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) ?? ""
            if let c = (ex.cities + WorldCity.catalog).first(where: { after.contains($0.name.lowercased()) }), let tz = TimeZone(identifier: c.tz) {
                let f = DateFormatter(); f.timeZone = tz; f.timeStyle = .short
                return "It's \(f.string(from: Date())) in \(c.name)."
            }
        }
        // activity
        if has("step") {
            let goal = s.settings.stepGoal ?? 8000
            let pct = Int(Double(s.todaySteps) / Double(max(1, goal)) * 100)
            return "You've taken \(s.todaySteps.formatted()) steps today, \(pct) percent of your \(goal.formatted()) step goal."
        }
        if has("calorie", "energy", "burned") { return "You've burned about \(Int(s.todayKcal)) kilocalories today." }
        if has("distance", "how far", "kilomet") { return String(format: "You've covered %.1f kilometres today.", s.todayKm) }
        // heart
        if has("measure", "check") && has("heart") {
            if !s.liveHRRunning { await s.toggleLiveHR() }
            return "Measuring your heart rate now. Keep the watch snug on your wrist."
        }
        if has("heart rate", "pulse", "heart") {
            if let v = s.liveHR ?? s.heartRates.last?.bpm { return "Your latest heart rate is \(v) beats per minute." }
            return "I don't have a heart-rate reading yet. Say \"measure my heart rate\" to take one."
        }
        // battery
        if has("battery", "charge") {
            if let b = s.battery { return "Your watch battery is at \(b) percent." }
            return "I can't read the battery while the watch is disconnected."
        }
        // weather
        if has("weather", "temperature", "rain", "hot", "cold outside") {
            if let x = s.weather.now {
                return "It's \(x.temp) degrees and \(WeatherNow.describe(x.code).lowercased()) in \(x.place), with a high of \(x.high) and a low of \(x.low)."
            }
            return "Set your city on the Weather page and I'll tell you the forecast."
        }
        // alarms
        if has("alarm") {
            if has("cancel", "delete", "remove", "clear", "turn off") {
                ex.alarms.removeAll(); await ex.saveAlarms(); return "All alarms are cleared."
            }
            if has("next") { return nextAlarm(ex.alarms).map { "Your next alarm is \($0)." } ?? "You have no alarms set." }
            if let (h, m) = parseTime(t) {
                var a = WatchAlarm(hour: h, minute: m); a.repeatDays = []; a.label = "Voice alarm"
                if !ex.alarmsLoaded { await ex.loadAlarms() }
                ex.alarms.append(a); await ex.saveAlarms()
                let d = Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date()
                return "Done. Your watch will vibrate at \(d.formatted(date: .omitted, time: .shortened))."
            }
        }
        // workouts
        if has("workout", "run", "jog", "cycling", "ride", "bike", "treadmill") {
            if has("stop", "end", "finish") { await w.end(); return "Workout ended. Nice work." }
            if has("pause") { await w.pause(); return "Workout paused." }
            if has("resume", "continue") { await w.resume(); return "Resuming your workout." }
            if has("start", "begin", "go for") {
                w.setMode(has("cycl", "ride", "bike") ? .cycling : has("treadmill", "indoor") ? .indoorRun : .outdoorRun)
                await w.start()
                return "Starting your \(w.mode.title.lowercased()). Have a good one."
            }
        }
        // music
        if has("next song", "next track", "skip") { await s.media.control("next"); return "Skipping to the next track." }
        if has("previous song", "previous track", "go back") { await s.media.control("previous"); return "Going back a track." }
        if has("pause music", "stop music", "pause the music") { await s.media.control("pause"); return "Music paused." }
        if has("play music", "resume music", "play some music") { await s.media.control("play"); return "Playing your music." }
        if has("what's playing", "what song", "what is playing") {
            if let n = s.media.now { return "This is \(n.title) by \(n.artist)." }
            return "Nothing is playing right now."
        }
        // find watch
        if has("find my watch", "ring my watch", "where is my watch") { await s.findWatch(); return "Ringing your watch." }
        // stocks
        if has("stock", "price of", "bitcoin", "shares") {
            if let q = ex.stocks.first(where: { t.contains($0.symbol.lowercased().replacingOccurrences(of: "-usd", with: "")) || (!$0.name.isEmpty && t.contains($0.name.lowercased().components(separatedBy: " ").first ?? "~")) || (t.contains("bitcoin") && $0.symbol.hasPrefix("BTC")) }) {
                let up = q.change >= 0
                return String(format: "%@ is at %.2f, %@ %.1f percent today.", q.name.isEmpty ? q.symbol : q.name, q.price, up ? "up" : "down", abs(q.percent))
            }
        }
        return nil
    }

    /// "7", "7:30", "7 30 pm", "seven", "half past six"… → 24 h time
    static func parseTime(_ t: String) -> (Int, Int)? {
        let words = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12]
        var s = t
        for (w, n) in words { s = s.replacingOccurrences(of: w, with: "\(n)") }
        let pm = s.contains("pm") || s.contains("p.m") || s.contains("evening") || s.contains("tonight")
        let am = s.contains("am") || s.contains("a.m") || s.contains("morning")
        guard let re = try? NSRegularExpression(pattern: "(\\d{1,2})(?:[:. ](\\d{2}))?"),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let hr = Range(m.range(at: 1), in: s), var h = Int(s[hr]) else { return nil }
        var mi = 0
        if let r = Range(m.range(at: 2), in: s) { mi = Int(s[r]) ?? 0 }
        if s.contains("half past") { mi = 30 }
        if pm && h < 12 { h += 12 }
        if am && h == 12 { h = 0 }
        guard (0...23).contains(h), (0...59).contains(mi) else { return nil }
        return (h, mi)
    }
}
