import AppKit
import SwiftUI

/// The studio's look, saved under `Theme.preferenceKey`. Ink (default) and pixel are both dark and share the dark
/// system appearance; pixel adds its own palette, stepped corners, hard shadows and pixel artwork.
enum StudioStyle: String, CaseIterable, Identifiable {
    case ink, pixel, paper
    var id: Self { self }
    static func from(_ raw: String) -> StudioStyle { StudioStyle(rawValue: raw) ?? .ink }
    var isDark: Bool { self != .paper }
    var isPixel: Bool { self == .pixel }
    var title: String {
        switch self {
        case .ink: "夜幕 · 深色（默认）"
        case .pixel: "像素 · 深色"
        case .paper: "云蓝 · 浅色"
        }
    }
    var subtitle: String {
        switch self {
        case .ink: "深海军蓝底色、明亮的四色工作区与发光插画"
        case .pixel: "靛蓝夜色、街机配色、像素插画与阶梯圆角"
        case .paper: "通透浅蓝与四色工作区"
        }
    }
    /// Suffix of this style's artwork assets ("StudioVideoPixel" …); nil for the light artwork.
    var artworkSuffix: String? {
        switch self {
        case .ink: "Dark"
        case .pixel: "Pixel"
        case .paper: nil
        }
    }
}

private struct StudioStyleKey: EnvironmentKey { static let defaultValue = StudioStyle.ink }
extension EnvironmentValues {
    var studioStyle: StudioStyle {
        get { self[StudioStyleKey.self] }
        set { self[StudioStyleKey.self] = newValue }
    }
}

/// A rounded rectangle, or in the pixel style a rectangle with stepped corners like an 8-bit window frame.
/// The step grows with the radius (2–4 pt, two steps per corner), so callers keep passing their usual radius.
struct StudioShape: InsettableShape {
    var radius: CGFloat
    var pixel: Bool
    private var inset: CGFloat = 0

    init(_ radius: CGFloat, pixel: Bool) {
        self.radius = radius
        self.pixel = pixel
    }

    func path(in rect: CGRect) -> Path {
        let frame = rect.insetBy(dx: inset, dy: inset)
        guard pixel else { return RoundedRectangle(cornerRadius: max(0, radius - inset)).path(in: frame) }
        let step = min(max(2, (radius / 4).rounded(.down)), 4, frame.width / 4, frame.height / 4)
        let (minX, minY, maxX, maxY) = (frame.minX, frame.minY, frame.maxX, frame.maxY)
        var path = Path()
        path.move(to: CGPoint(x: minX + 2 * step, y: minY))
        path.addLines([
            CGPoint(x: maxX - 2 * step, y: minY), CGPoint(x: maxX - 2 * step, y: minY + step), CGPoint(x: maxX - step, y: minY + step),
            CGPoint(x: maxX - step, y: minY + 2 * step), CGPoint(x: maxX, y: minY + 2 * step),
            CGPoint(x: maxX, y: maxY - 2 * step), CGPoint(x: maxX - step, y: maxY - 2 * step), CGPoint(x: maxX - step, y: maxY - step),
            CGPoint(x: maxX - 2 * step, y: maxY - step), CGPoint(x: maxX - 2 * step, y: maxY),
            CGPoint(x: minX + 2 * step, y: maxY), CGPoint(x: minX + 2 * step, y: maxY - step), CGPoint(x: minX + step, y: maxY - step),
            CGPoint(x: minX + step, y: maxY - 2 * step), CGPoint(x: minX, y: maxY - 2 * step),
            CGPoint(x: minX, y: minY + 2 * step), CGPoint(x: minX + step, y: minY + 2 * step), CGPoint(x: minX + step, y: minY + step),
            CGPoint(x: minX + 2 * step, y: minY + step),
        ])
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> StudioShape {
        var shape = self
        shape.inset += amount
        return shape
    }
}

extension View {
    /// Pixel style: a hard, unblurred drop shadow cast by the element's outline only (text inside casts none).
    /// Other styles keep the soft shadow they pass in.
    @ViewBuilder func studioShadow(pixel: Bool, color: Color, radius: CGFloat, y: CGFloat) -> some View {
        if pixel { compositingGroup().shadow(color: .black.opacity(0.55), radius: 0, x: 4, y: 4) } else { shadow(color: color, radius: radius, y: y) }
    }

    /// Pixel style: sets a caption on a small dialog-box plate so it stays readable over busy pixel art.
    @ViewBuilder func pixelPlate(_ pixel: Bool, border: Color) -> some View {
        if pixel {
            padding(.horizontal, 9).padding(.vertical, 6)
                .background(Color(hex: "080B1E").opacity(0.82), in: StudioShape(8, pixel: true))
                .overlay(StudioShape(8, pixel: true).stroke(border, lineWidth: 2))
        } else { self }
    }
}

/// A faint square grid behind the pixel style's pages, echoing the floor grid in its artwork.
struct PixelGrid: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 24
            var lines = Path()
            for x in stride(from: 0, through: size.width, by: cell) { lines.addRect(CGRect(x: x, y: 0, width: 1, height: size.height)) }
            for y in stride(from: 0, through: size.height, by: cell) { lines.addRect(CGRect(x: 0, y: y, width: size.width, height: 1)) }
            context.fill(lines, with: .color(Color(hex: "29ADFF").opacity(0.045)))
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// The pixel style's create button: a solid workspace-color block with dark text, a lit top edge and a shaded bottom edge.
struct PixelBlockBackground: View {
    var fill: Color
    var radius: CGFloat = 12
    var body: some View {
        StudioShape(radius, pixel: true).fill(fill)
            .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.35)).frame(height: 2).padding(.horizontal, 8).padding(.top, 2) }
            .overlay(alignment: .bottom) { Rectangle().fill(.black.opacity(0.28)).frame(height: 3).padding(.horizontal, 4).padding(.bottom, 0) }
            .clipShape(StudioShape(radius, pixel: true))
    }
}
