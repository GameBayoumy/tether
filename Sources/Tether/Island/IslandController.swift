import AppKit
import Combine
import SwiftUI

/// What the island is showing right now.
enum IslandMode: Equatable {
    case compact
    case toast(String, symbol: String, tint: IslandTint)
    case expanded
}

enum IslandTint: Equatable { case neutral, gold, healthy, attention }

/// Shared, observable island state; the controller sizes the panel to match.
@MainActor
final class IslandModel: ObservableObject {
    @Published var mode: IslandMode = .compact
    @Published var hovering = false
    let geometry: IslandGeometry

    init(geometry: IslandGeometry) {
        self.geometry = geometry
    }

    func size(for mode: IslandMode) -> CGSize {
        switch mode {
        case .compact: return CGSize(width: geometry.compactWidth, height: geometry.topHeight)
        case .toast: return CGSize(width: max(geometry.compactWidth, 400), height: geometry.topHeight + 46)
        case .expanded: return CGSize(width: max(geometry.compactWidth, 460), height: geometry.topHeight + 168)
        }
    }
}

/// Where the island sits: wrapped around the notch when there is one, otherwise a tab at the top edge.
struct IslandGeometry {
    var notchWidth: CGFloat
    var topHeight: CGFloat
    var hasNotch: Bool

    var compactWidth: CGFloat { hasNotch ? notchWidth + 2 * 74 : 230 }

    static func forScreen(_ screen: NSScreen) -> IslandGeometry {
        let inset = screen.safeAreaInsets.top
        if inset > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return IslandGeometry(notchWidth: screen.frame.width - left.width - right.width, topHeight: inset, hasNotch: true)
        }
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return IslandGeometry(notchWidth: 0, topHeight: max(26, min(menuBar, 34)), hasNotch: false)
    }
}

/// Owns the borderless panel at the top of the screen and turns device/Link events into island moments.
@MainActor
final class IslandController {
    static let shared = IslandController()

    private var panel: NSPanel?
    private var model: IslandModel?
    private var cancellables: Set<AnyCancellable> = []
    private var toastTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var lastConnection: ConnectionState?
    private var lastLink: LinkState?
    private var warnedLowBattery = false

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "islandEnabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "islandEnabled")
            newValue ? panel?.orderFrontRegardless() : panel?.orderOut(nil)
        }
    }

    func start(store: DeviceStore, link: LinkService, openMain: @escaping () -> Void, openHeadsetView: @escaping () -> Void) {
        guard panel == nil else { return }
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
        else { return }
        let model = IslandModel(geometry: .forScreen(screen))
        self.model = model

        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: IslandView(openMain: openMain, openHeadsetView: openHeadsetView)
            .environmentObject(model)
            .environmentObject(store)
            .environmentObject(link))
        self.panel = panel
        place(size: model.size(for: .compact), on: screen)
        if isEnabled { panel.orderFrontRegardless() }

        model.$mode.removeDuplicates().sink { [weak self] mode in self?.resize(for: mode) }.store(in: &cancellables)
        model.$hovering.removeDuplicates().sink { [weak self] hovering in self?.hoverChanged(hovering) }.store(in: &cancellables)
        store.objectWillChange.receive(on: RunLoop.main).sink { [weak self, weak store] in
            guard let self, let store else { return }
            DispatchQueue.main.async { self.deviceChanged(store) }
        }.store(in: &cancellables)
        link.$state.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] state in self?.linkChanged(state) }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.screensChanged() }.store(in: &cancellables)
    }

    // MARK: Events

    private func deviceChanged(_ store: DeviceStore) {
        let connection = store.connection
        defer { lastConnection = connection }
        if let lastConnection, lastConnection != connection {
            if connection.isConnected && !lastConnection.isConnected {
                toast("\(store.deviceName) connected", symbol: "cable.connector", tint: .healthy)
            } else if connection == .disconnected {
                toast("Headset disconnected", symbol: "cable.connector.slash", tint: .neutral)
            } else if connection == .unauthorized {
                toast("Allow USB debugging in the headset", symbol: "hand.raised", tint: .attention)
            }
        }
        if let level = store.status?.batteryLevel, store.status?.charge != .charging {
            if level <= 15 && !warnedLowBattery {
                warnedLowBattery = true
                toast("Headset battery \(level)%", symbol: "battery.25", tint: .attention)
            } else if level > 20 {
                warnedLowBattery = false
            }
        }
    }

    private func linkChanged(_ state: LinkState) {
        defer { lastLink = state }
        guard let lastLink, lastLink != state else { return }
        switch state {
        case .ready: toast("Ready: choose Launch in your headset", symbol: "visionpro", tint: .neutral)
        case .streaming: toast("Link is live", symbol: "dot.radiowaves.left.and.right", tint: .gold)
        case .waitingForDevice where lastLink == .streaming: toast("Link ended", symbol: "stop.circle", tint: .neutral)
        default: break
        }
    }

    private func toast(_ text: String, symbol: String, tint: IslandTint) {
        guard let model, model.mode != .expanded else { return }
        toastTask?.cancel()
        withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { model.mode = .toast(text, symbol: symbol, tint: tint) }
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3.2))
            guard !Task.isCancelled, let model = self?.model, case .toast = model.mode else { return }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) { model.mode = .compact }
        }
    }

    private func hoverChanged(_ hovering: Bool) {
        guard let model else { return }
        collapseTask?.cancel()
        if hovering {
            toastTask?.cancel()
            withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { model.mode = .expanded }
        } else {
            collapseTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, let model = self?.model, model.mode == .expanded, !model.hovering else { return }
                withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { model.mode = .compact }
            }
        }
    }

    // MARK: Panel geometry

    /// Grow the panel before an expanding animation; shrink it after a collapsing one.
    private func resize(for mode: IslandMode) {
        guard let panel, let model, let screen = panel.screen ?? NSScreen.main else { return }
        let target = model.size(for: mode)
        if target.width >= panel.frame.width && target.height >= panel.frame.height {
            place(size: target, on: screen)
        } else {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(420))
                guard let self, let model = self.model, model.size(for: model.mode) == target else { return }
                self.place(size: target, on: screen)
            }
        }
    }

    private func place(size: CGSize, on screen: NSScreen) {
        let frame = CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)
        panel?.setFrame(frame, display: true)
    }

    private func screensChanged() {
        guard panel != nil, let model,
              let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
        else { return }
        place(size: model.size(for: model.mode), on: screen)
    }
}
