import AppKit
import SwiftUI

// MARK: - saved designs (~/Library/Application Support/OHW Studio/Designs/*.ohwface)

enum DesignLibrary {
    static var dir: URL {
        let d = WatchStore.supportDir.appendingPathComponent("Designs", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func url(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).ohwface") }

    static func encode(_ d: FaceDoc) throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return try e.encode(d)
    }

    /// Decode tolerantly: any field missing from an older file takes its default value.
    static func decode(_ data: Data) -> FaceDoc? {
        guard var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func dict<T: Encodable>(_ v: T) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(v))) as? [String: Any] ?? [:]
        }
        func merge(_ base: Any, _ over: Any) -> Any {
            guard let b = base as? [String: Any], let o = over as? [String: Any] else { return over }
            var r = b
            for (k, v) in o { r[k] = b[k].map { merge($0, v) } ?? v }
            return r
        }
        let layers = (obj["layers"] as? [[String: Any]] ?? []).compactMap { l -> Any? in
            guard let k = (l["kind"] as? String).flatMap(LayerKind.init(rawValue:)) else { return nil }
            return merge(dict(Layer.make(k)), l)
        }
        obj["layers"] = []
        var merged = merge(dict(FaceDoc()), obj) as! [String: Any]
        merged["layers"] = layers
        guard let d = try? JSONSerialization.data(withJSONObject: merged) else { return nil }
        return try? JSONDecoder().decode(FaceDoc.self, from: d)
    }

    static func save(_ d: FaceDoc) { try? encode(d).write(to: url(d.id), options: .atomic) }
    static func delete(_ id: UUID) { try? FileManager.default.removeItem(at: url(id)) }

    static func list() -> [FaceDoc] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "ohwface" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap(decode) }
            .sorted { $0.modified > $1.modified }
    }
}

// MARK: - editor state

@MainActor
final class ComposerState: ObservableObject {
    @Published var doc: FaceDoc {
        didSet {
            guard doc != oldValue else { return }
            scheduleRender(); scheduleSave(); scheduleSize()
        }
    }
    @Published var selection: Set<UUID> = []
    @Published private(set) var preview: CGImage?
    @Published var liveClock = true { didSet { scheduleRender() } }
    @Published var sample = Sample.classic { didSet { scheduleRender() } }
    @Published var guidesX: [CGFloat] = []
    @Published var guidesY: [CGFloat] = []
    @Published var showGrid = false
    @Published var showSafeArea = true
    @Published private(set) var buildBytes: Int?
    @Published private(set) var buildElements: Int = 0
    @Published var designs: [FaceDoc] = []
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    let engine = ComposerEngine()
    private var undoStack: [FaceDoc] = [], redoStack: [FaceDoc] = []
    private var coalesceKey: String?
    private var coalesceAt = Date.distantPast
    private var renderPending = false
    private var saveTask: Task<Void, Never>?
    private var sizeTask: Task<Void, Never>?
    private var timer: Timer?

    init() {
        let saved = DesignLibrary.list()
        if let last = UserDefaults.standard.string(forKey: "composerLast").flatMap(UUID.init(uuidString:)),
           let d = saved.first(where: { $0.id == last }) {
            doc = d
        } else if let d = saved.first {
            doc = d
        } else {
            doc = ComposerTemplates.aurora()
            DesignLibrary.save(doc)
        }
        designs = DesignLibrary.list()
        UserDefaults.standard.set(doc.id.uuidString, forKey: "composerLast")
        render(); scheduleSize()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.liveClock == true { self?.scheduleRender() } }
        }
    }

    var currentSample: Sample { liveClock ? sample.at(Date()) : sample }

    // MARK: rendering

    func scheduleRender() {
        guard !renderPending else { return }
        renderPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.renderPending = false
            self.render()
        }
    }

    func render() { preview = engine.preview(doc, currentSample) }

    func bounds(_ l: Layer) -> CGRect { engine.bounds(l, sample: currentSample, twelveHour: engine.twelveHour(doc)) }

    private func scheduleSave() {
        saveTask?.cancel()
        let d = doc
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            DesignLibrary.save(d)
            self?.refreshDesignList(keeping: d)
        }
    }

    private func refreshDesignList(keeping d: FaceDoc) {
        if let i = designs.firstIndex(where: { $0.id == d.id }) { designs[i] = d } else { designs.insert(d, at: 0) }
    }

    private func scheduleSize() {
        sizeTask?.cancel()
        let d = doc
        sizeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            let r = await Task.detached(priority: .utility) { () -> (Int, Int) in
                let b = ComposerEngine().build(d); return (b.blob.count, b.elements.count)
            }.value
            guard !Task.isCancelled else { return }
            self?.buildBytes = r.0; self?.buildElements = r.1
        }
    }

    func makeBuild() async -> FaceBuild {
        let d = doc
        return await Task.detached(priority: .userInitiated) { ComposerEngine().build(d) }.value
    }

    // MARK: undo

    /// Apply a change. Consecutive changes with the same key within a second form one undo step.
    func mutate(_ key: String? = nil, record: Bool = true, _ f: (inout FaceDoc) -> Void) {
        var d = doc
        f(&d)
        guard d != doc else { return }
        let now = Date()
        if record && (key == nil || key != coalesceKey || now.timeIntervalSince(coalesceAt) > 1) {
            pushUndo()
        }
        coalesceKey = key; coalesceAt = now
        d.modified = now
        doc = d
    }

    func checkpoint() { pushUndo(); coalesceKey = nil }

    /// Drop the checkpoint of a gesture that ended up changing nothing.
    func endGesture() {
        if let last = undoStack.last, last == doc { undoStack.removeLast(); canUndo = !undoStack.isEmpty }
        scheduleSize()
    }

    private func pushUndo() {
        undoStack.append(doc)
        if undoStack.count > 150 { undoStack.removeFirst() }
        redoStack.removeAll()
        canUndo = true; canRedo = false
    }

    func undo() {
        guard let p = undoStack.popLast() else { return }
        redoStack.append(doc); doc = p
        selection = selection.filter { id in doc.layers.contains { $0.id == id } }
        canUndo = !undoStack.isEmpty; canRedo = true; coalesceKey = nil
    }

    func redo() {
        guard let n = redoStack.popLast() else { return }
        undoStack.append(doc); doc = n
        canUndo = true; canRedo = !redoStack.isEmpty; coalesceKey = nil
    }

    // MARK: layers

    func layer(_ id: UUID) -> Layer? { doc.layers.first { $0.id == id } }
    var selectedLayers: [Layer] { doc.layers.filter { selection.contains($0.id) } }
    var single: Layer? { selection.count == 1 ? selectedLayers.first : nil }

    func update(_ id: UUID, _ key: String? = nil, record: Bool = true, _ f: (inout Layer) -> Void) {
        mutate(key.map { "\(id)\($0)" }, record: record) { d in
            if let i = d.layers.firstIndex(where: { $0.id == id }) { f(&d.layers[i]) }
        }
    }

    func add(_ kind: LayerKind, at p: CGPoint? = nil) {
        guard doc.canAdd(kind) else { return }
        var l = Layer.make(kind, at: p ?? CGPoint(x: 205, y: 251))
        l.name = uniqueName(kind.title)
        insert([l])
    }

    func insert(_ ls: [Layer]) {
        mutate { d in d.layers.append(contentsOf: ls) }
        selection = Set(ls.map(\.id))
    }

    func addWidget(_ w: ComposerTemplates.Widget) {
        let ls = w.make(CGPoint(x: 205, y: 251)).filter { !$0.kind.isLive || doc.canAdd($0.kind) }
        insert(ls)
    }

    func addImage(_ url: URL, at p: CGPoint? = nil) {
        guard let data = Self.imageData(url, maxPixel: 900, png: true) else { return }
        var l = Layer.make(.image, at: p ?? CGPoint(x: 205, y: 251))
        if let img = Ink.decode(data) {
            let sc = min(220 / Double(img.width), 220 / Double(img.height))
            l.w = (Double(img.width) * sc).rounded(); l.h = (Double(img.height) * sc).rounded()
        }
        l.imageData = data
        l.name = url.deletingPathExtension().lastPathComponent
        insert([l])
    }

    func setPhoto(_ url: URL) {
        guard let data = Self.imageData(url, maxPixel: 1400, png: false) else { return }
        mutate { d in d.background.kind = .photo; d.background.photo = data }
    }

    static func imageData(_ url: URL, maxPixel: Int, png: Bool) -> Data? {
        guard let data = try? Data(contentsOf: url), let img = Ink.decode(data, maxPixel: maxPixel) else { return nil }
        let rep = NSBitmapImageRep(cgImage: img)
        return png ? rep.representation(using: .png, properties: [:])
                   : rep.representation(using: .jpeg, properties: [.compressionFactor: 0.88])
    }

    func uniqueName(_ base: String) -> String {
        let names = Set(doc.layers.map(\.name))
        if !names.contains(base) { return base }
        var i = 2
        while names.contains("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }

    func deleteSelection() {
        let ids = selection
        guard !ids.isEmpty else { return }
        mutate { d in d.layers.removeAll { ids.contains($0.id) } }
        selection = []
    }

    func duplicateSelection() {
        var copies: [Layer] = []
        for l in selectedLayers where !l.kind.isLive {
            var c = l; c.id = UUID(); c.x += 16; c.y += 16; c.name = uniqueName(l.name); copies.append(c)
        }
        guard !copies.isEmpty else { return }
        insert(copies)
    }

    func move(by dx: Double, _ dy: Double) {
        let ids = selection
        guard !ids.isEmpty else { return }
        mutate("nudge") { d in
            for i in d.layers.indices where ids.contains(d.layers[i].id) && !d.layers[i].locked {
                d.layers[i].x += dx; d.layers[i].y += dy
            }
        }
    }

    /// Move a layer up/down the stack (within artwork or within live layers).
    func reorder(_ id: UUID, by delta: Int) {
        mutate { d in
            guard let i = d.layers.firstIndex(where: { $0.id == id }) else { return }
            let live = d.layers[i].kind.isLive
            let peers = d.layers.indices.filter { d.layers[$0].kind.isLive == live }
            guard let pi = peers.firstIndex(of: i) else { return }
            let tj = pi + delta
            guard tj >= 0, tj < peers.count else { return }
            d.layers.swapAt(i, peers[tj])
        }
    }

    func moveToEdge(_ id: UUID, front: Bool) {
        mutate { d in
            guard let i = d.layers.firstIndex(where: { $0.id == id }) else { return }
            let l = d.layers.remove(at: i)
            if front { d.layers.append(l) } else { d.layers.insert(l, at: 0) }
        }
    }

    enum Align { case left, hcenter, right, top, vcenter, bottom }

    func align(_ a: Align) {
        let ls = selectedLayers.filter { !$0.locked }
        guard !ls.isEmpty else { return }
        let rects = Dictionary(uniqueKeysWithValues: ls.map { ($0.id, bounds($0)) })
        let ref: CGRect = ls.count == 1 ? CGRect(x: 0, y: 0, width: FaceKit.W, height: FaceKit.H)
                                        : rects.values.reduce(rects.values.first!) { $0.union($1) }
        mutate { d in
            for i in d.layers.indices {
                guard let r = rects[d.layers[i].id] else { continue }
                switch a {
                case .left: d.layers[i].x += ref.minX - r.minX
                case .hcenter: d.layers[i].x += ref.midX - r.midX
                case .right: d.layers[i].x += ref.maxX - r.maxX
                case .top: d.layers[i].y += ref.minY - r.minY
                case .vcenter: d.layers[i].y += ref.midY - r.midY
                case .bottom: d.layers[i].y += ref.maxY - r.maxY
                }
            }
        }
    }

    func distribute(horizontal: Bool) {
        let ls = selectedLayers.filter { !$0.locked }.sorted { horizontal ? $0.x < $1.x : $0.y < $1.y }
        guard ls.count > 2, let a = ls.first, let b = ls.last else { return }
        mutate { d in
            for (k, l) in ls.enumerated() {
                guard let i = d.layers.firstIndex(where: { $0.id == l.id }) else { continue }
                let t = Double(k) / Double(ls.count - 1)
                if horizontal { d.layers[i].x = a.x + (b.x - a.x) * t } else { d.layers[i].y = a.y + (b.y - a.y) * t }
            }
        }
    }

    // MARK: documents

    func open(_ d: FaceDoc) {
        DesignLibrary.save(doc)
        undoStack = []; redoStack = []; canUndo = false; canRedo = false
        selection = []
        doc = d
        UserDefaults.standard.set(d.id.uuidString, forKey: "composerLast")
        designs = DesignLibrary.list()
    }

    func newFrom(_ t: ComposerTemplates.Template) {
        var d = t.make()
        d.id = UUID(); d.modified = Date()
        DesignLibrary.save(d)
        open(d)
    }

    func duplicateDesign(_ src: FaceDoc) {
        var d = src
        d.id = UUID(); d.name = src.name + " copy"; d.modified = Date()
        DesignLibrary.save(d)
        designs = DesignLibrary.list()
    }

    func deleteDesign(_ d: FaceDoc) {
        DesignLibrary.delete(d.id)
        designs = DesignLibrary.list()
        if d.id == doc.id {
            if let n = designs.first { open(n) } else { newFrom(ComposerTemplates.all[0]) }
        }
    }

    func importDesign(_ url: URL) {
        guard let data = try? Data(contentsOf: url), var d = DesignLibrary.decode(data) else { return }
        d.id = UUID(); d.modified = Date()
        DesignLibrary.save(d)
        open(d)
    }

    func exportDesign(to url: URL) { try? DesignLibrary.encode(doc).write(to: url) }
}
