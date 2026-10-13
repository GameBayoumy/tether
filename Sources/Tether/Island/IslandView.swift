import SwiftUI

/// The island itself: black so it merges with the notch, flush with the top edge, rounded below.
struct IslandView: View {
    @EnvironmentObject private var model: IslandModel
    @EnvironmentObject private var store: DeviceStore
    @EnvironmentObject private var link: LinkService
    let openMain: () -> Void
    let openHeadsetView: () -> Void

    private var geometry: IslandGeometry { model.geometry }

    var body: some View {
        let size = model.size(for: model.mode)
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                IslandShape(radius: model.mode == .compact ? 12 : 22)
                    .fill(Color.black)
                VStack(spacing: 0) {
                    compactRow
                    switch model.mode {
                    case .compact:
                        EmptyView()
                    case .toast(let text, let symbol, let tint):
                        ToastRow(text: text, symbol: symbol, tint: tint)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                    case .expanded:
                        ExpandedPanel(openMain: openMain, openHeadsetView: openHeadsetView)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(IslandShape(radius: 22))
            .onHover { model.hovering = $0 }
            .onTapGesture { if model.mode != .expanded { model.hovering = true } }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(Theme.text)
        .preferredColorScheme(.dark)
    }

    /// The strip level with the menu bar: the mark on the left wing, one live reading on the right.
    private var compactRow: some View {
        HStack(spacing: 0) {
            TetherMark(size: 15, live: link.state == .streaming)
                .padding(.leading, 14)
            Spacer(minLength: geometry.hasNotch ? geometry.notchWidth : 12)
            rightWing.padding(.trailing, 14)
        }
        .frame(height: geometry.topHeight)
    }

    @ViewBuilder
    private var rightWing: some View {
        if link.state == .streaming {
            HStack(spacing: 5) {
                Circle().fill(Theme.gold).frame(width: 6, height: 6)
                Text("\(link.framesPerSecond)")
                    .font(Theme.figure(12, weight: .medium))
                    .contentTransition(.numericText())
                    .foregroundStyle(Theme.gold)
            }
        } else if let level = store.status?.batteryLevel {
            HStack(spacing: 4) {
                if store.status?.charge == .charging {
                    Image(systemName: "bolt.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.healthy)
                }
                Text("\(level)%").font(Theme.figure(11.5, weight: .medium)).contentTransition(.numericText())
                    .foregroundStyle(level <= 15 ? Theme.attention : Theme.text)
            }
        } else {
            Circle().fill(store.connection.color).frame(width: 6, height: 6)
        }
    }
}

/// Square top corners flush with the screen edge, generous round bottom corners.
struct IslandShape: Shape {
    var radius: CGFloat

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous).path(in: rect)
    }
}

private struct ToastRow: View {
    let text: String
    let symbol: String
    let tint: IslandTint

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
            Text(text).font(.system(size: 13, weight: .medium)).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 40)
    }

    private var color: Color {
        switch tint {
        case .neutral: return Theme.text
        case .gold: return Theme.gold
        case .healthy: return Theme.healthy
        case .attention: return Theme.attention
        }
    }
}

private struct ExpandedPanel: View {
    @EnvironmentObject private var store: DeviceStore
    @EnvironmentObject private var link: LinkService
    let openMain: () -> Void
    let openHeadsetView: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(store.connection == .disconnected ? "No headset" : store.deviceName)
                    .font(Theme.title(16))
                Text(store.connection.pillText).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                Spacer()
                Toggle("Link", isOn: Binding(get: { link.isEnabled }, set: { link.isEnabled = $0 }))
                    .toggleStyle(.switch).tint(Theme.gold).controlSize(.mini).labelsHidden()
                    .help("Use this Mac as the headset's Link PC")
            }

            HStack(alignment: .bottom, spacing: 26) {
                reading("Headset", store.status?.batteryLevel, charging: store.status?.charge == .charging)
                reading("Left", controller("Left"))
                reading("Right", controller("Right"))
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(link.state == .streaming ? "\(link.framesPerSecond)" : "—")
                        .font(Theme.figure(24)).contentTransition(.numericText())
                        .foregroundStyle(link.state == .streaming ? Theme.gold : Theme.textTertiary)
                    Text(link.state == .streaming ? "fps · \(String(format: "%.0f", link.megabitsPerSecond)) Mb/s" : link.state.title)
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
            }

            HStack(spacing: 8) {
                Text(hint).font(.system(size: 11.5)).foregroundStyle(link.state == .streaming ? Theme.gold : Theme.textSecondary)
                    .lineLimit(1)
                Spacer()
                Button("Headset view", action: openHeadsetView)
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!store.connection.isConnected)
                Button("Open Tether", action: openMain)
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 16)
    }

    private var hint: String {
        switch link.state {
        case .streaming: return "Live in your headset"
        case .ready: return "Choose Launch in your headset"
        case .connecting: return "Pairing…"
        case .waitingForDevice: return "Connect a Quest with USB‑C"
        case .off: return "Link is off"
        }
    }

    private func controller(_ side: String) -> Int? {
        store.status?.controllers.first { $0.side == side }?.battery
    }

    private func reading(_ label: String, _ level: Int?, charging: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(level.map(String.init) ?? "—").font(Theme.figure(24)).contentTransition(.numericText())
                Text("%").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.textSecondary)
                if charging {
                    Image(systemName: "bolt.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.healthy)
                }
            }
            LevelBar(level: level).frame(width: 54)
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
        }
    }
}
