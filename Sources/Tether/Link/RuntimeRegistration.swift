import Foundation

/// Makes Tether the OpenXR runtime for everything launched in this login session, automatically.
/// The macOS OpenXR loader honours XR_RUNTIME_JSON; `launchctl setenv` hands it to apps started
/// from the Dock, Finder, Unity Hub or the Epic launcher, with no admin rights needed. Tether opens
/// at login, so it's in place before any editor starts.
enum RuntimeRegistration {
    static var manifestPath: String? {
        Bundle.main.resourceURL?.appendingPathComponent("openxr/tether_openxr.json").path
    }

    static func registerForSession() {
        guard let manifestPath, FileManager.default.fileExists(atPath: manifestPath) else { return }
        launchctl(["setenv", "XR_RUNTIME_JSON", manifestPath])

        // The Khronos loader scans $XDG_DATA_DIRS (default /usr/local/share:/usr/share) for API layers
        // and fails every app with "Unknown failure" if one of them exists but can't be read, as when
        // /usr/local/share is root-only. Leave unreadable directories out of the search path.
        let defaults = ["/usr/local/share", "/usr/share"]
        let dirs = ProcessInfo.processInfo.environment["XDG_DATA_DIRS"].map { $0.split(separator: ":").map(String.init) } ?? defaults
        let readable = dirs.filter { (try? FileManager.default.contentsOfDirectory(atPath: $0)) != nil || !FileManager.default.fileExists(atPath: $0) }
        if readable.count != dirs.count {
            launchctl(["setenv", "XDG_DATA_DIRS", (readable.isEmpty ? ["/usr/share"] : readable).joined(separator: ":")])
        }
    }

    private static func launchctl(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
    }
}
