import Foundation
import os

private let log = Logger(subsystem: "io.dashxr.Tether", category: "unreal")

/// Installs the TetherXR plugin into every Unreal Engine on this Mac, so VR Preview renders into the headset
/// with no project setup. Tether bundles one build per engine version in Resources/unreal/<major.minor>/TetherXR;
/// it goes to <engine>/Engine/Plugins/Marketplace/TetherXR and is enabled by default. Reinstalled when the
/// bundled build changes or the launcher's "Verify" removed it.
enum UnrealPlugin {
    private static let stampName = ".tether-build"

    static func installInBackground() {
        DispatchQueue.global(qos: .utility).async { installAll() }
    }

    private static func installAll() {
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("unreal") else { return }
        for engine in engineRoots() {
            guard let version = engineVersion(engine) else { continue }
            let source = bundled.appendingPathComponent(version).appendingPathComponent("TetherXR")
            guard FileManager.default.fileExists(atPath: source.path) else {
                log.notice("No TetherXR build for Unreal \(version, privacy: .public) at \(engine.path, privacy: .public)")
                continue
            }
            install(source, into: engine.appendingPathComponent("Engine/Plugins/Marketplace/TetherXR"), version: version)
        }
    }

    private static func install(_ source: URL, into target: URL, version: String) {
        let files = FileManager.default
        let stamp = (try? String(contentsOf: source.appendingPathComponent(stampName), encoding: .utf8)) ?? ""
        let installed = (try? String(contentsOf: target.appendingPathComponent(stampName), encoding: .utf8)) ?? ""
        if !stamp.isEmpty && stamp == installed { return }
        // Copy next to the target, then swap, so an editor starting meanwhile never sees half a plugin.
        let staging = target.deletingLastPathComponent().appendingPathComponent(".TetherXR-\(UUID().uuidString)")
        do {
            try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.copyItem(at: source, to: staging)
            if files.fileExists(atPath: target.path) {
                _ = try files.replaceItemAt(target, withItemAt: staging)
            } else {
                try files.moveItem(at: staging, to: target)
            }
            log.notice("Installed TetherXR for Unreal \(version, privacy: .public) in \(target.path, privacy: .public)")
        } catch {
            try? files.removeItem(at: staging)
            log.error("Couldn't install TetherXR in \(target.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Engines the Epic Games Launcher installed, plus any in its default folder.
    private static func engineRoots() -> [URL] {
        var roots: [URL] = []
        let launcher = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Epic/UnrealEngineLauncher/LauncherInstalled.dat")
        if let data = try? Data(contentsOf: launcher),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = json["InstallationList"] as? [[String: Any]] {
            for entry in list {
                guard let name = entry["AppName"] as? String, name.hasPrefix("UE_"),
                      let location = entry["InstallLocation"] as? String else { continue }
                roots.append(URL(fileURLWithPath: location))
            }
        }
        let shared = URL(fileURLWithPath: "/Users/Shared/Epic Games")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: shared.path)) ?? [] where name.hasPrefix("UE_") {
            roots.append(shared.appendingPathComponent(name))
        }
        var seen = Set<String>()
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// "5.8" from Engine/Build/Build.version.
    private static func engineVersion(_ engine: URL) -> String? {
        let file = engine.appendingPathComponent("Engine/Build/Build.version")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let major = json["MajorVersion"] as? Int, let minor = json["MinorVersion"] as? Int else { return nil }
        return "\(major).\(minor)"
    }
}
