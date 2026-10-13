import AppKit
import Foundation

enum ConnectionState: Equatable {
    case disconnected
    /// Seen on USB but adb can't talk to it (developer mode off, or adb missing).
    case usbOnly
    /// The headset hasn't accepted this Mac's USB debugging key yet.
    case unauthorized
    case offline
    case connected(wireless: Bool)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

@MainActor
final class DeviceStore: ObservableObject {
    @Published private(set) var usbDevices: [USBQuest] = []
    @Published private(set) var adbDevices: [ADBDevice] = []
    @Published private(set) var status: QuestStatus?
    @Published private(set) var lastError: String?
    @Published private(set) var adb: ADB?

    private let usbMonitor = USBMonitor()
    private var pollTask: Task<Void, Never>?
    private var isRefreshing = false

    /// Product codenames reported by `adb devices -l` for Quest headsets.
    private static let questProducts: Set<String> = ["eureka", "panther", "hollywood", "seacliff", "monterey", "vr_monterey"]

    var primaryADB: ADBDevice? {
        adbDevices.first { $0.state == "device" && !$0.isWireless }
            ?? adbDevices.first { $0.state == "device" }
            ?? adbDevices.first
    }

    var primaryUSB: USBQuest? {
        usbDevices.first { $0.serial != nil && $0.serial == primaryADB?.serial } ?? usbDevices.first
    }

    var connection: ConnectionState {
        if let device = primaryADB {
            switch device.state {
            case "device": return .connected(wireless: device.isWireless)
            case "unauthorized": return .unauthorized
            default: return .offline
            }
        }
        return usbDevices.isEmpty ? .disconnected : .usbOnly
    }

    var deviceName: String {
        status?.model ?? primaryADB?.displayModel ?? primaryUSB?.name ?? "Quest"
    }

    var serial: String? { primaryADB?.serial ?? primaryUSB?.serial }

    func start() {
        guard pollTask == nil else { return }
        if let path = ADB.locate() { adb = ADB(path: path) }

        usbMonitor.onChange = { [weak self] devices in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.usbDevices = devices
                Task { await self.refresh() }
            }
        }
        usbMonitor.start()

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func refresh() async {
        guard let adb, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let usbSerials = Set(usbDevices.compactMap(\.serial))
            adbDevices = try await adb.devices().filter { device in
                usbSerials.contains(device.serial)
                    || (device.model?.contains("Quest") ?? false)
                    || Self.questProducts.contains(device.product ?? "")
            }
            if let device = primaryADB, device.state == "device" {
                status = try await adb.status(serial: device.serial)
            } else {
                status = nil
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Toggles Quest's virtual proximity sensor so the display stays on while the headset is off-face.
    func setKeepAwake(_ enabled: Bool) async {
        guard let adb, let serial = primaryADB?.serial else { return }
        let action = enabled ? "com.oculus.vrpowermanager.prox_close" : "com.oculus.vrpowermanager.automation_disable"
        do {
            _ = try await adb.run(["-s", serial, "shell", "am", "broadcast", "-a", action])
        } catch {
            lastError = error.localizedDescription
        }
        await refresh()
    }

    /// Fills the store with fixed data for design snapshots (`--snapshot`).
    func loadSnapshot(usb: [USBQuest], adb: [ADBDevice], status: QuestStatus?) {
        self.adb = ADB(path: "/usr/bin/true")
        usbDevices = usb
        adbDevices = adb
        self.status = status
    }

    // MARK: - Screenshots

    func saveScreenshot(_ image: CGImage) -> URL? {
        let folder = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tether", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = folder.appendingPathComponent("\(deviceName) \(formatter.string(from: Date())).png")
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return nil }
        do {
            try data.write(to: url)
            return url
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }
}
