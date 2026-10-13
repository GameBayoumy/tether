import Combine
import CoreVideo
import CXRSP
import Foundation
import os

private let log = Logger(subsystem: "io.dashxr.Tether", category: "link")

enum LinkState: Equatable {
    case off
    case waitingForDevice
    case connecting
    case ready
    case streaming

    init(_ state: qlh_state) {
        switch state {
        case QLH_STATE_WAITING_FOR_DEVICE: self = .waitingForDevice
        case QLH_STATE_CONNECTING: self = .connecting
        case QLH_STATE_HOST_CONNECTED: self = .ready
        case QLH_STATE_STREAMING: self = .streaming
        default: self = .off
        }
    }

    var title: String {
        switch self {
        case .off: return "Off"
        case .waitingForDevice: return "Waiting for headset"
        case .connecting: return "Connecting…"
        case .ready: return "Ready"
        case .streaming: return "Link active"
        }
    }
}

/// Owns the native Quest Link host and, while the headset is streaming, the render pipeline.
@MainActor
final class LinkService: ObservableObject {
    @Published private(set) var state: LinkState = .off
    @Published private(set) var framesPerSecond = 0
    @Published private(set) var posesPerSecond = 0
    @Published private(set) var megabitsPerSecond = 0.0
    @Published private(set) var screenCaptureDenied = false
    /// Whether macOS lets Tether post mouse events (Accessibility permission).
    @Published private(set) var canControlMac = DesktopPointer.hasPermission

    func requestControlPermission() {
        DesktopPointer.requestPermission()
    }

    @Published var isEnabled: Bool = UserDefaults.standard.object(forKey: "linkEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "linkEnabled")
            isEnabled ? start() : stop()
        }
    }

    private var host: OpaquePointer?
    /// Shared tracking + frame socket for the Tether OpenXR runtime (Unity / Unreal). Lazy, so
    /// `--snapshot` instances never bind the socket a running Tether is serving.
    private lazy var bridge = XRBridge()
    private var pipeline: StreamPipeline?
    private var statsTask: Task<Void, Never>?
    private var lastPoseCount: UInt64 = 0
    private var endLinkObserver: NSObjectProtocol?

    func start() {
        guard host == nil, isEnabled else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        host = qlh_create({ user, state, _ in
            guard let user else { return }
            let service = Unmanaged<LinkService>.fromOpaque(user).takeUnretainedValue()
            Task { @MainActor in service.handle(state) }
        }, context)
        qlh_start(host)
        startStats()
        // Lets scripts end Link by posting the distributed notification "io.dashxr.Tether.endLink".
        if endLinkObserver == nil {
            endLinkObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("io.dashxr.Tether.endLink"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.endLink() }
            }
        }
    }

    func stop() {
        statsTask?.cancel()
        statsTask = nil
        stopPipeline()
        guard let host else { return }
        self.host = nil
        state = .off
        // Stopping joins the host thread, which can take a moment mid-handshake.
        nonisolated(unsafe) let doomed = host
        DispatchQueue.global(qos: .userInitiated).async { qlh_destroy(doomed) }
    }

    /// Fixed state for design snapshots (`--snapshot`).
    func loadSnapshot(state: LinkState, fps: Int, mbps: Double, poses: Int) {
        self.state = state
        framesPerSecond = fps
        megabitsPerSecond = mbps
        posesPerSecond = poses
    }

    /// Latest left-eye frame Tether rendered for the headset (nil when not streaming).
    func latestPreview() -> CVPixelBuffer? {
        pipeline?.latestPreview()
    }

    /// Ends Quest Link; the headset returns to Quest Home and Tether waits for the next Launch.
    func endLink() {
        guard let host, state == .streaming else { return }
        log.notice("Ending Link from this Mac")
        if !qlh_end_streaming(host) { log.error("Couldn't end the Link session") }
    }

    func recenter() {
        pipeline?.recenter()
    }

    private var stalledPairings = 0
    private var lastGadgetReset = Date.distantPast

    /// The headset's Link service can stop answering after a host vanishes mid-session. Pairing then
    /// cycles Connecting -> Waiting; with USB debugging available, resetting the headset's USB gadget fixes it.
    private func noteStalledPairing(from old: LinkState, to new: LinkState) {
        if new == .ready || new == .streaming {
            stalledPairings = 0
            return
        }
        guard old == .connecting, new == .waitingForDevice else { return }
        stalledPairings += 1
        guard stalledPairings >= 2, Date().timeIntervalSince(lastGadgetReset) > 60,
              let adbPath = ADB.locate() else { return }
        lastGadgetReset = Date()
        stalledPairings = 0
        log.notice("Pairing stalled; resetting the headset's USB gadget")
        Task.detached { _ = try? await ADB(path: adbPath).run(["shell", "svc", "usb", "resetUsbGadget"]) }
    }

    private func handle(_ newState: qlh_state) {
        guard host != nil else { return }
        let previous = state
        state = LinkState(newState)
        noteStalledPairing(from: previous, to: state)
        log.notice("Link state: \(self.state.title, privacy: .public)")
        if state == .streaming {
            startPipeline()
        } else {
            stopPipeline()
        }
    }

    private func startPipeline() {
        guard pipeline == nil, let host else { return }
        var info = qlh_headset_info()
        _ = qlh_get_headset_info(host, &info)
        do {
            let pipeline = try StreamPipeline(host: host, info: info, bridge: bridge)
            pipeline.onEndLinkRequested = { [weak self] in
                Task { @MainActor in self?.endLink() }
            }
            if !DesktopPointer.hasPermission && !UserDefaults.standard.bool(forKey: "askedAccessibility") {
                // Ask once; after that the viewport offers the Allow… button.
                UserDefaults.standard.set(true, forKey: "askedAccessibility")
                DesktopPointer.requestPermission()
            }
            pipeline.start()
            self.pipeline = pipeline
            log.notice("Streaming \(info.display_width)x\(info.display_height) @ \(info.refresh_hz) Hz, left eye FOV up \(info.eye_fov.0.up) down \(info.eye_fov.0.down) left \(info.eye_fov.0.left) right \(info.eye_fov.0.right)")
        } catch {
            log.error("Pipeline failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stopPipeline() {
        pipeline?.stop()
        pipeline = nil
        framesPerSecond = 0
        megabitsPerSecond = 0
    }

    private func startStats() {
        statsTask?.cancel()
        statsTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                guard let host = self.host else { continue }
                var count: UInt64 = 0
                _ = qlh_get_pose(host, nil, &count)
                self.posesPerSecond = count >= self.lastPoseCount ? Int(count - self.lastPoseCount) : 0
                self.lastPoseCount = count
                self.megabitsPerSecond = Double(qlh_take_sent_bytes(host)) * 8 / 1_000_000
                self.framesPerSecond = self.pipeline?.takeFrameCount() ?? 0
                self.screenCaptureDenied = self.pipeline?.screenCapturePermissionDenied ?? false
                self.canControlMac = DesktopPointer.hasPermission
                if self.state != .streaming { self.bridge.publishIdle() }
                if self.state == .streaming {
                    log.debug("stats fps=\(self.framesPerSecond) mbps=\(self.megabitsPerSecond, format: .fixed(precision: 1)) poses=\(self.posesPerSecond) captureDenied=\(self.screenCaptureDenied) ax=\(self.canControlMac)")
                    log.debug("input \(self.pipeline?.inputSummary() ?? "", privacy: .public)")
                }
            }
        }
    }
}
