import Foundation
import ServiceManagement

/// Keeps Tether in the menu bar from login, so plugging in a headset pairs Link right away.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Tether: couldn't update login item: \(error.localizedDescription)")
        }
    }

    /// Turns it on the first time Tether runs; after that the user's menu choice wins.
    static func enableOnFirstLaunch() {
        let key = "loginItemConfigured"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        set(true)
    }
}
