import COpenXR
import CXRSP
import Foundation
import simd

/// XrPath <-> string.
final class PathRegistry {
    private let lock = NSLock()
    private var byString: [String: XrPath] = [:]
    private var strings: [String] = [""]

    func path(_ string: String) -> XrPath {
        lock.withLock {
            if let existing = byString[string] { return existing }
            strings.append(string)
            let path = XrPath(strings.count - 1)
            byString[string] = path
            return path
        }
    }

    func string(_ path: XrPath) -> String? {
        lock.withLock { path > 0 && Int(path) < strings.count ? strings[Int(path)] : nil }
    }
}

final class ActionSet {
    unowned let instance: Instance
    let name: String
    var actions: [Action] = []
    var attached = false

    init(instance: Instance, name: String) {
        self.instance = instance
        self.name = name
    }
}

/// One physical input a binding resolves to.
struct InputSource: Hashable {
    enum Component: Hashable {
        case trigger, triggerTouch, squeeze, stick, stickX, stickY, stickClick, stickTouch
        case button(UInt32), touch(UInt32)
        case gripPose, aimPose, haptic
    }

    let hand: Int // 0 left, 1 right
    let component: Component
}

final class Action {
    unowned let set: ActionSet
    let name: String
    let type: XrActionType
    let subactionPaths: [XrPath]
    var sources: [InputSource] = []
    var boundPaths: [XrPath] = []

    // Previous synced values per subaction (0 = aggregate), for changedSinceLastSync.
    var lastBool: [XrPath: Bool] = [:]
    var lastFloat: [XrPath: Float] = [:]
    var lastVector: [XrPath: SIMD2<Float>] = [:]
    var lastChange: [XrPath: XrTime] = [:]
    var current: [XrPath: (bool: Bool, float: Float, vector: SIMD2<Float>, active: Bool)] = [:]
    var changed: [XrPath: Bool] = [:]

    init(set: ActionSet, name: String, type: XrActionType, subactionPaths: [XrPath]) {
        self.set = set
        self.name = name
        self.type = type
        self.subactionPaths = subactionPaths
    }

    /// For pose actions: which controller and whether it's the aim pose.
    func poseSource(subaction: XrPath, instance: Instance) -> (Int, Bool)? {
        let hand = handIndex(subaction, instance: instance)
        for source in sources where hand == nil || source.hand == hand {
            switch source.component {
            case .gripPose: return (source.hand, false)
            case .aimPose: return (source.hand, true)
            default: continue
            }
        }
        return nil
    }
}

func handIndex(_ path: XrPath, instance: Instance) -> Int? {
    switch instance.paths.string(path) {
    case "/user/hand/left": return 0
    case "/user/hand/right": return 1
    default: return nil
    }
}

let touchProfile = "/interaction_profiles/oculus/touch_controller"
let simpleProfile = "/interaction_profiles/khr/simple_controller"

/// Resolves an Oculus Touch / simple controller binding path to a physical input.
func resolveBinding(_ path: String, profile: String) -> InputSource? {
    let parts = path.split(separator: "/").map(String.init) // user, hand, left, input, trigger, value
    guard parts.count >= 4, parts[0] == "user", parts[1] == "hand" else { return nil }
    let hand: Int
    switch parts[2] {
    case "left": hand = 0
    case "right": hand = 1
    default: return nil
    }
    if parts[3] == "output" { return parts.count >= 5 && parts[4] == "haptic" ? InputSource(hand: hand, component: .haptic) : nil }
    guard parts[3] == "input", parts.count >= 5 else { return nil }
    let identifier = parts[4]
    let component = parts.count >= 6 ? parts[5] : ""

    if profile == simpleProfile {
        switch identifier {
        case "select": return InputSource(hand: hand, component: .trigger)
        case "menu": return InputSource(hand: hand, component: .button(QLH_BTN_MENU))
        case "grip": return InputSource(hand: hand, component: .gripPose)
        case "aim": return InputSource(hand: hand, component: .aimPose)
        default: return nil
        }
    }

    let face: (click: UInt32, touch: UInt32)?
    switch (identifier, hand) {
    case ("x", 0): face = (QLH_BTN_X, 0x1)
    case ("y", 0): face = (QLH_BTN_Y, 0x2)
    case ("a", 1): face = (QLH_BTN_A, 0x1)
    case ("b", 1): face = (QLH_BTN_B, 0x2)
    default: face = nil
    }
    if let face {
        return InputSource(hand: hand, component: component == "touch" ? .touch(face.touch) : .button(face.click))
    }
    switch identifier {
    case "trigger":
        if component == "touch" { return InputSource(hand: hand, component: .triggerTouch) }
        return InputSource(hand: hand, component: .trigger)
    case "squeeze":
        return InputSource(hand: hand, component: .squeeze)
    case "thumbstick":
        switch component {
        case "x": return InputSource(hand: hand, component: .stickX)
        case "y": return InputSource(hand: hand, component: .stickY)
        case "click": return InputSource(hand: hand, component: .stickClick)
        case "touch": return InputSource(hand: hand, component: .stickTouch)
        default: return InputSource(hand: hand, component: .stick)
        }
    case "thumbrest":
        return InputSource(hand: hand, component: .touch(0x10))
    case "menu" where hand == 0:
        return InputSource(hand: hand, component: .button(QLH_BTN_MENU))
    case "system" where hand == 1:
        return InputSource(hand: hand, component: .button(QLH_BTN_SYSTEM))
    case "grip":
        return InputSource(hand: hand, component: .gripPose)
    case "aim":
        return InputSource(hand: hand, component: .aimPose)
    default:
        return nil
    }
}

/// Reads one physical input from the published controller state.
func readSource(_ source: InputSource, _ c: qlh_controller) -> (bool: Bool, float: Float, vector: SIMD2<Float>) {
    switch source.component {
    case .trigger: return (c.trigger > 0.55, c.trigger, .zero)
    case .triggerTouch: return (c.touches & 0x8 != 0 || c.trigger > 0.05, c.touches & 0x8 != 0 ? 1 : 0, .zero)
    case .squeeze: return (c.grip > 0.55, c.grip, .zero)
    case .stick: return (false, 0, SIMD2(c.stick_x, c.stick_y))
    case .stickX: return (abs(c.stick_x) > 0.5, c.stick_x, .zero)
    case .stickY: return (abs(c.stick_y) > 0.5, c.stick_y, .zero)
    case .stickClick:
        let pressed = c.buttons & (c.right ? QLH_BTN_STICK_R : QLH_BTN_STICK_L) != 0
        return (pressed, pressed ? 1 : 0, .zero)
    case .stickTouch: return (c.touches & 0x4 != 0, c.touches & 0x4 != 0 ? 1 : 0, .zero)
    case .button(let bit): return (c.buttons & bit != 0, c.buttons & bit != 0 ? 1 : 0, .zero)
    case .touch(let bit): return (c.touches & bit != 0, c.touches & bit != 0 ? 1 : 0, .zero)
    case .gripPose, .aimPose, .haptic: return (false, 0, .zero)
    }
}

extension Session {
    /// Picks the interaction profile the app suggested (Touch preferred) and resolves every attached action.
    func resolveBindings() {
        let instance = self.instance
        let touch = instance.paths.path(touchProfile)
        let simple = instance.paths.path(simpleProfile)
        let chosen = instance.suggested[touch] != nil ? touch : (instance.suggested[simple] != nil ? simple : 0)
        interactionProfile = chosen
        guard chosen != 0, let profileName = instance.paths.string(chosen) else { return }
        for set in attachedSets {
            for action in set.actions {
                action.sources = []
                action.boundPaths = []
            }
        }
        for (action, binding) in instance.suggested[chosen] ?? [] {
            guard let string = instance.paths.string(binding), let source = resolveBinding(string, profile: profileName) else { continue }
            action.sources.append(source)
            action.boundPaths.append(binding)
        }
        var event = XrEventDataInteractionProfileChanged()
        event.type = XR_TYPE_EVENT_DATA_INTERACTION_PROFILE_CHANGED
        event.session = handle
        instance.push(EventRecord(event))
    }

    func syncActions(_ tracking: tether_xr_state?) {
        let controllers = tracking.map { [$0.controllers.0, $0.controllers.1] } ?? [qlh_controller(), qlh_controller()]
        let live = tracking?.streaming == 1
        let time = now()
        for set in attachedSets {
            for action in set.actions {
                let keys: [XrPath] = [0] + action.subactionPaths
                for key in keys {
                    let hand = key == 0 ? nil : handIndex(key, instance: instance)
                    var bool = false
                    var float: Float = 0
                    var vector = SIMD2<Float>.zero
                    var active = false
                    for source in action.sources where hand == nil || source.hand == hand {
                        let controller = controllers[source.hand]
                        guard live && controller.valid else { continue }
                        active = true
                        let value = readSource(source, controller)
                        bool = bool || value.bool
                        if abs(value.float) > abs(float) { float = value.float }
                        if simd_length(value.vector) > simd_length(vector) { vector = value.vector }
                    }
                    let changed: Bool
                    switch action.type {
                    case XR_ACTION_TYPE_BOOLEAN_INPUT: changed = action.lastBool[key] != nil && action.lastBool[key] != bool
                    case XR_ACTION_TYPE_FLOAT_INPUT: changed = action.lastFloat[key] != nil && action.lastFloat[key] != float
                    case XR_ACTION_TYPE_VECTOR2F_INPUT: changed = action.lastVector[key] != nil && action.lastVector[key] != vector
                    default: changed = false
                    }
                    if changed || action.lastChange[key] == nil { action.lastChange[key] = time }
                    action.changed[key] = changed
                    action.lastBool[key] = bool
                    action.lastFloat[key] = float
                    action.lastVector[key] = vector
                    action.current[key] = (bool, float, vector, active)
                }
            }
        }
    }
}
