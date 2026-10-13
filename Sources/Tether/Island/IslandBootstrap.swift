import SwiftUI

/// Starts the island from inside a scene, where `openWindow` is available.
struct IslandBootstrap: View {
    let store: DeviceStore
    let link: LinkService
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task {
                let open = openWindow
                IslandController.shared.start(
                    store: store, link: link,
                    openMain: { open(id: "main"); NSApp.activate() },
                    openHeadsetView: { open(id: "screen"); NSApp.activate() })
            }
    }
}
