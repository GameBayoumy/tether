import AVFoundation
import Foundation

enum EyeMode: String, CaseIterable, Identifiable {
    case both = "Both Eyes"
    case left = "Left Eye"
    case right = "Right Eye"

    var id: String { rawValue }
}

enum StreamQuality: String, CaseIterable, Identifiable {
    case performance = "Performance"
    case balanced = "Balanced"
    case sharp = "Sharp"

    var id: String { rawValue }

    /// Sizes keep the Quest's 2:1-eyes aspect and stay multiples of 16 for the AVC encoder.
    var size: String {
        switch self {
        case .performance: return "1280x688"
        case .balanced: return "1920x1024"
        case .sharp: return "2560x1376"
        }
    }

    var bitRate: Int {
        switch self {
        case .performance: return 8_000_000
        case .balanced: return 16_000_000
        case .sharp: return 24_000_000
        }
    }
}

/// Streams the headset compositor output using the built-in `screenrecord` over adb.
@MainActor
final class ScreenStreamer: ObservableObject {
    enum State: Equatable {
        case idle
        case connecting
        case streaming
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var fps = 0
    @Published private(set) var megabitsPerSecond = 0.0
    @Published private(set) var videoSize = CGSize(width: 1920, height: 1024)
    @Published var quality: StreamQuality = .balanced {
        didSet { if quality != oldValue && wanted { launch() } }
    }

    let displayLayer = AVSampleBufferDisplayLayer()

    private let pipeline = DecodePipeline()
    private var process: Process?
    private var adbPath: String?
    private var serial: String?
    private var wanted = false
    private var generation = 0
    private var quickFailures = 0
    private var launchedAt = Date()
    private var lastErrorText = ""
    private var idleSeconds = 0
    private var statsTask: Task<Void, Never>?

    init() {
        displayLayer.videoGravity = .resize
        displayLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        pipeline.onFormatChange = { [weak self] size in
            Task { @MainActor in self?.videoSize = size }
        }
    }

    var isRunning: Bool { wanted }

    func start(adbPath: String, serial: String) {
        if wanted && self.serial == serial && process?.isRunning == true { return }
        self.adbPath = adbPath
        self.serial = serial
        wanted = true
        quickFailures = 0
        launch()
        startStats()
    }

    func stop() {
        wanted = false
        generation += 1
        terminate()
        statsTask?.cancel()
        statsTask = nil
        state = .idle
        fps = 0
        megabitsPerSecond = 0
    }

    func snapshot() -> CGImage? { pipeline.snapshot() }

    private func launch() {
        terminate()
        guard let adbPath, let serial else { return }
        generation += 1
        let gen = generation
        state = .connecting
        lastErrorText = ""
        launchedAt = Date()
        pipeline.reset(renderer: displayLayer.sampleBufferRenderer)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = [
            "-s", serial, "exec-out", "screenrecord",
            "--output-format=h264", "--size", quality.size,
            "--bit-rate", String(quality.bitRate), "--time-limit", "0", "-",
        ]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let pipeline = self.pipeline
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                pipeline.ingest(data)
            }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.lastErrorText = String((self?.lastErrorText ?? "") + text).suffix(500).description }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.processEnded(generation: gen) }
        }

        do {
            try process.run()
            self.process = process
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func terminate() {
        if let process, process.isRunning { process.terminate() }
        process = nil
    }

    private func processEnded(generation gen: Int) {
        guard gen == generation, wanted else { return }
        process = nil
        // screenrecord exits when the display reconfigures; restart unless it keeps dying immediately.
        if Date().timeIntervalSince(launchedAt) < 3 {
            quickFailures += 1
        } else {
            quickFailures = 0
        }
        if quickFailures >= 3 {
            let detail = lastErrorText.trimmingCharacters(in: .whitespacesAndNewlines)
            state = .failed(detail.isEmpty ? "The headset stopped the screen stream." : detail)
            wanted = false
            return
        }
        state = .connecting
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.wanted, gen == self.generation else { return }
            self.launch()
        }
    }

    private func startStats() {
        statsTask?.cancel()
        statsTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let stats = self.pipeline.takeStats()
                self.fps = stats.frames
                self.megabitsPerSecond = Double(stats.bytes) * 8 / 1_000_000
                // The Quest stops emitting frames when its display sleeps; fall back to the waiting state.
                self.idleSeconds = stats.frames > 0 ? 0 : self.idleSeconds + 1
                if stats.frames > 0 && self.state == .connecting {
                    self.state = .streaming
                } else if self.idleSeconds >= 3 && self.state == .streaming {
                    self.state = .connecting
                }
            }
        }
    }
}
