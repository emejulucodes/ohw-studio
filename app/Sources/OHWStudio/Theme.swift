import SwiftUI

extension Color {
    static let brand = Color(red: 1.0, green: 0.62, blue: 0.04)
    static let brand2 = Color(red: 0.37, green: 0.36, blue: 0.90)
    static let ok = Color(red: 0.19, green: 0.82, blue: 0.35)
    static let heart = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let sky = Color(red: 0.39, green: 0.82, blue: 1.0)
    static let panel = Color(nsColor: .controlBackgroundColor)
}

extension ShapeStyle where Self == Color {
    static var brand: Color { Color.brand }
    static var brand2: Color { Color.brand2 }
    static var ok: Color { Color.ok }
    static var heart: Color { Color.heart }
    static var sky: Color { Color.sky }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.06)))
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 28, weight: .bold, design: .rounded))
            if let s = subtitle { Text(s).font(.callout).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ConnectionPill: View {
    let state: LinkState
    var transfer = false
    @State private var pulse = false
    var color: Color {
        switch state { case .ready: return transfer ? .brand : .ok; case .bluetoothOff, .disconnected: return .red; default: return .orange }
    }
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.8), radius: pulse ? 5 : 1)
                .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: pulse)
            Text(transfer ? "Transferring" : state.label).font(.system(size: 12, weight: .semibold))
        }
        .padding(.horizontal, 11).padding(.vertical, 5)
        .background(color.opacity(0.14), in: Capsule())
        .onAppear { pulse = true }
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var unit: String = ""
    let symbol: String
    let tint: Color
    var body: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
                        .frame(width: 30, height: 30).background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    Spacer()
                }
                Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).kerning(0.6)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value).font(.system(size: 30, weight: .semibold, design: .rounded)).contentTransition(.numericText())
                    Text(unit).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct BatteryRing: View {
    let level: Int?
    var size: CGFloat = 96
    var body: some View {
        let v = Double(level ?? 0) / 100
        let tint: Color = (level ?? 100) < 20 ? .red : ((level ?? 100) < 45 ? .orange : .ok)
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 10)
            Circle().trim(from: 0, to: v).stroke(tint.gradient, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(duration: 0.8), value: v)
            VStack(spacing: 0) {
                Text(level.map { "\($0)" } ?? "–").font(.system(size: size * 0.27, weight: .bold, design: .rounded))
                Text("battery").font(.system(size: size * 0.11, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Rendered OHW-11 hardware with a face image on its screen.
struct WatchMockup: View {
    var face: NSImage?
    var height: CGFloat = 360
    var glow: Color = .brand
    var body: some View {
        let w = height * 0.82
        ZStack {
            // strap
            RoundedRectangle(cornerRadius: w * 0.14).fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.07)],
                                                                          startPoint: .top, endPoint: .bottom))
                .frame(width: w * 0.62, height: height * 1.38)
            // case
            RoundedRectangle(cornerRadius: w * 0.25, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.34), Color(white: 0.10)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: w * 1.08, height: height * 1.07)
                .shadow(color: .black.opacity(0.5), radius: 24, y: 14)
            // crown
            RoundedRectangle(cornerRadius: 4).fill(LinearGradient(colors: [Color(white: 0.45), Color(white: 0.2)], startPoint: .top, endPoint: .bottom))
                .frame(width: w * 0.06, height: height * 0.16).offset(x: w * 0.56, y: -height * 0.17)
            RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.25))
                .frame(width: w * 0.04, height: height * 0.1).offset(x: w * 0.55, y: height * 0.08)
            // glass
            RoundedRectangle(cornerRadius: w * 0.21, style: .continuous).fill(.black)
                .frame(width: w * 1.0, height: height * 0.99)
            Group {
                if let face {
                    Image(nsImage: face).resizable().interpolation(.high).aspectRatio(410.0 / 502.0, contentMode: .fit)
                } else {
                    ZStack {
                        Color.black
                        Image(systemName: "applewatch.watchface").font(.system(size: height * 0.18)).foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(width: w * 0.92, height: height * 0.92 * 1.0)
            .clipShape(RoundedRectangle(cornerRadius: w * 0.18, style: .continuous))
            // reflection
            RoundedRectangle(cornerRadius: w * 0.21, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.10), .clear, .clear], startPoint: .topLeading, endPoint: .center))
                .frame(width: w * 1.0, height: height * 0.99).allowsHitTesting(false)
        }
        .frame(width: w * 1.2, height: height * 1.38)
        .background(RadialGradient(colors: [glow.opacity(0.28), .clear], center: .center, startRadius: 10, endRadius: height * 0.75))
    }
}

struct ToastView: View {
    let toast: Toast
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.symbol).foregroundStyle(toast.isError ? .red : .brand)
            Text(toast.text).font(.system(size: 13, weight: .semibold))
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
        .background(.thickMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = .brand
    func makeBody(configuration: Configuration) -> some View { PrimaryBody(configuration: configuration, tint: tint) }

    struct PrimaryBody: View {
        let configuration: Configuration
        let tint: Color
        @Environment(\.isEnabled) private var enabled
        var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .foregroundStyle(.white)
            .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
        }
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.quaternary.opacity(configuration.isPressed ? 0.9 : 0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
