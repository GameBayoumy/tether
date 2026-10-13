import AppKit
import SwiftUI

/// Renders the main window in its key states to PNGs for design review: `Tether --snapshot <dir>`.
@MainActor
enum Snapshots {
    /// True while rendering: AppKit-backed controls (switches) don't draw in ImageRenderer.
    static private(set) var isRendering = false

    static func render(to directory: URL) {
        isRendering = true
        defer { isRendering = false }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let usb = USBQuest(registryID: 1, name: "Quest 3", productID: 0x5013, serial: "1WMHH8A0000000",
                           linkSpeedBps: 480_000_000)
        let adb = ADBDevice(serial: "1WMHH8A0000000", state: "device", model: "Quest_3", product: "eureka")
        var status = QuestStatus()
        status.model = "Quest 3"
        status.horizonOS = "207"
        status.android = "14"
        status.build = "52433670048800520"
        status.xrspdRunning = true
        status.xrspdReady = true
        status.batteryLevel = 97
        status.charge = .charging
        status.powerSource = "Charger"
        status.batteryTempC = 36.0
        status.controllers = [
            ControllerStatus(side: "Left", model: "RUBY", battery: 30, state: "SEARCHING", tracking: nil, firmware: nil),
            ControllerStatus(side: "Right", model: "RUBY", battery: 64, state: "CONNECTED_ACTIVE", tracking: "POSITION", firmware: "207.5.0"),
        ]
        status.powerState = "HEADSET_MOUNTED"
        status.storageTotalKB = 470_203_100
        status.storageAvailableKB = 437_480_860
        status.foregroundPackage = "com.oculus.xrstreamingclient"
        status.wifiIP = "192.168.1.42"

        renderIsland(to: directory, usb: usb, adb: adb, status: status)

        let cases: [(String, Bool, LinkState)] = [
            ("streaming", true, .streaming),
            ("ready", true, .ready),
            ("disconnected", false, .waitingForDevice),
        ]
        for (name, connected, linkState) in cases {
            let store = DeviceStore()
            let link = LinkService()
            if connected { store.loadSnapshot(usb: [usb], adb: [adb], status: status) } else { store.loadSnapshot(usb: [], adb: [], status: nil) }
            link.loadSnapshot(state: linkState, fps: 57, mbps: 84, poses: 556)
            let view = ContentView(fixedPointer: .zero)
                .environmentObject(store)
                .environmentObject(link)
                .environmentObject(ScreenStreamer())
                .frame(width: 1200, height: 800)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            renderer.colorMode = .nonLinear
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: directory.appendingPathComponent("\(name).png"))
        }
    }

    private static func renderIsland(to directory: URL, usb: USBQuest, adb: ADBDevice, status: QuestStatus) {
        let store = DeviceStore()
        store.loadSnapshot(usb: [usb], adb: [adb], status: status)
        let modes: [(String, IslandMode, LinkState)] = [
            ("island-compact", .compact, .ready),
            ("island-compact-live", .compact, .streaming),
            ("island-toast", .toast("Link is live", symbol: "dot.radiowaves.left.and.right", tint: .gold), .streaming),
            ("island-expanded", .expanded, .streaming),
        ]
        for (name, mode, linkState) in modes {
            let link = LinkService()
            link.loadSnapshot(state: linkState, fps: 72, mbps: 41, poses: 552)
            let model = IslandModel(geometry: IslandGeometry(notchWidth: 200, topHeight: 32, hasNotch: true))
            model.mode = mode
            let view = ZStack(alignment: .top) {
                Color(white: 0.85)
                IslandView(openMain: {}, openHeadsetView: {})
                    .environmentObject(model).environmentObject(store).environmentObject(link)
            }
            .frame(width: 620, height: 240)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: directory.appendingPathComponent("\(name).png"))
        }
    }
}
