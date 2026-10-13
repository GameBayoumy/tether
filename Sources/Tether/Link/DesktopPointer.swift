import ApplicationServices
import CoreGraphics
import CXRSP
import Foundation

/// Turns a controller ray on the virtual screen into real macOS mouse input:
/// pointing moves the cursor, trigger clicks and drags, A/X right-clicks, the thumbstick scrolls.
final class DesktopPointer: @unchecked Sendable {
    enum Hand: Int { case left = 0, right = 1 }

    private let lock = NSLock()
    private var enabledValue = true
    private var activeHand: Hand = .right
    private var smoothed: SIMD2<Float>?
    private var lastPosted: CGPoint?
    private var leftDown = false
    private var rightDown = false
    private var previousButtons: [UInt32] = [0, 0]
    private var previousTrigger: [Float] = [0, 0]
    private let source = CGEventSource(stateID: .hidSystemState)

    var isEnabled: Bool {
        get { lock.withLock { enabledValue } }
        set {
            lock.withLock { enabledValue = newValue }
            if !newValue { releaseButtons() }
        }
    }

    var activeHandIndex: Int { lock.withLock { activeHand.rawValue } }

    static var hasPermission: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to Accessibility settings.
    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Called once per rendered frame with both controllers and where each one's ray hits the screen (0...1 uv).
    /// `display` is the captured display in global coordinates.
    func update(controllers: [qlh_controller], hits: [SIMD2<Float>?], display: CGRect, onRecenter: () -> Void) {
        guard isEnabled, Self.hasPermission, display.width > 0 else { return }
        lock.lock()
        defer { lock.unlock() }

        // The hand that last pulled its trigger drives the pointer.
        for index in 0..<2 where controllers[index].valid {
            if controllers[index].trigger > 0.6 && previousTrigger[index] <= 0.6 {
                activeHand = Hand(rawValue: index) ?? .right
            }
        }
        let hand = activeHand.rawValue
        let controller = controllers[hand]

        // B / Y recenters the screen in front of you.
        for index in 0..<2 {
            let buttons = controllers[index].buttons
            let recenterButton = index == 1 ? QLH_BTN_B : QLH_BTN_Y
            if buttons & recenterButton != 0 && previousButtons[index] & recenterButton == 0 { onRecenter() }
        }

        if let hit = hits[hand] {
            // Exponential smoothing removes hand tremor, which is magnified at screen distance.
            let target = SIMD2<Float>(min(max(hit.x, 0), 1), min(max(hit.y, 0), 1))
            let current = smoothed.map { $0 + (target - $0) * 0.45 } ?? target
            smoothed = current
            let point = CGPoint(x: display.minX + CGFloat(current.x) * display.width,
                                y: display.minY + CGFloat(current.y) * display.height)
            let moved = lastPosted.map { abs($0.x - point.x) + abs($0.y - point.y) > 0.75 } ?? true

            if controller.trigger > 0.7 && !leftDown {
                post(.leftMouseDown, at: point, button: .left)
                leftDown = true
            } else if controller.trigger < 0.35 && leftDown {
                post(.leftMouseUp, at: point, button: .left)
                leftDown = false
            } else if moved {
                post(leftDown ? .leftMouseDragged : .mouseMoved, at: point, button: .left, from: lastPosted)
            }

            let rightButton = hand == 1 ? QLH_BTN_A : QLH_BTN_X
            let rightPressed = controller.buttons & rightButton != 0
            if rightPressed && !rightDown {
                post(.rightMouseDown, at: point, button: .right)
                rightDown = true
            } else if !rightPressed && rightDown {
                post(.rightMouseUp, at: point, button: .right)
                rightDown = false
            }

            // Thumbstick scrolls; a dead zone keeps a resting stick from drifting the page.
            let dx = abs(controller.stick_x) > 0.25 ? controller.stick_x : 0
            let dy = abs(controller.stick_y) > 0.25 ? controller.stick_y : 0
            if dx != 0 || dy != 0,
               let scroll = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                    wheel1: Int32(dy * 16), wheel2: Int32(-dx * 16), wheel3: 0) {
                scroll.location = point
                scroll.post(tap: .cghidEventTap)
            }
            lastPosted = point
        } else {
            smoothed = nil
            releaseButtonsLocked()
        }

        previousButtons = [controllers[0].buttons, controllers[1].buttons]
        previousTrigger = [controllers[0].trigger, controllers[1].trigger]
    }

    /// Lets go of any mouse button Tether is holding, e.g. when the session ends mid-drag.
    func releaseButtons() {
        lock.withLock { releaseButtonsLocked() }
    }

    private func releaseButtonsLocked() {
        guard leftDown || rightDown, let point = lastPosted else { return }
        if leftDown { post(.leftMouseUp, at: point, button: .left) }
        if rightDown { post(.rightMouseUp, at: point, button: .right) }
        leftDown = false
        rightDown = false
    }

    /// Window dragging and many apps read the event's movement deltas rather than its position,
    /// so moves and drags carry the delta from the previous point; presses carry a click count.
    private func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton, from previous: CGPoint? = nil) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        if let previous {
            event.setIntegerValueField(.mouseEventDeltaX, value: Int64((point.x - previous.x).rounded()))
            event.setIntegerValueField(.mouseEventDeltaY, value: Int64((point.y - previous.y).rounded()))
        }
        switch type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .leftMouseDragged:
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        default:
            break
        }
        event.post(tap: .cghidEventTap)
    }
}
