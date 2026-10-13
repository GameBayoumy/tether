import TetherCore
import CoreVideo
import CXRSP
import Foundation
import Metal

/// Drives a streaming session: pose → render → per-slice H.264 → `qlh_send_frame`, paced to the headset refresh rate.
final class StreamPipeline: @unchecked Sendable {
    private let host: OpaquePointer
    private let renderer: VRRenderer
    private let encoder: SliceEncoder
    private let capture = DesktopCapture()
    let pointer = DesktopPointer()
    private let renderQueue = DispatchQueue(label: "tether.link.render", qos: .userInteractive)
    private let sendQueue = DispatchQueue(label: "tether.link.send", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private let refreshHz: Double
    /// Frames on the GPU whose completion will still hand slices to the encoder.
    private let renders = DispatchGroup()

    private let lock = NSLock()
    private var inFlight = 0
    private var framesSent = 0
    private var needsKeyframe = true
    private var lastKeyframe = Date.distantPast
    private var frameID: UInt32 = 0
    /// Set by `stop()`; after that nothing more reaches the host, which may be destroyed.
    private var stopped = false

    private var permissionCard: MTLTexture?
    private var waitingCard: MTLTexture?

    /// Keyframes refresh all five slices together; also sent after any dropped slice.
    private static let keyframeInterval: TimeInterval = 2
    /// Every frame an IDR (set via TETHER_INTRA_ONLY=1). P-frames keep static content sharp at the same bitrate.
    private static let intraOnly = ProcessInfo.processInfo.environment["TETHER_INTRA_ONLY"] != nil

    var screenCapturePermissionDenied: Bool { capture.permissionDenied }

    private let bridge: XRBridge?
    private let declaredTangents: ((Float, Float, Float, Float), (Float, Float, Float, Float))

    init(host: OpaquePointer, info: qlh_headset_info, bridge: XRBridge? = nil) throws {
        self.bridge = bridge
        guard let device = MTLCreateSystemDefaultDevice() else { throw RendererError("This Mac has no Metal GPU") }
        self.host = host
        refreshHz = info.refresh_hz > 0 ? Double(info.refresh_hz) : 72
        // The headset unprojects each eye with the FOV tangents declared in every slice, so the renderer must
        // use exactly those. Default: the real asymmetric lens FOV, declared in XrsFovPort order
        // (left, right, up, down; confirmed in the headset). TETHER_FOV=symmetric falls back to one
        // symmetric frustum covering the whole lens, which is valid whatever the field order.
        let eyes = [info.eye_fov.0, info.eye_fov.1]
        let renderFOV: [qlh_fov]
        var tangents: ((Float, Float, Float, Float), (Float, Float, Float, Float))
        func tanDeg(_ degrees: Float) -> Float { tan(degrees * .pi / 180) }
        if ProcessInfo.processInfo.environment["TETHER_FOV"] != "symmetric" {
            renderFOV = eyes
            tangents = ((tanDeg(eyes[0].left), tanDeg(eyes[0].right), tanDeg(eyes[0].up), tanDeg(eyes[0].down)),
                        (tanDeg(eyes[1].left), tanDeg(eyes[1].right), tanDeg(eyes[1].up), tanDeg(eyes[1].down)))
        } else {
            let halfAngle = min(max(eyes.flatMap { [$0.up, $0.down, $0.left, $0.right] }.max() ?? 55, 40), 70)
            let t = tanDeg(halfAngle)
            renderFOV = Array(repeating: qlh_fov(up: halfAngle, down: halfAngle, left: halfAngle, right: halfAngle), count: 2)
            tangents = ((t, t, t, t), (t, t, t, t))
        }
        declaredTangents = tangents
        withUnsafePointer(to: &tangents) {
            $0.withMemoryRebound(to: (Float, Float, Float, Float).self, capacity: 2) { qlh_set_frame_fov(host, $0) }
        }
        renderer = try VRRenderer(device: device, eyeFOV: renderFOV)
        // ~100 Mb/s total keeps well inside USB 2 bulk throughput; USB 3 has far more headroom.
        encoder = try SliceEncoder(width: VRRenderer.frameWidth, height: VRRenderer.sliceHeight,
                                   count: VRRenderer.sliceCount, fps: Int(refreshHz.rounded()), bitRatePerSlice: 32_000_000)

        permissionCard = renderer.makeCard(
            title: "Screen Recording needed",
            subtitle: "On your Mac, allow Tether in System Settings › Privacy & Security › Screen & System Audio Recording, then reopen Tether.")
        waitingCard = renderer.makeCard(title: "Tether", subtitle: "Starting desktop capture…")

        encoder.onFrame = { [weak self] frame in self?.send(frame) }
        // Frames an editor renders through the OpenXR runtime replace Tether's own scene.
        bridge?.onFrame = { [weak self] frame in self?.forwardRuntimeFrame(frame) }
        encoder.onFailure = { [weak self] _ in
            guard let self else { return }
            self.lock.withLock {
                self.inFlight -= 1
                self.needsKeyframe = true
            }
        }
    }

    func start() {
        capture.start()
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: renderQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / refreshHz, leeway: .microseconds(500))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        capture.stop()
        renderQueue.sync {}
        // Frames still on the GPU hand their slices to the encoder when they complete.
        renders.wait()
        encoder.invalidate()
        pointer.releaseButtons()
        lock.withLock { stopped = true }
        sendQueue.sync {}
    }

    func recenter() {
        renderer.requestRecenter()
        lock.withLock { recenterCount &+= 1 }
    }

    func latestPreview() -> CVPixelBuffer? {
        renderer.latestPreview()
    }

    private var lastInput: ([qlh_controller], [SIMD2<Float>?]) = ([], [])

    /// One-line controller summary for diagnostics.
    func inputSummary() -> String {
        let (controllers, hits) = lock.withLock { lastInput }
        return controllers.enumerated().map { index, c in
            let hit = index < hits.count ? hits[index].map { String(format: "%.2f,%.2f", $0.x, $0.y) } ?? "off" : "off"
            return "\(index == 0 ? "L" : "R")[\(c.valid ? "in" : "--")\(c.pose_valid ? "+pose" : "") trig \(String(format: "%.2f", c.trigger)) grip \(String(format: "%.2f", c.grip)) btn \(String(c.buttons, radix: 16)) stick \(String(format: "%.1f,%.1f", c.stick_x, c.stick_y)) bat \(c.battery) hit \(hit)]"
        }.joined(separator: " ")
    }

    /// Frames handed to the headset since the previous call.
    func takeFrameCount() -> Int {
        lock.withLock {
            defer { framesSent = 0 }
            return framesSent
        }
    }

    private func tick() {
        var pose = qlh_pose()
        if !qlh_get_pose(host, &pose, nil) {
            pose.orientation = (0, 0, 0, 1)
        }
        var controllers = [qlh_controller](repeating: qlh_controller(), count: 2)
        _ = controllers.withUnsafeMutableBufferPointer { qlh_get_controllers(host, $0.baseAddress) }
        let ipd = qlh_get_ipd(host)
        if ipd > 0 { renderer.ipd = ipd }
        handleSystemButton(controllers)

        // Tracking for an editor using the Tether OpenXR runtime; while it is sending frames, it owns the display.
        if let bridge {
            bridge.publish(head: pose, controllers: controllers, ipd: ipd, fovTangents: declaredTangents,
                           eyeWidth: UInt32(VRRenderer.frameWidth / 2), eyeHeight: UInt32(VRRenderer.frameHeight),
                           refreshHz: Float(refreshHz), recenterCount: lock.withLock { recenterCount })
            // The End Link panel takes the display back until it closes and the app sends a keyframe.
            if bridge.runtimeIsDriving && !renderer.isPanelVisible && !lock.withLock({ runtimeAwaitingKeyframe }) {
                lock.withLock {
                    lastInput = (controllers, [nil, nil])
                    // The headset is decoding the app's stream; Tether's next own frame must not reference its old ones.
                    needsKeyframe = true
                }
                return
            }
        }

        let proceed: Bool = lock.withLock {
            // Render, encode and USB send overlap; a deeper queue would only add latency.
            guard inFlight < 3 else { return false }
            inFlight += 1
            frameID &+= 1
            return true
        }
        guard proceed else { return }
        let (keyframe, id) = lock.withLock { () -> (Bool, UInt32) in
            let due = Self.intraOnly || needsKeyframe || Date().timeIntervalSince(lastKeyframe) >= Self.keyframeInterval
            if due {
                needsKeyframe = false
                lastKeyframe = Date()
            }
            return (due, frameID)
        }

        let source: VRRenderer.ScreenSource
        if let frame = capture.latestFrame() {
            source = .desktop(frame)
        } else if capture.permissionDenied, let permissionCard {
            source = .card(permissionCard)
        } else if let waitingCard {
            source = .card(waitingCard)
        } else {
            lock.withLock { inFlight -= 1 }
            return
        }

        // Controllers: draw their rays, and drive the Mac pointer when one points at the desktop.
        let active = pointer.activeHandIndex
        var hits: [SIMD2<Float>?] = [nil, nil]
        var panelHits: [SIMD2<Float>?] = [nil, nil]
        let renders = self.renders
        renders.enter()
        let submitted = renderer.render(pose: pose, source: source, controllers: controllers, activeHand: active,
                                        pressed: controllers[active].trigger > 0.7, hits: &hits,
                                        panelHits: &panelHits) { [weak self] slices in
            self?.encoder.encode(frameID: id, pose: pose, slices: slices, keyframe: keyframe)
            renders.leave()
        }
        lock.withLock { lastInput = (controllers, hits) }
        if renderer.isPanelVisible {
            // A drag in progress must not stay held while the panel has the controllers.
            pointer.releaseButtons()
            handlePanel(controllers: controllers, hits: panelHits)
        } else if let display = capture.displayBounds {
            pointer.update(controllers: controllers, hits: hits, display: display) { [weak self] in self?.renderer.requestRecenter() }
        }
        if !submitted {
            renders.leave()
            lock.withLock {
                inFlight -= 1
                needsKeyframe = true
            }
        }
    }

    /// Development aid: TETHER_DUMP_SLICE=/path writes slice 0 of the first 120 frames as Annex-B.
    private static let dumpPath = ProcessInfo.processInfo.environment["TETHER_DUMP_SLICE"]
    private var dumpedFrames = 0

    private var systemHeldSince: Date?
    private var systemHoldHandled = false
    /// Incremented on every recenter, so the OpenXR runtime can recenter the editor's view too.
    private var recenterCount: UInt32 = 0

    /// Called on the render queue when the user confirms End Link in the headset.
    var onEndLinkRequested: (() -> Void)?
    private var panelTriggerDown = [false, false]

    /// Meta (system) button: hold to recenter, like on Quest; a short press opens the End Link panel.
    private func handleSystemButton(_ controllers: [qlh_controller]) {
        let held = controllers.contains { $0.valid && $0.buttons & QLH_BTN_SYSTEM != 0 }
        if !held {
            if let since = systemHeldSince, !systemHoldHandled, Date().timeIntervalSince(since) < 0.75 {
                renderer.preparePanelTextures()
                renderer.setPanelVisible(!renderer.isPanelVisible)
                panelTriggerDown = controllers.map { $0.trigger > 0.7 }
            }
            systemHeldSince = nil
            systemHoldHandled = false
            return
        }
        let since = systemHeldSince ?? Date()
        systemHeldSince = since
        if !systemHoldHandled && Date().timeIntervalSince(since) >= 0.75 {
            systemHoldHandled = true
            recenter()
        }
    }

    /// Trigger on a panel button: End Link ends the session, Cancel closes the panel.
    private func handlePanel(controllers: [qlh_controller], hits: [SIMD2<Float>?]) {
        for index in 0..<2 {
            let down = controllers[index].trigger > 0.7
            defer { panelTriggerDown[index] = down }
            guard down, !panelTriggerDown[index], let uv = hits[index] else { continue }
            switch VRRenderer.panelButton(at: uv) {
            case 1:
                renderer.setPanelVisible(false)
                onEndLinkRequested?()
            case 2:
                renderer.setPanelVisible(false)
            default:
                break
            }
        }
    }

    /// Set while Tether's own frames replace the OpenXR app's; cleared by the app's next keyframe.
    private var runtimeAwaitingKeyframe = false

    /// Frames from an OpenXR app go straight to the headset, except while the End Link panel is open.
    private func forwardRuntimeFrame(_ frame: EncodedFrame) {
        let isKeyframe = frame.codecConfig.contains { !$0.isEmpty }
        let forward: Bool = lock.withLock {
            if renderer.isPanelVisible {
                if !runtimeAwaitingKeyframe { needsKeyframe = true }
                runtimeAwaitingKeyframe = true
                return false
            }
            if runtimeAwaitingKeyframe && !isKeyframe { return false }
            runtimeAwaitingKeyframe = false
            return true
        }
        if forward { send(frame, counted: false) }
    }

    /// `counted` frames come from this pipeline's own renderer and hold an in-flight slot.
    private func send(_ frame: EncodedFrame, counted: Bool = true) {
        sendQueue.async { [self] in
            guard !lock.withLock({ stopped }) else { return }
            if let path = Self.dumpPath, dumpedFrames < 120 {
                if dumpedFrames == 0 { FileManager.default.createFile(atPath: path, contents: nil) }
                if let handle = FileHandle(forWritingAtPath: path) {
                    handle.seekToEndOfFile()
                    handle.write(frame.codecConfig[0] + frame.video[0])
                    try? handle.close()
                }
                dumpedFrames += 1
            }
            var blob = Data()
            var ranges: [(Range<Int>, Range<Int>)] = []
            for index in 0..<frame.video.count {
                let csdStart = blob.count
                blob.append(frame.codecConfig[index])
                let videoStart = blob.count
                blob.append(frame.video[index])
                ranges.append((csdStart..<videoStart, videoStart..<blob.count))
            }
            var pose = frame.pose
            let sent = blob.withUnsafeBytes { raw -> Bool in
                // An OpenXR app can send a frame with no payload at all.
                guard let base = raw.baseAddress else { return false }
                var slices = ranges.map { csd, video in
                    qlh_slice(codec_config: csd.isEmpty ? nil : base + csd.lowerBound, codec_config_bytes: csd.count,
                              video: base + video.lowerBound, video_bytes: video.count)
                }
                return slices.withUnsafeMutableBufferPointer { qlh_send_frame(host, frame.frameID, &pose, $0.baseAddress) }
            }
            lock.withLock {
                if counted { inFlight -= 1 }
                if sent {
                    framesSent += 1
                } else {
                    needsKeyframe = true
                }
            }
        }
    }
}
