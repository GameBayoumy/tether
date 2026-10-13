import Foundation

enum ChargeState {
    case charging, discharging, notCharging, full, unknown

    init(code: Int?) {
        switch code {
        case 2: self = .charging
        case 3: self = .discharging
        case 4: self = .notCharging
        case 5: self = .full
        default: self = .unknown
        }
    }

    var label: String {
        switch self {
        case .charging: return "Charging"
        case .discharging: return "On battery"
        case .notCharging: return "Plugged in, not charging"
        case .full: return "Fully charged"
        case .unknown: return "Unknown"
        }
    }
}

struct ControllerStatus: Identifiable, Hashable {
    var id: String { side }
    let side: String
    let model: String?
    let battery: Int?
    let state: String
    let tracking: String?
    let firmware: String?

    var isConnected: Bool { state.hasPrefix("CONNECTED") }

    var stateLabel: String {
        switch state {
        case "CONNECTED_ACTIVE": return "Active"
        case "CONNECTED_INACTIVE": return "Idle"
        case "SEARCHING": return "Searching"
        case "DISABLED": return "Asleep"
        case "DISCONNECTED": return "Disconnected"
        default: return state.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

struct QuestStatus: Equatable {
    var model = "Quest"
    var horizonOS: String?
    var android: String?
    var build: String?
    var xrspdRunning = false
    var xrspdReady = false
    var linkStreaming = false
    var batteryLevel: Int?
    var charge: ChargeState = .unknown
    var powerSource: String?
    var batteryTempC: Double?
    var controllers: [ControllerStatus] = []
    /// vrpowermanager state, e.g. HEADSET_MOUNTED, HEADSET_UNMOUNTED, STANDBY.
    var powerState: String?

    /// Developer override of the face sensor: CLOSE keeps the display on without anyone wearing it.
    var virtualProximity: String?

    var isWorn: Bool { powerState == "HEADSET_MOUNTED" }
    var isAsleep: Bool { powerState == "STANDBY" }
    var keepAwake: Bool { virtualProximity == "CLOSE" }

    var powerStateLabel: String {
        switch powerState {
        case "HEADSET_MOUNTED": return "On head"
        case "HEADSET_UNMOUNTED": return "Not worn"
        case "STANDBY": return "Asleep"
        case "WAITING_FOR_SLEEP_MSG": return "Going to sleep"
        case nil: return "Unknown"
        case let other?: return other.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
    var storageTotalKB: Int64?
    var storageAvailableKB: Int64?
    var foregroundPackage: String?
    var wifiIP: String?

    var foregroundAppName: String? {
        guard let pkg = foregroundPackage else { return nil }
        switch pkg {
        case "com.oculus.vrshell": return "Home"
        case "com.oculus.xrstreamingclient": return "Quest Link"
        case "com.oculus.systemux": return "System UI"
        case "com.oculus.guardian": return "Boundary"
        default: return pkg
        }
    }
}

/// Collects all status in one `adb shell` round trip, split into `@@section` blocks.
enum StatusParser {
    static let props = [
        "ro.product.model", "ro.vros.build.version", "ro.build.version.release",
        "ro.build.version.incremental", "init.svc.xrspd", "ovr.xrspd.ffs.ready",
        "ovr.xrspd.streaming_active",
    ]

    static let script: String = {
        let propLines = props.map { "echo \"\($0)=$(getprop \($0))\"" }.joined(separator: "; ")
        return [
            "echo @@props", propLines,
            "echo @@battery", "dumpsys battery",
            "echo @@remote", "dumpsys OVRRemoteService | grep 'Paired device'",
            "echo @@power", "dumpsys vrpowermanager | grep -m2 -E '^ *(State|Virtual proximity state):'",
            "echo @@df", "df -k /data | tail -1",
            "echo @@top", "dumpsys activity activities | grep -m1 'ResumedActivity'",
            "echo @@wifi", "ip -f inet addr show wlan0 | grep inet",
        ].joined(separator: "; ")
    }()

    static func sections(_ text: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        var current: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("@@") {
                current = String(line.dropFirst(2))
                result[current!] = []
            } else if let current, !line.isEmpty {
                result[current, default: []].append(line)
            }
        }
        return result
    }

    /// Parses `key: value` (or `key=value`) lines into a dictionary.
    static func keyValues(_ lines: [String], separator: Character) -> [String: String] {
        var dict: [String: String] = [:]
        for line in lines {
            guard let idx = line.firstIndex(of: separator) else { continue }
            let key = line[..<idx].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            dict[key] = value
        }
        return dict
    }

    static func parse(_ text: String) -> QuestStatus {
        let s = sections(text)
        var status = QuestStatus()

        let props = keyValues(s["props"] ?? [], separator: "=").filter { !$0.value.isEmpty }
        status.model = props["ro.product.model"] ?? status.model
        status.horizonOS = props["ro.vros.build.version"]
        status.android = props["ro.build.version.release"]
        status.build = props["ro.build.version.incremental"]
        status.xrspdRunning = props["init.svc.xrspd"] == "running"
        status.xrspdReady = props["ovr.xrspd.ffs.ready"] == "1"
        status.linkStreaming = props["ovr.xrspd.streaming_active"] == "1"

        let battery = keyValues(s["battery"] ?? [], separator: ":")
        status.batteryLevel = battery["level"].flatMap(Int.init)
        status.charge = ChargeState(code: battery["status"].flatMap(Int.init))
        status.batteryTempC = battery["temperature"].flatMap(Double.init).map { $0 / 10 }
        if battery["AC powered"] == "true" {
            status.powerSource = "Charger"
        } else if battery["USB powered"] == "true" {
            status.powerSource = "USB"
        } else if battery["Wireless powered"] == "true" || battery["Dock powered"] == "true" {
            status.powerSource = "Dock"
        }

        status.controllers = (s["remote"] ?? []).compactMap(parseController)
            .sorted { $0.side < $1.side }

        let power = keyValues(s["power"] ?? [], separator: ":")
        status.powerState = power["State"]
        status.virtualProximity = power["Virtual proximity state"]

        if let df = s["df"]?.first {
            let cols = df.split(separator: " ", omittingEmptySubsequences: true)
            if cols.count >= 4 {
                status.storageTotalKB = Int64(cols[1])
                status.storageAvailableKB = Int64(cols[3])
            }
        }

        if let top = s["top"]?.first,
           let component = top.split(separator: " ").first(where: { $0.contains("/") }) {
            status.foregroundPackage = component.split(separator: "/").first.map(String.init)
        }

        if let inet = s["wifi"]?.first {
            let cols = inet.split(separator: " ")
            if cols.count >= 2 { status.wifiIP = cols[1].split(separator: "/").first.map(String.init) }
        }
        return status
    }

    /// `Paired device: a862…, Type:  Right, Model: RUBY, … Battery:  20%, … ExternalStatus: CONNECTED_ACTIVE, …`
    static func parseController(_ line: String) -> ControllerStatus? {
        var fields: [String: String] = [:]
        for part in line.components(separatedBy: ", ") {
            guard let idx = part.firstIndex(of: ":") else { continue }
            fields[part[..<idx].trimmingCharacters(in: .whitespaces)] =
                part[part.index(after: idx)...].trimmingCharacters(in: .whitespaces)
        }
        guard let side = fields["Type"], !side.isEmpty else { return nil }
        let battery = fields["Battery"].flatMap { Int($0.replacingOccurrences(of: "%", with: "")) }
        func nonEmpty(_ key: String) -> String? { fields[key].flatMap { $0.isEmpty ? nil : $0 } }
        return ControllerStatus(
            side: side,
            model: nonEmpty("Model"),
            battery: battery,
            state: nonEmpty("ExternalStatus") ?? nonEmpty("Status") ?? "UNKNOWN",
            tracking: nonEmpty("TrackingStatus"),
            firmware: nonEmpty("Firmware")
        )
    }
}
