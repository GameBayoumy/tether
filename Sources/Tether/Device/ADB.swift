import Foundation

enum ADBError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}

struct ADBDevice: Identifiable, Hashable {
    var id: String { serial }
    let serial: String
    /// `device`, `unauthorized`, `offline`, ...
    let state: String
    let model: String?
    let product: String?

    var isWireless: Bool { serial.contains(":") || serial.hasPrefix("adb-") }
    var displayModel: String? { model?.replacingOccurrences(of: "_", with: " ") }
}

/// Thin async wrapper around the platform-tools `adb` binary.
final class ADB: @unchecked Sendable {
    let path: String

    init(path: String) {
        self.path = path
    }

    /// Apps launched from Finder get a minimal PATH, so look in the usual install locations.
    static func locate() -> String? {
        var candidates = ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
        let env = ProcessInfo.processInfo.environment
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let root = env[key] { candidates.append(root + "/platform-tools/adb") }
        }
        candidates.append(NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb")
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func runData(_ args: [String], timeout: TimeInterval = 10) async throws -> Data {
        let path = self.path
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = args
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

                // Drain stderr concurrently so a chatty command can't deadlock on a full pipe.
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    errData = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                killer.cancel()

                if process.terminationStatus != 0 && data.isEmpty {
                    let message = String(decoding: errData, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: ADBError.failed(message.isEmpty ? "adb exited with \(process.terminationStatus)" : message))
                } else {
                    continuation.resume(returning: data)
                }
            }
        }
    }

    func run(_ args: [String], timeout: TimeInterval = 10) async throws -> String {
        String(decoding: try await runData(args, timeout: timeout), as: UTF8.self)
    }

    func devices() async throws -> [ADBDevice] {
        let output = try await run(["devices", "-l"])
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 2, !line.hasPrefix("List of devices"), !line.hasPrefix("*") else { return nil }
            var info: [String: String] = [:]
            for field in fields.dropFirst(2) {
                let parts = field.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2 { info[parts[0]] = parts[1] }
            }
            return ADBDevice(serial: fields[0], state: fields[1], model: info["model"], product: info["product"])
        }
    }

    func status(serial: String) async throws -> QuestStatus {
        let output = try await run(["-s", serial, "shell", StatusParser.script], timeout: 15)
        return StatusParser.parse(output)
    }
}
