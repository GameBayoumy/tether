import SwiftUI

/// Tether's room: ink walls, slate panes, a perspective floor, and one warm light for a live link.
enum Theme {
    static let roomTop = Color(hex: 0x04060B)
    static let roomHorizon = Color(hex: 0x0C1322)
    static let floor = Color(hex: 0x05070D)

    static let pane = Color(hex: 0x141A26)
    static let paneFar = Color(hex: 0x0F141E)
    static let paneRaised = Color(hex: 0x1C2433)

    static let text = Color(hex: 0xEEF1F6)
    static let textSecondary = Color(hex: 0xA3ACBE)
    static let textTertiary = Color(hex: 0x7F899E)

    /// The only accent: the link is live.
    static let gold = Color(hex: 0xE9C27A)
    static let goldInk = Color(hex: 0x1C1608)
    static let healthy = Color(hex: 0x5BE3A9)
    static let attention = Color(hex: 0xFFB45E)
    static let fault = Color(hex: 0xFF6B6B)

    static let paneRadius: CGFloat = 14
    static let viewportRadius: CGFloat = 18

    static func figure(_ size: CGFloat, weight: Font.Weight = .light) -> Font {
        .system(size: size, weight: weight).width(.expanded).monospacedDigit()
    }

    static func wordmark(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold).width(.expanded)
    }

    static func title(_ size: CGFloat) -> Font {
        .system(size: size, weight: .medium).width(.expanded)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// The Tether mark: two nodes, headset and Mac, joined by a slack cable hanging between them.
struct TetherMark: View {
    var size: CGFloat = 24
    var live = false

    var body: some View {
        Canvas { context, canvas in
            let w = canvas.width
            let color: GraphicsContext.Shading = .color(live ? Theme.gold : Theme.text)
            let left = CGPoint(x: w * 0.2, y: w * 0.34)
            let right = CGPoint(x: w * 0.82, y: w * 0.34)
            var cable = Path()
            cable.move(to: left)
            cable.addCurve(to: right, control1: CGPoint(x: w * 0.3, y: w * 0.98), control2: CGPoint(x: w * 0.72, y: w * 0.98))
            context.stroke(cable, with: color, style: StrokeStyle(lineWidth: w * 0.08, lineCap: .round))
            // Headset node: a ring. Mac node: a solid dot.
            let ringRadius = w * 0.15
            context.fill(Path(ellipseIn: CGRect(x: left.x - ringRadius, y: left.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2)),
                         with: .color(Theme.roomTop))
            context.stroke(Path(ellipseIn: CGRect(x: left.x - ringRadius, y: left.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2)),
                           with: color, lineWidth: w * 0.08)
            let dot = w * 0.11
            context.fill(Path(ellipseIn: CGRect(x: right.x - dot, y: right.y - dot, width: dot * 2, height: dot * 2)), with: color)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
