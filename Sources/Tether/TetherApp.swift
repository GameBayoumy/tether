import SwiftUI

@main
struct TetherApp: App {
    @StateObject private var store = DeviceStore()
    @StateObject private var screen = ScreenStreamer()
    @StateObject private var link = LinkService()

    init() {
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
            Snapshots.render(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            exit(0)
        }
        RuntimeRegistration.registerForSession()
    }

    var body: some Scene {
        WindowGroup("Tether", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(screen)
                .environmentObject(link)
                .frame(minWidth: 1180, minHeight: 760)
                .background(IslandBootstrap(store: store, link: link))
                .task {
                    store.start()
                    link.start()
                    LoginItem.enableOnFirstLaunch()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1200, height: 800)

        Window("Device Screen", id: "screen") {
            ScreenWindow()
                .environmentObject(store)
                .environmentObject(screen)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1100, height: 640)

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(store)
                .environmentObject(link)
                .task { store.start() }
        } label: {
            Image(nsImage: MenuBarIcon.image)
        }
    }
}
