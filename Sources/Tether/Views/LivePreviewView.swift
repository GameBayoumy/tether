import AppKit
import CoreVideo
import SwiftUI

/// Shows the frames Tether renders for the headset, straight from their IOSurfaces, at display rate.
struct LivePreviewView: NSViewRepresentable {
    let source: () -> CVPixelBuffer?

    func makeNSView(context: Context) -> PreviewNSView {
        PreviewNSView(source: source)
    }

    func updateNSView(_ view: PreviewNSView, context: Context) {
        view.source = source
    }
}

final class PreviewNSView: NSView {
    var source: () -> CVPixelBuffer?
    private var current: CVPixelBuffer?
    private var timer: Timer?

    init(source: @escaping () -> CVPixelBuffer?) {
        self.source = source
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspectFill
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        guard window != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        guard let buffer = source(), buffer !== current, let surface = CVPixelBufferGetIOSurface(buffer) else { return }
        // Hold the buffer while it's on screen so the pool doesn't hand it back to the renderer.
        current = buffer
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = surface.takeUnretainedValue()
        CATransaction.commit()
    }

    deinit { timer?.invalidate() }
}
