import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Captures the main display with ScreenCaptureKit for the virtual screen in the headset.
final class DesktopCapture: NSObject, SCStreamOutput, @unchecked Sendable {
    private let queue = DispatchQueue(label: "tether.link.capture", qos: .userInteractive)
    private let lock = NSLock()
    private var stream: SCStream?
    private var latest: CVPixelBuffer?
    private var denied = false
    private var bounds: CGRect?
    /// Bumped by `stop()`, so a capture still starting up when the session ends is shut down instead of kept.
    private var generation = 0

    /// The captured display in global (top-left origin) coordinates, for mapping pointer positions.
    var displayBounds: CGRect? { lock.withLock { bounds } }

    var permissionDenied: Bool { lock.withLock { denied } }

    func latestFrame() -> CVPixelBuffer? {
        lock.withLock { latest }
    }

    func start() {
        guard CGPreflightScreenCaptureAccess() else {
            lock.withLock { denied = true }
            // Shows the system prompt the first time; macOS applies the grant after a relaunch.
            CGRequestScreenCaptureAccess()
            return
        }
        let generation = lock.withLock { self.generation }
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let mainID = CGMainDisplayID()
                guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else { return }

                let config = SCStreamConfiguration()
                var width = display.width * 2
                var height = display.height * 2
                if let mode = CGDisplayCopyDisplayMode(display.displayID) {
                    width = mode.pixelWidth
                    height = mode.pixelHeight
                }
                let scale = min(1.0, 3840.0 / Double(width))
                config.width = Int(Double(width) * scale)
                config.height = Int(Double(height) * scale)
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                config.queueDepth = 4
                config.showsCursor = true

                let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                                      configuration: config, delegate: nil)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                try await stream.startCapture()
                let displayBounds = CGDisplayBounds(display.displayID)
                let current = lock.withLock { () -> Bool in
                    guard generation == self.generation else { return false }
                    self.stream = stream
                    self.bounds = displayBounds
                    return true
                }
                if !current { try? await stream.stopCapture() }
            } catch {
                lock.withLock { denied = true }
            }
        }
    }

    func stop() {
        let stream = lock.withLock { () -> SCStream? in
            defer { self.stream = nil; latest = nil; generation += 1 }
            return self.stream
        }
        stream?.stopCapture { _ in }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.withLock { if stream === self.stream { latest = buffer } }
    }
}
