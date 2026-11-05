import Foundation

// JieLi RCSP — the chip vendor's own channel (GATT AE00: write AE01, notify AE02), used by CO FIT's JL SDK.
// Authentication (libjl_auth.so): Bluetooth E1 (SAFER+) with a fixed key and address baked into the library.
//   app → [00 + 16 random]   dev → [01 + E1(random)]   app → "\x02pass"
//   dev → [00 + 16 random]   app → [01 + E1(random)]   dev → "\x02pass"
// Frames: FE DC BA [flags: 0x80 command | 0x40 wants reply][opcode][len BE16][sn + params | status + sn + data] EF.
// Verified on the OHW-11 (2026-11-05): auth succeeds; TARGET_INFO and SYS_INFO answer; flash, file browse,
// device config and health opcodes answer status 2 (unsupported).

enum JLAuth {
    static let exp: [UInt8] = (0..<256).map { i in var v = 1; for _ in 0..<i { v = v * 45 % 257 }; return UInt8(v % 256) }
    static let log: [UInt8] = { var l = [UInt8](repeating: 0, count: 256); for (i, v) in exp.enumerated() { l[Int(v)] = UInt8(i) }; return l }()
    static let xorPos: Set<Int> = [0, 3, 4, 7, 8, 11, 12, 15]
    static let perm = [8, 11, 12, 15, 2, 1, 6, 5, 10, 9, 14, 13, 0, 7, 4, 3]
    static let bias: [[UInt8]] = (0...17).map { p in p < 2 ? [] : (0..<16).map { i in exp[Int(exp[(17 * p + i + 1) % 256])] } }
    static let key: [UInt8] = [0x06, 0x77, 0x5f, 0x87, 0x91, 0x8d, 0xd4, 0x23, 0x00, 0x5d, 0xf1, 0xd8, 0xcf, 0x0c, 0x14, 0x2b]
    static let addr: [UInt8] = [0x11, 0x22, 0x33, 0x33, 0x22, 0x11]

    static func keys(_ k0: [UInt8]) -> [[UInt8]] {
        var k = k0 + [k0.reduce(0, ^)]
        var out = [Array(k[0..<16])]
        for p in 2...17 {
            k = k.map { ($0 << 3) | ($0 >> 5) }
            out.append((0..<16).map { i in k[(p - 1 + i) % 17] &+ bias[p][i] })
        }
        return out
    }
    static func ar(_ key: [UInt8], _ input: [UInt8], prime: Bool = false) -> [UInt8] {
        let ks = keys(key); var x = input
        for r in 0..<8 {
            if prime && r == 2 { x = (0..<16).map { xorPos.contains($0) ? x[$0] ^ input[$0] : x[$0] &+ input[$0] } }
            let a = ks[2 * r], b = ks[2 * r + 1]
            x = (0..<16).map { xorPos.contains($0) ? x[$0] ^ a[$0] : x[$0] &+ a[$0] }
            x = (0..<16).map { xorPos.contains($0) ? exp[Int(x[$0])] : log[Int(x[$0])] }
            x = (0..<16).map { xorPos.contains($0) ? x[$0] &+ b[$0] : x[$0] ^ b[$0] }
            for layer in 0..<4 {
                var y = [UInt8](); y.reserveCapacity(16)
                for j in stride(from: 0, to: 16, by: 2) { y += [x[j] &* 2 &+ x[j + 1], x[j] &+ x[j + 1]] }
                x = layer < 3 ? perm.map { y[$0] } : y
            }
        }
        let k = ks[16]
        return (0..<16).map { xorPos.contains($0) ? x[$0] ^ k[$0] : x[$0] &+ k[$0] }
    }
    static let offsets: [(UInt8, Bool)] = [(233, true), (229, false), (223, true), (193, false), (179, true), (167, false), (149, true), (131, false),
                                           (233, false), (229, true), (223, false), (193, true), (179, false), (167, true), (149, false), (131, true)]
    static func e1(_ rand: [UInt8]) -> [UInt8] {
        let kt = (0..<16).map { offsets[$0].1 ? key[$0] &+ offsets[$0].0 : key[$0] ^ offsets[$0].0 }
        var t = ar(key, rand)
        t = (0..<16).map { (t[$0] ^ rand[$0]) &+ addr[$0 % 6] }
        return ar(kt, t, prime: true)
    }
    static func respond(_ challenge: [UInt8]) -> [UInt8] { [1] + e1(Array(challenge[1..<17])) }
}

struct ChipFact: Identifiable, Hashable { var id: String { name }; let name: String; let value: String }

@MainActor
final class JieLiChip: ObservableObject {
    unowned let link: WatchLink
    @Published var authed = false
    @Published var busy = false
    @Published var facts: [ChipFact] = []
    @Published var tones: [String] = []
    @Published var chipClock: String?
    @Published var log: [String] = []
    @Published var error: String?

    private var raw: [[UInt8]] = []
    private var buf: [UInt8] = []
    private var packets: [(UInt8, UInt8, [UInt8])] = []
    private var sn: UInt8 = 0

    init(link: WatchLink) { self.link = link }

    private func feed(_ d: [UInt8]) {
        if buf.isEmpty && !(d.count >= 3 && d[0] == 0xfe && d[1] == 0xdc && d[2] == 0xba) { raw.append(d); return }
        buf += d
        while buf.count >= 8 {
            guard let i = (0...(buf.count - 3)).first(where: { buf[$0] == 0xfe && buf[$0 + 1] == 0xdc && buf[$0 + 2] == 0xba }) else { buf.removeAll(); return }
            guard buf.count >= i + 7 else { return }
            let n = Int(buf[i + 5]) << 8 | Int(buf[i + 6])
            guard buf.count >= i + 8 + n else { return }
            packets.append((buf[i + 3], buf[i + 4], Array(buf[(i + 7)..<(i + 7 + n)])))
            buf.removeFirst(i + 8 + n)
        }
    }

    private func waitRaw(_ t: Double = 4) async -> [UInt8]? {
        let end = Date().addingTimeInterval(t)
        while Date() < end { if !raw.isEmpty { return raw.removeFirst() }; try? await Task.sleep(nanoseconds: 50_000_000) }
        return nil
    }

    func cmd(_ op: UInt8, _ params: [UInt8] = [], timeout: Double = 4) async -> [UInt8]? {
        sn &+= 1
        let body = [sn] + params
        link.jieliWrite([0xfe, 0xdc, 0xba, 0xc0, op, UInt8(body.count >> 8), UInt8(body.count & 0xff)] + body + [0xef])
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let i = packets.firstIndex(where: { $0.1 == op && $0.0 & 0x80 == 0 }) { return packets.remove(at: i).2 }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    func connect() async {
        guard link.jieliAvailable else { error = "The watch's JieLi service wasn't found."; return }
        busy = true; error = nil; defer { busy = false }
        link.onJieLi = { [weak self] d in self?.feed(d) }
        link.jieliListen(true)
        try? await Task.sleep(nanoseconds: 600_000_000)
        raw.removeAll(); packets.removeAll()
        var r = [UInt8](repeating: 0, count: 17); for i in 1..<17 { r[i] = .random(in: 0...255) }
        link.jieliWrite(r)
        guard let proof = await waitRaw() else { error = "The chip didn't answer the handshake."; return }
        log.append(proof == JLAuth.respond(r) ? "Chip proved it knows the key" : "Chip proof differs (continuing)")
        link.jieliWrite([2] + Array("pass".utf8))
        guard let ch = await waitRaw(), ch.count == 17 else { error = "No challenge from the chip."; return }
        link.jieliWrite(JLAuth.respond(ch))
        guard let ok = await waitRaw(), ok == [2] + Array("pass".utf8) else { error = "The chip rejected our answer."; return }
        authed = true
        log.append("Authenticated")
        await readInfo()
    }

    func disconnect() { link.jieliListen(false); link.onJieLi = nil; authed = false }

    func readInfo() async {
        var f: [ChipFact] = []
        if let b = await cmd(3, [0xff, 0xff, 0xff, 0xff, 0]), b.count > 2 {
            var i = 2
            while i + 1 < b.count {
                let len = Int(b[i]), type = b[i + 1]
                guard len > 0, i + 1 + len <= b.count else { break }
                let v = Array(b[(i + 2)..<(i + 1 + len)])
                switch type {
                case 0: if let x = v.first { f.append(.init(name: "RCSP protocol", value: "\(x >> 4).\(x & 15)")) }
                case 1: if v.count >= 5 { f.append(.init(name: "Low-power limit", value: "\(v[4])%")) }
                case 2: if v.count >= 6 { f.append(.init(name: "Classic BT address", value: v[0..<6].map { String(format: "%02X", $0) }.joined(separator: ":"))) }
                case 4: if v.count >= 5 { f.append(.init(name: "Function mask", value: String(format: "0x%08X", v[0..<4].reduce(0) { $0 << 8 | UInt32($1) }))) }
                case 5: if v.count >= 2 { let c = Int(v[0]) << 8 | Int(v[1]); f.append(.init(name: "Chip firmware", value: "\(c >> 12 & 15).\(c >> 8 & 15).\(c >> 4 & 15).\(c & 15)")) }
                case 6: if let x = v.first { f.append(.init(name: "SDK type", value: "\(x)")) }
                case 7: if v.count == 2 { f.append(.init(name: "Bootloader", value: String(format: "%X.%X.%X.%X", v[0] >> 4, v[0] & 15, v[1] >> 4, v[1] & 15))) }
                case 8: if v.count >= 3 { f.append(.init(name: "OTA layout", value: (v[0] == 1 ? "double backup" : "single backup") + (v[1] == 1 ? ", needs loader" : ""))) }
                case 10: if v.count >= 4 { f.append(.init(name: "Vendor / product", value: String(format: "VID 0x05D6  UID %d  PID 0x%04X", Int(v[0]) << 8 | Int(v[1]), Int(v[2]) << 8 | Int(v[3])))) }
                case 13: if v.count >= 4 { f.append(.init(name: "RCSP MTU", value: "\(Int(v[0]) << 8 | Int(v[1])) / \(Int(v[2]) << 8 | Int(v[3])) bytes")) }
                case 17: if let x = v.first { f.append(.init(name: "BLE only", value: x == 1 ? "yes" : "no (dual mode)")) }
                default: break
                }
                i += 1 + len
            }
        }
        if let s = await cmd(2) { f.append(.init(name: "Feature map", value: s.first == 0 ? Data(s.dropFirst(2)).map { String(format: "%02x", $0) }.joined() : "not supported")) }
        // System info, function 2 (RTC): [len][attr][…] — attr 0 = chip clock, 5 = alarm tone list.
        if let r = await cmd(7, [2, 0xff, 0xff, 0xff, 0xff]), r.count > 3 {
            var i = 3
            while i + 1 < r.count {
                let len = Int(r[i]); let attr = r[i + 1]
                guard len > 0, i + 1 + len <= r.count else { break }
                let v = Array(r[(i + 2)..<(i + 1 + len)])
                if attr == 0, v.count >= 7 {
                    chipClock = String(format: "%04d-%02d-%02d %02d:%02d:%02d", Int(v[0]) | Int(v[1]) << 8, v[2], v[3], v[4], v[5], v[6])
                }
                if attr == 5 { tones = Self.parseTones(v) }
                i += 1 + len
            }
        }
        facts = f
    }

    /// Tone list: [count] then [index][len][name + NUL]… The first is "提示音0" ("prompt tone 0"), the rest just "1"…"9".
    static func parseTones(_ v: [UInt8]) -> [String] {
        guard let n = v.first else { return [] }
        var out: [String] = []; var i = 1
        while out.count < Int(n), i + 1 < v.count {
            let idx = Int(v[i]), len = Int(v[i + 1])
            guard i + 2 + len <= v.count else { break }
            _ = String(bytes: v[(i + 2)..<(i + 2 + len)].filter { $0 != 0 }, encoding: .utf8)
            out.append("Tone \(idx)")
            i += 2 + len
        }
        return out
    }
}
