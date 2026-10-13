import Foundation
import IOKit
import IOKit.usb

/// A Meta headset as seen on the USB bus, independent of adb.
struct USBQuest: Identifiable, Hashable {
    var id: UInt64 { registryID }
    let registryID: UInt64
    let name: String
    let productID: Int
    let serial: String?
    let linkSpeedBps: Int?

    var isUSB3: Bool { (linkSpeedBps ?? 0) >= 5_000_000_000 }

    var speedLabel: String {
        guard let bps = linkSpeedBps else { return "Unknown" }
        switch bps {
        case 10_000_000_000...: return "10 Gb/s · USB 3.2"
        case 5_000_000_000...: return "5 Gb/s · USB 3.0"
        case 480_000_000...: return "480 Mb/s · USB 2.0"
        default: return "\(bps / 1_000_000) Mb/s · USB 1.1"
        }
    }
}

/// Watches IOKit for Meta (VID 0x2833) devices being attached or removed.
final class USBMonitor {
    static let metaVendorID = 0x2833

    var onChange: (([USBQuest]) -> Void)?

    private var port: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0

    deinit {
        if addedIterator != 0 { IOObjectRelease(addedIterator) }
        if removedIterator != 0 { IOObjectRelease(removedIterator) }
        if let port { IONotificationPortDestroy(port) }
    }

    func start() {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            USBMonitor.drain(iterator)
            guard let refcon else { return }
            Unmanaged<USBMonitor>.fromOpaque(refcon).takeUnretainedValue().rescan()
        }
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, Self.matching(), callback, refcon, &addedIterator)
        Self.drain(addedIterator)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, Self.matching(), callback, refcon, &removedIterator)
        Self.drain(removedIterator)
        rescan()
    }

    func rescan() {
        onChange?(Self.scan())
    }

    private static func matching() -> CFDictionary {
        let dict = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
        // A bare idVendor key doesn't match IOUSBHostDevice; it has to go through IOPropertyMatch.
        dict[kIOPropertyMatchKey] = ["idVendor": metaVendorID]
        return dict
    }

    /// Notifications are only re-armed once their iterator has been fully consumed.
    private static func drain(_ iterator: io_iterator_t) {
        while case let object = IOIteratorNext(iterator), object != 0 {
            IOObjectRelease(object)
        }
    }

    static func scan() -> [USBQuest] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching(), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var devices: [USBQuest] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &entryID)
            devices.append(USBQuest(
                registryID: entryID,
                name: property(service, "USB Product Name") as? String ?? "Quest headset",
                productID: (property(service, "idProduct") as? NSNumber)?.intValue ?? 0,
                serial: property(service, "USB Serial Number") as? String,
                linkSpeedBps: (property(service, "UsbLinkSpeed") as? NSNumber)?.intValue
            ))
        }
        return devices
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
