import CXRSP
import Foundation
import TetherCore

/// The app side of the OpenXR runtime contract (see tether_xr_shared.h): publishes tracking into a
/// memory-mapped file and accepts encoded frames from the runtime over a Unix-domain socket.
final class XRBridge: @unchecked Sendable {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Tether", isDirectory: true)
    static let statePath = directory.appendingPathComponent("xr-state").path
    static let socketPath = directory.appendingPathComponent("xr.sock").path

    /// Called on the socket thread for every frame the runtime sends.
    var onFrame: ((EncodedFrame) -> Void)? {
        get { lock.withLock { frameHandler } }
        set { lock.withLock { frameHandler = newValue } }
    }

    private var frameHandler: ((EncodedFrame) -> Void)?
    private var mapping: UnsafeMutablePointer<tether_xr_state>?
    private var listenSocket: Int32 = -1
    private let lock = NSLock()
    private var lastFrame = Date.distantPast
    private var lastState = tether_xr_state()

    init() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        mapState()
        startListening()
    }

    deinit {
        if listenSocket >= 0 { close(listenSocket) }
        unlink(Self.socketPath)
        if let mapping { munmap(mapping, MemoryLayout<tether_xr_state>.size) }
    }

    /// True while an editor is actively rendering through the runtime.
    var runtimeIsDriving: Bool {
        lock.withLock { Date().timeIntervalSince(lastFrame) < 0.5 }
    }

    func publish(head: qlh_pose, controllers: [qlh_controller], ipd: Float,
                 fovTangents: ((Float, Float, Float, Float), (Float, Float, Float, Float)),
                 eyeWidth: UInt32, eyeHeight: UInt32, refreshHz: Float, recenterCount: UInt32) {
        var state = tether_xr_state()
        state.magic = TETHER_XR_STATE_MAGIC
        state.version = TETHER_XR_VERSION
        state.streaming = 1
        state.heartbeat_ns = UInt64(clock_gettime_nsec_np(CLOCK_MONOTONIC))
        state.head = head
        if controllers.count == 2 { state.controllers = (controllers[0], controllers[1]) }
        state.ipd = ipd > 0 ? ipd : 0.063
        state.fov_tangents = fovTangents
        state.eye_width = eyeWidth
        state.eye_height = eyeHeight
        state.refresh_hz = refreshHz
        state.floor_height = 1.6
        state.recenter_count = recenterCount
        write(state)
    }

    /// Marks the headset as not streaming, keeping the last description for the runtime.
    func publishIdle() {
        var state = lock.withLock { lastState }
        state.magic = TETHER_XR_STATE_MAGIC
        state.version = TETHER_XR_VERSION
        state.streaming = 0
        state.heartbeat_ns = UInt64(clock_gettime_nsec_np(CLOCK_MONOTONIC))
        write(state)
    }

    private func write(_ state: tether_xr_state) {
        guard let mapping else { return }
        var value = state
        // The seqlock allows one writer at a time; publish and publishIdle run on different threads.
        lock.withLock {
            lastState = state
            tether_xr_write_state(mapping, &value)
        }
    }

    // MARK: Shared memory

    private func mapState() {
        let fd = open(Self.statePath, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let size = MemoryLayout<tether_xr_state>.size
        guard ftruncate(fd, off_t(size)) == 0,
              let raw = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), raw != MAP_FAILED else { return }
        mapping = raw.bindMemory(to: tether_xr_state.self, capacity: 1)
    }

    // MARK: Socket

    private func startListening() {
        unlink(Self.socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(Self.socketPath.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.withUnsafeBytes { buffer.copyMemory(from: $0) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 1) == 0 else { close(fd); return }
        listenSocket = fd
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "tether.xr.bridge"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            receiveFrames(client)
            close(client)
            lock.withLock { lastFrame = .distantPast }
        }
    }

    private func receiveFrames(_ client: Int32) {
        let headerSize = MemoryLayout<tether_xr_frame_header>.size
        var header = tether_xr_frame_header()
        while true {
            let ok = withUnsafeMutableBytes(of: &header) { readExactly(client, $0.baseAddress!, headerSize) }
            guard ok, header.magic == TETHER_XR_FRAME_MAGIC else { return }
            let csd = withUnsafeBytes(of: header.codec_config_bytes) { Array($0.bindMemory(to: UInt32.self)) }
            let video = withUnsafeBytes(of: header.video_bytes) { Array($0.bindMemory(to: UInt32.self)) }
            let total = (csd + video).reduce(0) { $0 + Int($1) }
            guard total < 64 << 20 else { return }
            var payload = Data(count: total)
            let gotPayload = payload.withUnsafeMutableBytes { total == 0 || readExactly(client, $0.baseAddress!, total) }
            guard gotPayload else { return }

            var offset = 0
            var codecConfig: [Data] = []
            var slices: [Data] = []
            for index in 0..<csd.count {
                codecConfig.append(payload.subdata(in: offset..<(offset + Int(csd[index]))))
                offset += Int(csd[index])
                slices.append(payload.subdata(in: offset..<(offset + Int(video[index]))))
                offset += Int(video[index])
            }
            lock.withLock { lastFrame = Date() }
            onFrame?(EncodedFrame(frameID: header.frame_id, pose: header.pose, codecConfig: codecConfig, video: slices))
        }
    }

    private func readExactly(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Bool {
        var done = 0
        while done < count {
            let n = read(fd, buffer + done, count - done)
            if n > 0 {
                done += n
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }
}
