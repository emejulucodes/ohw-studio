import SwiftUI

struct AssistantView: View {
    @EnvironmentObject var store: WatchStore
    @EnvironmentObject var ai: AssistantStore
    @State private var typed = ""
    @State private var keyField = ""
    @State private var trigger: WatchTrigger = .shutter

    static let examples = ["How many steps today?", "What's my heart rate?", "Set an alarm for 6:30 am", "What's the weather?",
                           "Start a run", "Next song", "What time is it in London?", "How's Bitcoin doing?",
                           "Give me a 2-minute breathing exercise", "Suggest a quick dinner idea"]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: "Assistant", subtitle: "Talk to your wrist. OHW Studio listens through the watch microphone, answers on the watch speaker and screen.")
            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 18) {
                    orb
                    Text(status).font(.headline)
                    Text(ai.phase == .listening ? (ai.partial.isEmpty ? "Listening on \(ai.micName)…" : "“\(ai.partial)”") : hint)
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .frame(maxWidth: 300, minHeight: 44)
                    HStack {
                        TextField("…or type a question", text: $typed).textFieldStyle(.roundedBorder).onSubmit(send)
                        Button("Ask", action: send).disabled(typed.isEmpty)
                    }
                    .frame(width: 320)
                }
                .padding(24)
                .frame(width: 380)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                conversation
            }
            HStack(alignment: .top, spacing: 14) {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Start from the watch", systemImage: "applewatch.radiowaves.left.and.right").font(.headline)
                        Text("Map a watch button to the assistant. Press it, speak, and the answer comes back on your wrist.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Picker("Button", selection: $trigger) { ForEach(WatchTrigger.allCases) { Text($0.title).tag($0) } }.frame(width: 220)
                            Button(store.mapping[trigger] == .assistant ? "Mapped ✓" : "Use this button") { store.mapping[trigger] = .assistant }
                                .disabled(store.mapping[trigger] == .assistant)
                        }
                        let mapped = WatchTrigger.allCases.filter { store.mapping[$0] == .assistant }
                        Text(mapped.isEmpty ? "No button mapped yet." : "Mapped to: " + mapped.map(\.title).joined(separator: ", "))
                            .font(.caption).foregroundStyle(mapped.isEmpty ? Color.orange : Color.ok)
                        Text("The camera shutter works well: open the camera on the watch, then tap the shutter to talk.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Settings", systemImage: "gearshape").font(.headline)
                        Toggle("Listen through the watch microphone", isOn: $ai.preferWatchMic)
                        if !ai.watchMicAvailable {
                            Text("The watch isn't connected as an audio device. Connect “OHW-11” in System Settings › Bluetooth to use its mic and speaker.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        Toggle("Speak answers aloud", isOn: $ai.speakReplies)
                        Toggle("Show answers on the watch screen", isOn: $ai.showOnWatch)
                        Toggle("Ask Claude when it isn't a built-in command", isOn: $ai.useClaude)
                        if ai.useClaude {
                            HStack {
                                SecureField(ai.hasKey ? "API key saved in Keychain" : "Claude API key (sk-ant-…)", text: $keyField)
                                    .textFieldStyle(.roundedBorder)
                                Button("Save") { ai.setKey(keyField); keyField = "" }.disabled(keyField.isEmpty)
                                if ai.hasKey { Button("Remove") { ai.setKey(nil) } }
                            }
                            Text("Questions go to Claude (claude-opus-5-5) with today's watch stats as context. The key stays in your Mac's Keychain.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Try saying").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(Self.examples, id: \.self) { e in
                            Button { ai.ask(e) } label: {
                                Text("“\(e)”").font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10).padding(.vertical, 7)
                                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    var status: String {
        switch ai.phase {
        case .idle: return "Tap to talk"
        case .listening: return "Listening…"
        case .thinking: return "Thinking…"
        case .speaking: return "Answering"
        }
    }
    var hint: String { ai.lastError ?? "Built-in commands work offline; anything else goes to Claude." }

    var orb: some View {
        let tint: Color = ai.phase == .listening ? .heart : ai.phase == .thinking ? .brand2 : ai.phase == .speaking ? .ok : .brand
        return Button { ai.toggle() } label: {
            ZStack {
                Circle().fill(tint.opacity(0.15)).frame(width: 190, height: 190)
                    .scaleEffect(ai.phase == .listening ? 1 + CGFloat(ai.level) * 0.35 : 1)
                    .animation(.easeOut(duration: 0.12), value: ai.level)
                Circle().fill(tint.opacity(0.25)).frame(width: 150, height: 150)
                Circle().fill(LinearGradient(colors: [tint, tint.opacity(0.65)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 112, height: 112).shadow(color: tint.opacity(0.6), radius: 20)
                Image(systemName: ai.phase == .listening ? "waveform" : ai.phase == .thinking ? "ellipsis" : ai.phase == .speaking ? "speaker.wave.2.fill" : "mic.fill")
                    .font(.system(size: 40, weight: .semibold)).foregroundStyle(.white)
                    .symbolEffect(.variableColor.iterative, isActive: ai.phase != .idle)
            }
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.space, modifiers: [.option])
        .help("Talk (⌥Space)")
    }

    var conversation: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text("Conversation").font(.headline); Spacer(); if !ai.turns.isEmpty { Button("Clear") { ai.turns = [] }.controlSize(.small) } }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if ai.turns.isEmpty {
                                Text("Your questions and the watch's answers appear here.").foregroundStyle(.secondary)
                            }
                            ForEach(ai.turns) { t in
                                HStack {
                                    if t.fromUser { Spacer(minLength: 60) }
                                    VStack(alignment: t.fromUser ? .trailing : .leading, spacing: 3) {
                                        Text(t.text).textSelection(.enabled)
                                            .padding(.horizontal, 12).padding(.vertical, 8)
                                            .background(t.fromUser ? Color.brand.opacity(0.85) : (t.source == "error" ? Color.red.opacity(0.2) : Color.white.opacity(0.08)),
                                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                            .foregroundStyle(t.fromUser ? .white : .primary)
                                        Text(t.fromUser ? t.date.formatted(date: .omitted, time: .shortened)
                                             : (t.source == "claude" ? "Claude" : t.source == "command" ? "Built-in" : "") )
                                            .font(.caption2).foregroundStyle(.tertiary)
                                    }
                                    if !t.fromUser { Spacer(minLength: 60) }
                                }
                                .id(t.id)
                            }
                            if ai.phase == .thinking { ProgressView().controlSize(.small).id("thinking") }
                        }
                    }
                    .frame(minHeight: 280, maxHeight: 340)
                    .onChange(of: ai.turns.count) { _, _ in withAnimation { proxy.scrollTo(ai.turns.last?.id) } }
                }
            }
        }
    }

    func send() { let q = typed.trimmingCharacters(in: .whitespaces); guard !q.isEmpty else { return }; typed = ""; ai.ask(q) }
}
