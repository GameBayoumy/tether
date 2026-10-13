import AppKit
import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject private var store: DeviceStore
    @EnvironmentObject private var link: LinkService
    @Environment(\.openWindow) private var openWindow
    @AppStorage("islandEnabled") private var islandEnabled = true
    @State private var openAtLogin = LoginItem.isEnabled

    var body: some View {
        Text(store.connection == .disconnected ? "No headset connected" : "\(store.deviceName) · \(store.connection.pillText)")
        Text("Link: \(link.state.title)")
        if let status = store.status {
            if let level = status.batteryLevel {
                Text("Headset \(level)%\(status.charge == .charging ? ", charging" : "")")
            }
            ForEach(status.controllers) { controller in
                Text("\(controller.side) controller \(controller.battery.map { "\($0)%" } ?? "—") · \(controller.stateLabel)")
            }
        }
        Divider()
        Button("Open Tether") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Button("Headset View") {
            openWindow(id: "screen")
            NSApp.activate()
        }
        .disabled(!store.connection.isConnected)
        if link.state == .streaming {
            Button("End Link") { link.endLink() }
        }
        Toggle("Open at Login", isOn: $openAtLogin)
            .onChange(of: openAtLogin) { LoginItem.set(openAtLogin) }
        Toggle("Show Island", isOn: $islandEnabled)
            .onChange(of: islandEnabled) { IslandController.shared.isEnabled = islandEnabled }
        Divider()
        Button("Quit Tether") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// The Tether mark as a template image for the menu bar.
@MainActor
enum MenuBarIcon {
    static let image: NSImage = {
        let renderer = ImageRenderer(content: TetherMark(size: 16).environment(\.colorScheme, .light))
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage(systemSymbolName: "link", accessibilityDescription: "Tether")!
        image.isTemplate = true
        image.accessibilityDescription = "Tether"
        return image
    }()
}
