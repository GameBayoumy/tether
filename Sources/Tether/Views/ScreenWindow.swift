import AVFoundation
import SwiftUI

struct ScreenWindow: View {
    @EnvironmentObject private var store: DeviceStore
    @EnvironmentObject private var screen: ScreenStreamer
    @State private var eye: EyeMode = .both
    @State private var toast: String?

    private var aspect: CGFloat {
        let size = screen.videoSize
        guard size.height > 0 else { return 16 / 9 }
        return (eye == .both ? size.width : size.width / 2) / size.height
    }

    var body: some View {
        ZStack {
            Color.black
            VideoView(layer: screen.displayLayer, eye: eye)
                .aspectRatio(aspect, contentMode: .fit)
                .opacity(screen.state == .streaming ? 1 : 0)
            overlay
        }
        .overlay(alignment: .bottomLeading) {
            if screen.state == .streaming {
                Text("\(screen.fps) fps · \(String(format: "%.1f", screen.megabitsPerSecond)) Mb/s · \(Int(screen.videoSize.width))×\(Int(screen.videoSize.height))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.black.opacity(0.5), in: Capsule())
                    .padding(12)
            }
        }
        .overlay(alignment: .top) {
            if let toast {
                Text(toast)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(minWidth: 520, minHeight: 300)
        .navigationTitle("\(store.deviceName) Screen")
        .toolbar {
            ToolbarItemGroup {
                Picker("View", selection: $eye) {
                    ForEach(EyeMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Choose which eye to show")

                Picker("Quality", selection: $screen.quality) {
                    ForEach(StreamQuality.allCases) { quality in
                        Text("\(quality.rawValue) · \(quality.size.replacingOccurrences(of: "x", with: "×"))").tag(quality)
                    }
                }
                .help("Stream resolution and bitrate")

                if let status = store.status {
                    Toggle(isOn: Binding(
                        get: { status.keepAwake },
                        set: { enabled in Task { await store.setKeepAwake(enabled) } }
                    )) {
                        Label("Keep Awake", systemImage: status.keepAwake ? "sun.max.fill" : "moon.zzz")
                    }
                    .toggleStyle(.button)
                    .help("Keep the headset display on while it isn't being worn")
                }

                Button(action: takeScreenshot) {
                    Label("Screenshot", systemImage: "camera")
                }
                .disabled(screen.state != .streaming)
                .help("Save the current frame to Pictures › Tether")

                Button {
                    screen.isRunning ? screen.stop() : startIfPossible()
                } label: {
                    Label(screen.isRunning ? "Stop" : "Start",
                          systemImage: screen.isRunning ? "stop.fill" : "play.fill")
                }
                .disabled(!store.connection.isConnected)
            }
        }
        .onAppear(perform: startIfPossible)
        .onDisappear { screen.stop() }
        .onChange(of: store.primaryADB) {
            if store.connection.isConnected { startIfPossible() } else { screen.stop() }
        }
    }

    @ViewBuilder
    private var overlay: some View {
        if !store.connection.isConnected {
            placeholder(symbol: "visionpro", text: "Connect your Quest to see its screen")
        } else {
            switch screen.state {
            case .idle:
                placeholder(symbol: "play.rectangle", text: "Screen stream stopped")
            case .connecting:
                if let status = store.status, status.isAsleep, !status.keepAwake {
                    VStack(spacing: 14) {
                        placeholder(symbol: "moon.zzz", text: "The headset is asleep, so its display is off. Put it on, or keep it awake from here.")
                        Button("Wake & Keep Awake") {
                            Task { await store.setKeepAwake(true) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large).tint(.white)
                        Text("Waiting for the headset display…").foregroundStyle(.white.opacity(0.75))
                    }
                }
            case .failed(let message):
                placeholder(symbol: "exclamationmark.triangle", text: message)
            case .streaming:
                EmptyView()
            }
        }
    }

    private func placeholder(symbol: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 40, weight: .light))
            Text(text).multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .foregroundStyle(.white.opacity(0.7))
    }

    private func startIfPossible() {
        guard store.connection.isConnected, let adb = store.adb, let serial = store.primaryADB?.serial else { return }
        screen.start(adbPath: adb.path, serial: serial)
    }

    private func takeScreenshot() {
        guard var image = screen.snapshot() else { return }
        if eye != .both {
            let half = image.width / 2
            let rect = CGRect(x: eye == .left ? 0 : half, y: 0, width: half, height: image.height)
            image = image.cropping(to: rect) ?? image
        }
        guard let url = store.saveScreenshot(image) else { return }
        withAnimation { toast = "Saved \(url.lastPathComponent)" }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { toast = nil }
        }
    }
}

/// Hosts the shared display layer, cropping to one eye by widening the layer inside a clipped view.
struct VideoView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    let eye: EyeMode

    func makeNSView(context: Context) -> VideoNSView {
        VideoNSView(videoLayer: layer)
    }

    func updateNSView(_ view: VideoNSView, context: Context) {
        view.eye = eye
    }
}

final class VideoNSView: NSView {
    private let videoLayer: AVSampleBufferDisplayLayer

    var eye: EyeMode = .both {
        didSet { needsLayout = true }
    }

    init(videoLayer: AVSampleBufferDisplayLayer) {
        self.videoLayer = videoLayer
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
        layer?.backgroundColor = .black
        layer?.addSublayer(videoLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        switch eye {
        case .both: videoLayer.frame = b
        case .left: videoLayer.frame = CGRect(x: 0, y: 0, width: b.width * 2, height: b.height)
        case .right: videoLayer.frame = CGRect(x: -b.width, y: 0, width: b.width * 2, height: b.height)
        }
        CATransaction.commit()
    }
}
