import SwiftUI
import AppKit

@main
enum Entry {
    static func main() {
        // headless helper for testing the face encoder: OHWStudio --render-faces <dir>
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-faces"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1])
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for s in FaceStyle.allCases {
                let b = s.build(FaceOptions())
                try? Data(b.blob).write(to: dir.appendingPathComponent("\(s.rawValue).bin"))
                try? b.preview.pngData()?.write(to: dir.appendingPathComponent("\(s.rawValue).png"))
                print("\(s.rawValue): \(b.blob.count) bytes, \(b.elements.count) elements")
            }
            return
        }
        if let i = args.firstIndex(of: "--render-composer"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1])
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for t in ComposerTemplates.all {
                let e = ComposerEngine()
                let d = t.make()
                let t0 = Date()
                let b = e.build(d)
                try? Data(b.blob).write(to: dir.appendingPathComponent("\(t.id).bin"))
                try? e.preview(d, .classic).pngData()?.write(to: dir.appendingPathComponent("\(t.id).png"))
                print("\(t.id): \(b.blob.count) bytes, \(b.elements.count) elements, \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            }
            return
        }
        OHWStudioApp.main()
    }
}

struct OHWStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = WatchStore()
    @StateObject private var composer = ComposerState()

    var body: some Scene {
        WindowGroup("OHW Studio", id: "main") {
            RootView()
                .environmentObject(store)
                .environmentObject(composer)
                .environmentObject(store.extras)
                .environmentObject(store.dev)
                .environmentObject(store.workout)
                .environmentObject(store.assistant)
                .environmentObject(store.contacts)
                .environmentObject(store.chip)
                .frame(minWidth: 1180, minHeight: 720)
                .preferredColorScheme(.dark)
                .tint(.brand)
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1240, height: 820)

        MenuBarExtra {
            MenuBarView().environmentObject(store).preferredColorScheme(.dark)
        } label: {
            Label(store.battery.map { "\($0)%" } ?? "OHW", systemImage: store.state == .ready ? "applewatch.radiowaves.left.and.right" : "applewatch.slash")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
