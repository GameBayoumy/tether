import COpenXR
import CXRSP
import Foundation
import simd

// MARK: - Versions, time, logging

func makeVersion(_ major: UInt64, _ minor: UInt64, _ patch: UInt64) -> XrVersion {
    (major << 48) | (minor << 32) | patch
}

let runtimeAPIVersion = makeVersion(1, 1, 63)

/// XrTime is CLOCK_MONOTONIC nanoseconds, the same clock the Tether app stamps its heartbeat with.
func now() -> XrTime { XrTime(clock_gettime_nsec_np(CLOCK_MONOTONIC)) }

func log(_ message: @autoclosure () -> String) {
    if ProcessInfo.processInfo.environment["TETHER_XR_LOG"] != nil {
        FileHandle.standardError.write(("[Tether OpenXR] " + message() + "\n").data(using: .utf8)!)
    }
}

// MARK: - Poses

struct Pose {
    var orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    var position = SIMD3<Float>(0, 0, 0)

    static let identity = Pose()

    init(orientation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), position: SIMD3<Float> = .zero) {
        self.orientation = orientation
        self.position = position
    }

    init(_ p: XrPosef) {
        orientation = simd_normalize(simd_quatf(ix: p.orientation.x, iy: p.orientation.y, iz: p.orientation.z, r: p.orientation.w))
        position = SIMD3(p.position.x, p.position.y, p.position.z)
    }

    init(_ p: qlh_pose) {
        orientation = simd_quatf(ix: p.orientation.0, iy: p.orientation.1, iz: p.orientation.2, r: p.orientation.3)
        position = SIMD3(p.position.0, p.position.1, p.position.2)
    }

    var xr: XrPosef {
        XrPosef(orientation: XrQuaternionf(x: orientation.imag.x, y: orientation.imag.y, z: orientation.imag.z, w: orientation.real),
                position: XrVector3f(x: position.x, y: position.y, z: position.z))
    }

    var inverse: Pose {
        let q = orientation.inverse
        return Pose(orientation: q, position: -q.act(position))
    }

    static func * (a: Pose, b: Pose) -> Pose {
        Pose(orientation: a.orientation * b.orientation, position: a.position + a.orientation.act(b.position))
    }
}

// MARK: - Tracking published by the Tether app

/// Reads the memory-mapped state the Tether app publishes (tether_xr_shared.h).
final class SharedTracking: @unchecked Sendable {
    static let shared = SharedTracking()

    private let lock = NSLock()
    private var mapping: UnsafeMutablePointer<tether_xr_state>?

    static var directory: String {
        NSHomeDirectory() + "/Library/Application Support/Tether"
    }

    private init() {}

    /// Maps the state file once Tether has created it; the editor may have loaded the runtime first.
    private func map() -> UnsafeMutablePointer<tether_xr_state>? {
        let fd = open(Self.directory + "/xr-state", O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let size = MemoryLayout<tether_xr_state>.size
        // Reading past the end of a shorter (just created) file would raise SIGBUS.
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size >= off_t(size) else { return nil }
        guard let raw = mmap(nil, size, PROT_READ, MAP_SHARED, fd, 0), raw != MAP_FAILED else { return nil }
        return raw.bindMemory(to: tether_xr_state.self, capacity: 1)
    }

    /// The latest snapshot, or nil if Tether isn't running (no state file or a stale heartbeat).
    func snapshot() -> tether_xr_state? {
        let mapping = lock.withLock { () -> UnsafeMutablePointer<tether_xr_state>? in
            if mapping == nil { mapping = map() }
            return mapping
        }
        guard let mapping else { return nil }
        var state = tether_xr_state()
        guard tether_xr_read_state(mapping, &state) else { return nil }
        // A heartbeat from before a reboot can be ahead of the current monotonic clock.
        let age = Int64(now()) - Int64(state.heartbeat_ns)
        return age >= 0 && age < 3_000_000_000 ? state : nil
    }
}

// MARK: - Two-call idiom and strings

func writeString(_ string: String, capacity: UInt32, count: UnsafeMutablePointer<UInt32>?, buffer: UnsafeMutablePointer<CChar>?) -> XrResult {
    let bytes = Array(string.utf8CString)
    count?.pointee = UInt32(bytes.count)
    if capacity == 0 { return XR_SUCCESS }
    guard capacity >= UInt32(bytes.count), let buffer else { return XR_ERROR_SIZE_INSUFFICIENT }
    for (index, byte) in bytes.enumerated() { buffer[index] = byte }
    return XR_SUCCESS
}

func copyFixedString<T>(_ string: String, into tuple: inout T) {
    withUnsafeMutableBytes(of: &tuple) { raw in
        raw.initializeMemory(as: UInt8.self, repeating: 0)
        let bytes = Array(string.utf8.prefix(raw.count - 1))
        raw.copyBytes(from: bytes)
    }
}

func readFixedString<T>(_ tuple: T) -> String {
    withUnsafeBytes(of: tuple) { raw in
        let bytes = raw.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Finds a struct of `type` in an input `next` chain.
func findInChain(_ next: UnsafeRawPointer?, type: XrStructureType) -> UnsafeRawPointer? {
    var current = next
    while let pointer = current {
        let base = pointer.assumingMemoryBound(to: XrBaseInStructure.self)
        if base.pointee.type == type { return pointer }
        current = UnsafeRawPointer(base.pointee.next)
    }
    return nil
}

// MARK: - Handles

/// Maps opaque XR handles to runtime objects. Handles are small integers, never pointers.
final class HandleTable: @unchecked Sendable {
    static let shared = HandleTable()
    private let lock = NSLock()
    private var nextID: UInt64 = 1
    private var objects: [UInt64: AnyObject] = [:]

    func register(_ object: AnyObject) -> OpaquePointer {
        lock.withLock {
            let id = nextID
            nextID += 1
            objects[id] = object
            return OpaquePointer(bitPattern: UInt(id))!
        }
    }

    func lookup<T: AnyObject>(_ handle: OpaquePointer?, as type: T.Type) -> T? {
        guard let handle else { return nil }
        let id = UInt64(UInt(bitPattern: handle))
        return lock.withLock { objects[id] as? T }
    }

    func remove(_ handle: OpaquePointer?) {
        guard let handle else { return }
        let id = UInt64(UInt(bitPattern: handle))
        _ = lock.withLock { objects.removeValue(forKey: id) }
    }

    /// Removes every object matching `predicate`: the children of a parent handle being destroyed.
    func removeAll(where predicate: (AnyObject) -> Bool) {
        lock.withLock { objects = objects.filter { !predicate($0.value) } }
    }
}
