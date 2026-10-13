import SwiftUI

/// The main window: a small room with the viewport facing you and status panes on an arc.
struct ContentView: View {
    @EnvironmentObject private var store: DeviceStore
    @EnvironmentObject private var link: LinkService
    /// Snapshots pass a fixed pointer; the live window follows the mouse.
    var fixedPointer: CGPoint? = nil
    @State private var pointer: CGPoint = .zero

    var body: some View {
        GeometryReader { geo in
            let p = fixedPointer ?? pointer
            ZStack {
                RoomBackdrop(live: link.state == .streaming, pointer: p)
                VStack(spacing: 0) {
                    TopBar()
                    Spacer(minLength: 18).frame(maxHeight: 40)
                    HStack(alignment: .center, spacing: 26) {
                        VStack(spacing: 26) {
                            HeadsetSlab().standOnArc(.left, pointer: p)
                            ControllersSlab().standOnArc(.left, pointer: p)
                        }
                        Viewport()
                            .frame(width: 560, height: 470)
                            .offset(x: p.x * -4, y: p.y * -3)
                        VStack(spacing: 26) {
                            CableSlab().standOnArc(.right, pointer: p)
                            SystemSlab().standOnArc(.right, pointer: p)
                        }
                    }
                    Spacer(minLength: 16)
                    FloorMarking()
                        .offset(x: p.x * -12)
                        .padding(.bottom, 26)
                }
                .padding(.horizontal, 24)
            }
            .onContinuousHover { phase in
                guard fixedPointer == nil else { return }
                switch phase {
                case .active(let location):
                    let target = CGPoint(x: location.x / max(geo.size.width, 1) * 2 - 1,
                                         y: location.y / max(geo.size.height, 1) * 2 - 1)
                    withAnimation(.easeOut(duration: 0.35)) { pointer = target }
                case .ended:
                    withAnimation(.easeOut(duration: 0.6)) { pointer = .zero }
                }
            }
        }
        .foregroundStyle(Theme.text)
        .preferredColorScheme(.dark)
    }
}

private struct TopBar: View {
    @EnvironmentObject private var store: DeviceStore
    @EnvironmentObject private var link: LinkService

    var body: some View {
        HStack(spacing: 10) {
            TetherMark(size: 22, live: link.state == .streaming)
            Text("Tether").font(Theme.wordmark(15)).tracking(0.4)
            Spacer()
            HStack(spacing: 8) {
                StatusDot(color: store.connection.color)
                Text(store.connection == .disconnected ? "No headset" : store.deviceName)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(store.connection.pillText)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise").frame(width: 14, height: 14)
            }
            .buttonStyle(SecondaryButtonStyle())
            .help("Refresh headset status")
        }
        .padding(.leading, 72) // the window's traffic lights sit here
        .padding(.top, 12)
        .frame(height: 44)
    }
}

/// Serial and cable written on the floor in front of the viewport, like a stage marking.
private struct FloorMarking: View {
    @EnvironmentObject private var store: DeviceStore

    var body: some View {
        Text(text)
            .font(.system(size: 15, weight: .medium).width(.expanded))
            .tracking(1.0)
            .foregroundStyle(Theme.text.opacity(0.5))
            .rotation3DEffect(.degrees(48), axis: (x: 1, y: 0, z: 0), anchor: .center, perspective: 0.45)
            .accessibilityLabel(text)
    }

    private var text: String {
        guard store.connection != .disconnected else { return "Waiting for a headset on USB‑C" }
        var parts = [store.deviceName]
        if let serial = store.serial { parts.append(serial) }
        if let usb = store.primaryUSB { parts.append(usb.speedLabel) }
        return parts.joined(separator: "   ·   ")
    }
}

// MARK: - Side panes

private struct HeadsetSlab: View {
    @EnvironmentObject private var store: DeviceStore

    var body: some View {
        Slab(title: "Headset") {
            if let status = store.status {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Figure(value: status.batteryLevel.map(String.init) ?? "—", unit: "%", size: 40)
                    if status.charge == .charging {
                        Image(systemName: "bolt.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.healthy)
                    }
                }
                LevelBar(level: status.batteryLevel)
                VStack(spacing: 6) {
                    InfoRow(label: "Power", value: status.charge.label)
                    InfoRow(label: "State", value: status.keepAwake ? "Kept awake" : status.powerStateLabel,
                            tint: status.isWorn || status.keepAwake ? Theme.healthy : nil)
                }
                .padding(.top, 2)
                Spacer(minLength: 0)
                KeepAwakeToggle(status: status)
            } else {
                Placeholder(text: store.connection == .disconnected ? "Connect a headset" : "Battery needs USB debugging")
            }
        }
    }
}

private struct ControllersSlab: View {
    @EnvironmentObject private var store: DeviceStore

    var body: some View {
        Slab(title: "Controllers") {
            if let status = store.status, !status.controllers.isEmpty {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(["Left", "Right"], id: \.self) { side in
                        let controller = status.controllers.first { $0.side == side }
                        VStack(alignment: .leading, spacing: 7) {
                            Text(side).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.textTertiary)
                            Figure(value: controller?.battery.map(String.init) ?? "—", unit: "%", size: 28,
                                   tint: controller?.isConnected == true ? Theme.text : Theme.textSecondary)
                            LevelBar(level: controller?.battery, dimmed: controller?.isConnected != true)
                            Text(controller.map(\.stateLabel) ?? "Not paired")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(controller?.isConnected == true ? Theme.healthy : Theme.textTertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Spacer(minLength: 0)
                Text("Sleeping controllers show their last reported charge.")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Placeholder(text: store.connection == .disconnected ? "Connect a headset" : "No controller data")
            }
        }
    }
}

private struct CableSlab: View {
    @EnvironmentObject private var store: DeviceStore
    @EnvironmentObject private var link: LinkService

    var body: some View {
        Slab(title: "Cable") {
            if let usb = store.primaryUSB {
                Figure(value: usb.isUSB3 ? (usb.linkSpeedBps ?? 0 >= 10_000_000_000 ? "10" : "5") : "480",
                       unit: usb.isUSB3 ? "Gb/s" : "Mb/s", size: 34,
                       tint: usb.isUSB3 ? Theme.text : Theme.attention)
                Text(usb.isUSB3 ? "USB 3 · full Link quality" : "USB 2 · use a USB 3 cable for full Link quality")
                    .font(.system(size: 11.5)).foregroundStyle(usb.isUSB3 ? Theme.textSecondary : Theme.attention)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 6) {
                    InfoRow(label: "Link", value: link.state.title, tint: link.state == .streaming ? Theme.gold : nil)
                    InfoRow(label: "Link service", value: linkService, tint: store.status?.xrspdReady == true ? Theme.healthy : nil)
                    InfoRow(label: "Product ID", value: String(format: "0x%04X", usb.productID))
                }
                .padding(.top, 4)
            } else {
                Placeholder(text: store.primaryADB?.isWireless == true ? "Connected over Wi‑Fi; Link needs USB" : "No USB connection")
            }
        }
    }

    private var linkService: String {
        guard let status = store.status else { return "—" }
        return status.xrspdRunning ? (status.xrspdReady ? "Ready" : "Starting") : "Stopped"
    }
}

private struct SystemSlab: View {
    @EnvironmentObject private var store: DeviceStore

    var body: some View {
        Slab(title: "System") {
            if let status = store.status {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Horizon OS").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    Figure(value: status.horizonOS.map { "v\($0)" } ?? "—", size: 26)
                }
                VStack(spacing: 6) {
                    InfoRow(label: "Active app", value: status.foregroundAppName ?? "—", help: status.foregroundPackage)
                    InfoRow(label: "Wi‑Fi", value: status.wifiIP ?? "Off")
                    InfoRow(label: "Temperature", value: status.batteryTempC.map { String(format: "%.0f °C", $0) } ?? "—",
                            tint: (status.batteryTempC ?? 0) >= 42 ? Theme.attention : nil)
                }
                Spacer(minLength: 0)
                if let total = status.storageTotalKB, let free = status.storageAvailableKB, total > 0 {
                    let used = Double(total - free) / Double(total)
                    LevelBar(level: Int(used * 100))
                    Text("\(Self.bytes(free)) free of \(Self.bytes(total))")
                        .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
            } else {
                Placeholder(text: store.connection == .disconnected ? "Connect a headset" : "Needs USB debugging")
            }
        }
    }

    static func bytes(_ kb: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: kb * 1024, countStyle: .file)
    }
}

private struct Placeholder: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Figure(value: "—", size: 36, tint: Theme.textTertiary)
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
