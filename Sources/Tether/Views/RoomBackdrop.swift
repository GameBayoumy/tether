import SwiftUI

/// The room: ink walls fading to a horizon light, and the same perspective floor the headset scene uses.
struct RoomBackdrop: View {
    var live: Bool
    /// Pointer position, -1...1 on each axis, for parallax.
    var pointer: CGPoint
    /// Horizon height as a fraction of the window.
    var horizon: CGFloat = 0.78

    var body: some View {
        Canvas { context, size in
            let horizonY = size.height * horizon - pointer.y * 6
            let vanishing = CGPoint(x: size.width / 2 - pointer.x * 18, y: horizonY)

            // Walls and floor.
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .linearGradient(Gradient(stops: [
                             .init(color: Theme.roomTop, location: 0),
                             .init(color: Theme.roomHorizon, location: horizon),
                             .init(color: Theme.floor, location: 1),
                         ]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

            // Horizon light: cool when idle, warm gold when the link is live.
            let glow = live ? Theme.gold : Color(hex: 0x5B7BB8)
            let glowRect = CGRect(x: vanishing.x - size.width * 0.55, y: horizonY - 90, width: size.width * 1.1, height: 180)
            context.fill(Path(ellipseIn: glowRect),
                         with: .radialGradient(Gradient(colors: [glow.opacity(live ? 0.30 : 0.16), glow.opacity(0)]),
                                               center: vanishing, startRadius: 0, endRadius: size.width * 0.55))

            // Floor grid in perspective, fading into the horizon.
            let floorDepth = size.height - horizonY
            guard floorDepth > 20 else { return }
            let lineColor = live ? Theme.gold : Color.white
            for i in -14...14 {
                let bottomX = vanishing.x + CGFloat(i) * size.width * 0.09
                var line = Path()
                line.move(to: vanishing)
                line.addLine(to: CGPoint(x: bottomX, y: size.height))
                context.stroke(line, with: .linearGradient(Gradient(colors: [lineColor.opacity(0), lineColor.opacity(live ? 0.13 : 0.08)]),
                                                           startPoint: vanishing, endPoint: CGPoint(x: bottomX, y: size.height)),
                               lineWidth: 1)
            }
            for k in 1...14 {
                let z = CGFloat(k) * 0.55
                let y = horizonY + floorDepth / z
                guard y < size.height else { continue }
                let fade = min(1, (y - horizonY) / floorDepth * 1.6)
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(lineColor.opacity((live ? 0.12 : 0.07) * fade)), lineWidth: 1)
            }
        }
        .ignoresSafeArea()
        .animation(.easeOut(duration: 1.2), value: live)
    }
}
