import SwiftUI

/// A status pane standing on the arc. Elevation comes from its fill against the room; no borders.
struct Slab<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            content
        }
        .padding(16)
        .frame(width: 252, height: 218, alignment: .topLeading)
        .background(Theme.paneFar, in: RoundedRectangle(cornerRadius: Theme.paneRadius, style: .continuous))
    }
}

/// Stands a side pane on the arc, angled toward the viewer; hovering swings it round to face you.
struct ArcPlacement: ViewModifier {
    enum Side { case left, right }
    let side: Side
    let pointer: CGPoint
    @State private var hovering = false

    func body(content: Content) -> some View {
        let sign: Double = side == .left ? 1 : -1
        let resting = sign * 17 + Double(pointer.x) * 4
        content
            .scaleEffect(hovering ? 1.0 : 0.92)
            .brightness(hovering ? 0.02 : -0.03)
            .rotation3DEffect(.degrees(hovering ? 0 : resting), axis: (x: 0, y: 1, z: 0),
                              anchor: side == .left ? .trailing : .leading, perspective: 0.55)
            .offset(x: CGFloat(-pointer.x) * 10, y: CGFloat(-pointer.y) * 5)
            .shadow(color: .black.opacity(0.45), radius: 22, x: 0, y: 16)
            .onHover { hovering = $0 }
            .animation(.spring(response: 0.45, dampingFraction: 0.82), value: hovering)
    }
}

extension View {
    func standOnArc(_ side: ArcPlacement.Side, pointer: CGPoint) -> some View {
        modifier(ArcPlacement(side: side, pointer: pointer))
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var tint: Color? = nil
    var help: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 6)
            Text(value)
                .fontWeight(.medium)
                .foregroundStyle(tint ?? Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .font(.system(size: 12))
        .help(help ?? value)
    }
}

/// A figure that rolls its digits when the value changes.
struct Figure: View {
    let value: String
    var unit: String? = nil
    var size: CGFloat = 40
    var tint: Color = Theme.text

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value)
                .font(Theme.figure(size))
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            if let unit {
                Text(unit).font(.system(size: size * 0.32, weight: .medium)).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

struct LevelBar: View {
    let level: Int?
    var dimmed = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(color).frame(width: geo.size.width * CGFloat(level ?? 0) / 100)
            }
        }
        .frame(height: 4)
        .opacity(dimmed ? 0.5 : 1)
        .accessibilityLabel(level.map { "\($0) percent" } ?? "Unknown")
    }

    private var color: Color {
        guard let level else { return Theme.textTertiary }
        return level <= 15 ? Theme.fault : (level <= 30 ? Theme.attention : Theme.healthy)
    }
}

struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isEnabled ? Theme.goldInk : Theme.textTertiary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(isEnabled ? Theme.gold : Theme.paneRaised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .contentShape(Rectangle())
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(isEnabled ? Theme.text : Theme.textTertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Theme.paneRaised.opacity(hovering && isEnabled ? 1 : 0.75),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .onHover { hovering = $0 }
            .contentShape(Rectangle())
    }
}

/// Keeps the headset display on while it isn't worn (Quest's developer "virtual proximity").
struct KeepAwakeToggle: View {
    @EnvironmentObject private var store: DeviceStore
    let status: QuestStatus

    var body: some View {
        if Snapshots.isRendering {
            HStack(spacing: 8) {
                Text("Keep awake")
                Capsule().fill(status.keepAwake ? Theme.gold : Color.white.opacity(0.18))
                    .frame(width: 26, height: 15)
                    .overlay(alignment: status.keepAwake ? .trailing : .leading) {
                        Circle().fill(.white).padding(1.5)
                    }
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.textSecondary)
        } else {
            toggle
        }
    }

    private var toggle: some View {
        Toggle("Keep awake", isOn: Binding(
            get: { status.keepAwake },
            set: { enabled in Task { await store.setKeepAwake(enabled) } }
        ))
        .toggleStyle(.switch)
        .tint(Theme.gold)
        .controlSize(.mini)
        .font(.system(size: 12))
        .foregroundStyle(Theme.textSecondary)
        .help("Keeps the headset display on while it isn't worn. Turn off to let it sleep normally.")
    }
}

extension ConnectionState {
    var pillText: String {
        switch self {
        case .disconnected: return "Not connected"
        case .usbOnly: return "USB · debugging off"
        case .unauthorized: return "Waiting for approval"
        case .offline: return "Offline"
        case .connected(let wireless): return wireless ? "Connected over Wi‑Fi" : "Connected over USB"
        }
    }

    var color: Color {
        switch self {
        case .disconnected: return Theme.textTertiary
        case .usbOnly, .unauthorized: return Theme.attention
        case .offline: return Theme.fault
        case .connected: return Theme.healthy
        }
    }
}

extension LinkState {
    var tint: Color {
        switch self {
        case .off, .waitingForDevice: return Theme.textTertiary
        case .connecting: return Theme.attention
        case .ready: return Theme.text
        case .streaming: return Theme.gold
        }
    }
}
