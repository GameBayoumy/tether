import Foundation
import os

private let log = Logger(subsystem: "io.dashxr.Tether", category: "openxr")

/// Makes Tether the OpenXR runtime, automatically:
/// - The system default, `/usr/local/share/openxr/1/active_runtime.json`. The OpenXR loader that Unity
///   ships for macOS falls back to it when Play mode clears XR_RUNTIME_JSON ("System Default"). It is a
///   link to a manifest Tether keeps current in Application Support, so admin rights are needed once.
/// - XR_RUNTIME_JSON via `launchctl setenv`, for apps started later in this login session.
enum RuntimeRegistration {
    static var manifestPath: String? {
        Bundle.main.resourceURL?.appendingPathComponent("openxr/tether_openxr.json").path
    }

    private static let systemManifest = "/usr/local/share/openxr/1/active_runtime.json"
    private static let declinedKey = "declinedSystemOpenXRRegistration"

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

        registerAsSystemDefault()
    }

    /// Keeps the user manifest pointing at this copy of the runtime, and links the system default to it.
    private static func registerAsSystemDefault() {
        guard let library = Bundle.main.resourceURL?.appendingPathComponent("openxr/libTetherOpenXR.dylib").path else { return }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tether")
        let userManifest = directory.appendingPathComponent("openxr_runtime.json")
        // The library path is absolute: the loader resolves relative paths against the manifest's location.
        let manifest: [String: Any] = [
            "file_format_version": "1.0.0",
            "runtime": ["name": "Tether", "library_path": library],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return }
        if (try? Data(contentsOf: userManifest)) != data {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: userManifest, options: .atomic)
        }

        // Already linked and readable: nothing to do. Another runtime's manifest is left alone.
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: systemManifest),
           target == userManifest.path, FileManager.default.isReadableFile(atPath: systemManifest) {
            return
        }
        if FileManager.default.isReadableFile(atPath: systemManifest) {
            log.notice("Another OpenXR runtime is the system default; leaving \(systemManifest, privacy: .public)")
            return
        }
        guard !UserDefaults.standard.bool(forKey: declinedKey) else { return }

        // One admin prompt. /usr/local/share can be root-only, which hides the manifest from editors.
        let script = """
            mkdir -p /usr/local/share/openxr/1 && \
            chmod a+rx /usr/local/share /usr/local/share/openxr /usr/local/share/openxr/1 && \
            ln -sfn '\(userManifest.path)' '\(systemManifest)'
            """
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = [
                "-e", "do shell script \"\(script.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges "
                    + "with prompt \"Tether wants to register its OpenXR runtime, so Unity can render to your headset.\"",
            ]
            guard (try? process.run()) != nil else { return }
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                // Cancelled: don't ask on every launch.
                UserDefaults.standard.set(true, forKey: declinedKey)
                log.notice("System OpenXR registration declined")
            }
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
