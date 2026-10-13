import SwiftUI

/// The near pane. While Link is live it is a window into the headset: Tether's own left-eye frame,
/// with a status chip and one slim control bar. Otherwise a quiet standby room and the next step.
struct Viewport: View {
    @EnvironmentObject private var store: DeviceStore
    @EnvironmentObject private var link: LinkService
    @Environment(\.openWindow) private var openWindow
    @State private var showingHeadsetView = false

    private var live: Bool { link.state == .streaming }

    var body: some View {
        ZStack(alignment: .bottom) {
            stage
            controlBar
        }
        .overlay(alignment: .topLeading) { chip.padding(16) }
        .background(Theme.pane)
        .clipShape(RoundedRectangle(cornerRadius: Theme.viewportRadius, style: .continuous))
        .shadow(color: .black.opacity(0.6), radius: 40, x: 0, y: 26)
        .animation(.easeOut(duration: 0.5), value: live)
    }

    // MARK: Stage

    @ViewBuilder
    private var stage: some View {
        if showingHeadsetView && store.connection.isConnected {
            HeadsetMirror()
        } else if live {
            LivePreviewView { link.latestPreview() }
                .overlay(alignment: .bottom) {
                    // A low scrim so the control bar reads over bright desktops.
                    LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 110)
                        .allowsHitTesting(false)
                }
                .transition(.opacity)
        } else {
            ZStack {
                StandbyRoom()
                standbyMessage
                    .padding(.horizontal, 44)
                    .padding(.bottom, 60)
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var standbyMessage: some View {
        VStack(spacing: 12) {
            switch link.state {
            case .ready:
                headline("Ready to tether")
                Text("Put on your headset and choose **Launch** on the Quest Link prompt.")
                    .font(.system(size: 14.5)).foregroundStyle(Theme.text)
                Text("No prompt? Open Quick Settings › Quest Link.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
            case .connecting:
                headline("Pairing…")
                ProgressView().controlSize(.small).padding(.top, 4)
            case .waitingForDevice:
                headline("Connect your Quest")
                Text("Use a USB‑C data cable, straight into the Mac. If macOS asks to allow the accessory, click Allow.")
                    .font(.system(size: 13.5)).foregroundStyle(Theme.textSecondary)
            case .off:
                headline("Link is off")
                Button("Turn on Link") { link.isEnabled = true }.buttonStyle(PrimaryButtonStyle()).padding(.top, 4)
            case .streaming:
                EmptyView()
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Chip

    @ViewBuilder
    private var chip: some View {
        if live && !showingHeadsetView {
            HStack(spacing: 7) {
                Circle().fill(Theme.gold).frame(width: 7, height: 7)
                Text("Live").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.gold)
                Text("\(link.framesPerSecond) fps · \(String(format: "%.0f", link.megabitsPerSecond)) Mb/s")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.text)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(.black.opacity(0.62), in: Capsule())
        } else if let warning {
            Label(warning, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.attention)
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(.black.opacity(0.62), in: Capsule())
        }
    }

    private var warning: String? {
        if link.screenCaptureDenied { return "Allow Screen Recording for Tether, then reopen it" }
        if store.connection == .unauthorized { return "Allow USB debugging in the headset" }
        return nil
    }

    // MARK: Control bar

    private var controlBar: some View {
        HStack(spacing: 10) {
            Text(link.state.title).font(.system(size: 12.5)).foregroundStyle(link.state.tint)
            if live && !link.canControlMac {
                Button("Allow Pointer…") { link.requestControlPermission() }
                    .buttonStyle(SecondaryButtonStyle())
                    .help("Allow Accessibility so the controllers can move the Mac pointer")
            }

            Spacer()

            if live {
                barButton("scope", help: "Put the screen straight ahead of where you're looking") { link.recenter() }
                barButton("xmark.circle", help: "End Quest Link; the headset returns to Quest Home") { link.endLink() }
            }
            barButton(showingHeadsetView ? "eye.slash" : "eye",
                      help: showingHeadsetView ? "Back to Tether's view" : "See the headset's own view (needs USB debugging)") {
                showingHeadsetView.toggle()
            }
            .disabled(!store.connection.isConnected)
            barButton("arrow.up.forward.app", help: "Open the headset view in its own window") {
                showingHeadsetView = false
                openWindow(id: "screen")
            }
            .disabled(!store.connection.isConnected)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func barButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 16, height: 16)
        }
        .buttonStyle(SecondaryButtonStyle())
        .help(help)
    }

    private func headline(_ text: String) -> some View {
        Text(text).font(Theme.title(26)).tracking(-0.3)
    }
}

/// The empty room seen through the viewport while nothing is streaming.
private struct StandbyRoom: View {
    var body: some View {
        Canvas { context, size in
            let horizon = size.height * 0.62
            let vanishing = CGPoint(x: size.width / 2, y: horizon)
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .linearGradient(Gradient(colors: [Theme.pane, Color(hex: 0x0E1420), Theme.floor]),
                                               startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.fill(Path(ellipseIn: CGRect(x: vanishing.x - size.width * 0.6, y: horizon - 60, width: size.width * 1.2, height: 120)),
                         with: .radialGradient(Gradient(colors: [Color(hex: 0x5B7BB8).opacity(0.14), .clear]),
                                               center: vanishing, startRadius: 0, endRadius: size.width * 0.6))
            for i in -10...10 {
                var line = Path()
                line.move(to: vanishing)
                line.addLine(to: CGPoint(x: vanishing.x + CGFloat(i) * size.width * 0.12, y: size.height))
                context.stroke(line, with: .linearGradient(Gradient(colors: [.white.opacity(0), .white.opacity(0.07)]),
                                                           startPoint: vanishing, endPoint: CGPoint(x: vanishing.x, y: size.height)),
                               lineWidth: 1)
            }
            for k in 1...9 {
                let y = horizon + (size.height - horizon) / (CGFloat(k) * 0.6)
                guard y < size.height else { continue }
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(.white.opacity(0.05)), lineWidth: 1)
            }
        }
    }
}

/// The headset's own composited view, mirrored over adb.
private struct HeadsetMirror: View {
    @EnvironmentObject private var store: DeviceStore
    @EnvironmentObject private var screen: ScreenStreamer
    @State private var eye: EyeMode = .left

    var body: some View {
        ZStack {
            Color.black
            VideoView(layer: screen.displayLayer, eye: eye)
                .aspectRatio(aspect, contentMode: .fill)
                .opacity(screen.state == .streaming ? 1 : 0)
            if screen.state != .streaming {
                VStack(spacing: 10) {
                    if store.status?.isAsleep == true && store.status?.keepAwake == false {
                        Text("The headset is asleep.").foregroundStyle(Theme.textSecondary)
                        Button("Wake and keep awake") { Task { await store.setKeepAwake(true) } }
                            .buttonStyle(PrimaryButtonStyle())
                    } else if case .failed(let message) = screen.state {
                        Text(message).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .font(.system(size: 13))
                .padding(24)
            }
        }
        .overlay(alignment: .topTrailing) {
            Picker("Eye", selection: $eye) {
                ForEach(EyeMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .padding(12)
        }
        .onAppear(perform: start)
        .onDisappear { screen.stop() }
    }

    private var aspect: CGFloat {
        let size = screen.videoSize
        guard size.height > 0 else { return 16 / 9 }
        return (eye == .both ? size.width : size.width / 2) / size.height
    }

    private func start() {
        guard let adb = store.adb, let serial = store.primaryADB?.serial else { return }
        screen.start(adbPath: adb.path, serial: serial)
    }
}
