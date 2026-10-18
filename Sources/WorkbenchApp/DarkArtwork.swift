import AppKit
import SwiftUI

/// Drawn stand-ins for the dark-mode artwork, in the style of the dark reference: a glowing object on a lit
/// glass podium against deep navy. They are replaced automatically when the "…Dark" image assets are added
/// (see docs/design/dark-theme/README.md).
struct HeroDarkArt: View {
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let sphere = min(size.height * 0.78, size.width * 0.24)
            let center = CGPoint(x: size.width * 0.70, y: size.height * 0.50)
            ZStack {
                LinearGradient(colors: [Color(hex: "0A1220"), Color(hex: "0F1F36"), Color(hex: "0B1826")], startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [Color(hex: "2F7BFF").opacity(0.42), Color(hex: "1B4DA8").opacity(0.18), .clear], center: UnitPoint(x: 0.70, y: 0.5), startRadius: 0, endRadius: size.width * 0.38)
                ForEach(0..<14, id: \.self) { index in
                    // Faint vertical light streaks, like a distant night city behind glass.
                    let x = size.width * (0.42 + Double(index) * 0.042)
                    Rectangle().fill(LinearGradient(colors: [Color(hex: "3A6EB8").opacity(0.0), Color(hex: "3A6EB8").opacity(0.16), .clear], startPoint: .bottom, endPoint: .top))
                        .frame(width: 2 + CGFloat(index % 3), height: size.height * (0.35 + 0.05 * Double(index % 5))).position(x: x, y: size.height * 0.62)
                }
                glassPanel(width: sphere * 0.62, height: sphere * 0.42, bars: true).modifier(Skew(amount: -0.12)).position(x: center.x - sphere * 1.12, y: center.y - sphere * 0.18)
                glassPanel(width: sphere * 0.48, height: sphere * 0.62, bars: false).modifier(Skew(amount: 0.12)).position(x: center.x + sphere * 1.10, y: center.y + sphere * 0.05)
                Ellipse().stroke(LinearGradient(colors: [Color(hex: "9FD6FF").opacity(0.9), Color(hex: "3C8BFF").opacity(0.35), Color(hex: "9FD6FF").opacity(0.8)], startPoint: .leading, endPoint: .trailing), lineWidth: 2)
                    .frame(width: sphere * 2.2, height: sphere * 0.52).rotationEffect(.degrees(-11)).position(center)
                    .shadow(color: Color(hex: "4FA8FF"), radius: 6)
                Circle().fill(RadialGradient(colors: [Color(hex: "CFEAFF"), Color(hex: "4E97FF"), Color(hex: "143C8C"), Color(hex: "0A1A3C")], center: UnitPoint(x: 0.38, y: 0.32), startRadius: 2, endRadius: sphere * 0.62))
                    .overlay(Circle().stroke(Color(hex: "8CCBFF").opacity(0.75), lineWidth: 1.5))
                    .overlay(GridSphere().stroke(Color(hex: "A8DBFF").opacity(0.16), lineWidth: 0.8))
                    .frame(width: sphere, height: sphere).position(center)
                    .shadow(color: Color(hex: "3D8BFF").opacity(0.9), radius: sphere * 0.22)
                Text("AI").font(.system(size: sphere * 0.36, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                    .shadow(color: Color(hex: "7CC4FF"), radius: 10).position(center)
                Circle().fill(Color(hex: "D7F0FF")).frame(width: 7, height: 7).shadow(color: Color(hex: "7CC4FF"), radius: 6)
                    .position(x: center.x - sphere * 0.98, y: center.y + sphere * 0.16)
            }
        }.accessibilityHidden(true)
    }

    private func glassPanel(width: CGFloat, height: CGFloat, bars: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8).fill(Color(hex: "6FAEFF").opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: "7FBFFF").opacity(0.38), lineWidth: 1))
            .overlay(alignment: .bottomLeading) {
                if bars {
                    HStack(alignment: .bottom, spacing: width * 0.06) {
                        ForEach([0.35, 0.6, 0.45, 0.8, 0.55], id: \.self) { value in
                            RoundedRectangle(cornerRadius: 1).fill(Color(hex: "7FBFFF").opacity(0.45)).frame(width: width * 0.08, height: height * 0.55 * value)
                        }
                    }.padding(width * 0.12)
                } else {
                    VStack(alignment: .leading, spacing: height * 0.08) {
                        ForEach([0.7, 0.5, 0.85, 0.4], id: \.self) { value in Capsule().fill(Color(hex: "7FBFFF").opacity(0.35)).frame(width: width * 0.7 * value, height: 2) }
                    }.padding(width * 0.14)
                }
            }
            .frame(width: width, height: height).shadow(color: Color(hex: "3D8BFF").opacity(0.35), radius: 10)
    }
}

/// Tilts a flat panel as if it were turned toward the center. A 2D shear stands in for `rotation3DEffect`,
/// which layer snapshots (the offscreen render checks) cannot draw in place.
private struct Skew: GeometryEffect {
    var amount: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        let shear = CGAffineTransform(a: 0.92, b: amount, c: 0, d: 1, tx: 0, ty: 0)
        return ProjectionTransform(CGAffineTransform(translationX: -size.width / 2, y: -size.height / 2)
            .concatenating(shear).concatenating(CGAffineTransform(translationX: size.width / 2, y: size.height / 2)))
    }
}

/// Latitude and longitude lines that make the hero sphere read as a globe.
private struct GridSphere: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = rect.width / 2
        for latitude in [-0.45, 0.0, 0.45] {
            let width = 2 * radius * sqrt(1 - latitude * latitude)
            path.addEllipse(in: CGRect(x: rect.midX - width / 2, y: rect.midY + radius * latitude - width * 0.08, width: width, height: width * 0.16))
        }
        for inset in [0.25, 0.42] { path.addEllipse(in: rect.insetBy(dx: rect.width * inset, dy: 0)) }
        return path
    }
}

/// One module's stand-in artwork: its object glowing in the module color on a glass podium.
struct ModuleDarkArt: View {
    enum Kind { case video, audio, code, design, custom(String) }
    var kind: Kind
    var tint: Color

    private var symbol: String {
        switch kind {
        case .video: return "video.fill"
        case .audio: return "mic.fill"
        case .code: return "laptopcomputer"
        case .design: return "paintpalette.fill"
        case .custom(let icon): return icon
        }
    }
    private var panelSymbols: [String] {
        switch kind {
        case .video: return ["play.fill", "film"]
        case .audio: return ["waveform", "music.note"]
        case .code: return ["chevron.left.forwardslash.chevron.right", "curlybraces"]
        case .design: return ["photo", "paintbrush.pointed.fill"]
        case .custom: return ["sparkles", "square.stack.3d.up"]
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let unit = min(size.width, size.height * 1.15)
            // Narrow cards are taller than wide; lift the podium so it clears the caption and the open button.
            let base = CGPoint(x: size.width * 0.52, y: size.height * (size.height > size.width ? 0.68 : 0.80))
            ZStack {
                LinearGradient(colors: [Color(hex: "0C1522"), Color(hex: "111D2C"), Color(hex: "0E1724")], startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [tint.opacity(0.42), tint.opacity(0.12), .clear], center: UnitPoint(x: 0.52, y: 0.66), startRadius: 0, endRadius: unit * 0.62)
                ForEach(0..<9, id: \.self) { index in
                    Circle().fill(tint.opacity(0.85)).frame(width: index % 3 == 0 ? 3 : 2).shadow(color: tint, radius: 4)
                        .position(x: size.width * (0.14 + 0.09 * Double(index)), y: size.height * (0.30 + 0.06 * Double((index * 5) % 7)))
                        .opacity(0.65)
                }
                panel(panelSymbols[0], width: unit * 0.30, height: unit * 0.23).modifier(Skew(amount: -0.16)).position(x: size.width * 0.20, y: size.height * 0.60)
                panel(panelSymbols[1], width: unit * 0.26, height: unit * 0.30).modifier(Skew(amount: 0.16)).position(x: size.width * 0.84, y: size.height * 0.56)
                // Glass podium: two stacked rings with a lit rim.
                Ellipse().fill(LinearGradient(colors: [Color(hex: "1B2738"), Color(hex: "0C131D")], startPoint: .top, endPoint: .bottom))
                    .overlay(Ellipse().stroke(tint.opacity(0.85), lineWidth: 1.6)).frame(width: unit * 0.78, height: unit * 0.17)
                    .shadow(color: tint.opacity(0.7), radius: 14).position(x: base.x, y: base.y + unit * 0.05)
                Ellipse().fill(LinearGradient(colors: [Color(hex: "243246"), Color(hex: "121B28")], startPoint: .top, endPoint: .bottom))
                    .overlay(Ellipse().stroke(tint.opacity(0.65), lineWidth: 1.2)).frame(width: unit * 0.56, height: unit * 0.12)
                    .position(base)
                Ellipse().fill(tint.opacity(0.35)).frame(width: unit * 0.44, height: unit * 0.06).blur(radius: 10).position(x: base.x, y: base.y - unit * 0.01)
                Image(systemName: symbol).resizable().scaledToFit()
                    .foregroundStyle(LinearGradient(colors: [.white.opacity(0.96), tint.opacity(0.95), tint.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: unit * 0.40, height: unit * 0.33)
                    .shadow(color: tint.opacity(0.95), radius: 16).shadow(color: .black.opacity(0.5), radius: 6, y: 6)
                    .position(x: base.x, y: base.y - unit * 0.21)
            }
        }.accessibilityHidden(true)
    }

    private func panel(_ symbol: String, width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 7).fill(tint.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(tint.opacity(0.55), lineWidth: 1))
            .overlay(Image(systemName: symbol).font(.system(size: min(width, height) * 0.36, weight: .semibold)).foregroundStyle(tint.opacity(0.95)).shadow(color: tint, radius: 6))
            .frame(width: width, height: height).shadow(color: tint.opacity(0.4), radius: 10)
    }
}

extension ModuleDarkArt.Kind {
    static func of(_ area: WorkArea) -> ModuleDarkArt.Kind {
        switch StudioArtwork.index(for: area) {
        case 0: return .video
        case 1: return .audio
        case 2: return .code
        case 3: return .design
        default: return .custom(area.icon)
        }
    }
}
