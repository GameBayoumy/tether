import COpenXR
import CXRSP
import Foundation
import Metal
import simd

let systemID: XrSystemId = 0x7E7E

final class Instance {
    let apiVersion: XrVersion
    let applicationName: String
    var events: [EventRecord] = []
    let lock = NSLock()
    var session: Session?
    let paths = PathRegistry()
    var suggested: [XrPath: [(action: Action, binding: XrPath)]] = [:]

    init(apiVersion: XrVersion, applicationName: String) {
        self.apiVersion = apiVersion
        self.applicationName = applicationName
    }

    func push(_ event: EventRecord) {
        lock.withLock { events.append(event) }
    }
}

/// An event waiting for xrPollEvent, stored as the raw bytes of its XrEventData* struct.
struct EventRecord {
    let bytes: [UInt8]

    init<T>(_ value: T) {
        var copy = value
        bytes = withUnsafeBytes(of: &copy) { Array($0) }
    }
}

final class Session {
    unowned let instance: Instance
    var handle: XrSession?
    let queue: MTLCommandQueue
    var state: XrSessionState = XR_SESSION_STATE_IDLE
    var running = false
    var exitRequested = false
    var attachedSets: [ActionSet] = []
    var interactionProfile: XrPath = 0
    var compositor: Compositor?

    /// LOCAL space origin in tracking space: the head position and heading when the session began.
    var localOrigin = Pose.identity
    var localOriginSet = false
    var lastRecenterCount: UInt32 = 0

    /// Pose the app last asked for views with (tracking space), sent with the frame for reprojection.
    var lastViewHead: qlh_pose?

    var nextFrameTime: XrTime = 0
    var frameBegun = false

    init(instance: Instance, queue: MTLCommandQueue) {
        self.instance = instance
        self.queue = queue
    }

    func setState(_ newState: XrSessionState) {
        state = newState
        var event = XrEventDataSessionStateChanged()
        event.type = XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED
        event.session = handle
        event.state = newState
        event.time = now()
        instance.push(EventRecord(event))
    }

    /// Re-anchors LOCAL to the current head heading (yaw only) when the session starts or the user recenters.
    func updateLocalOrigin(_ tracking: tether_xr_state?) {
        guard let tracking, tracking.streaming == 1 else { return }
        if !localOriginSet || tracking.recenter_count != lastRecenterCount {
            let head = Pose(tracking.head)
            let forward = head.orientation.act(SIMD3<Float>(0, 0, -1))
            let yaw = atan2(-forward.x, -forward.z)
            localOrigin = Pose(orientation: simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)),
                               position: SIMD3(head.position.x, head.position.y, head.position.z))
            localOriginSet = true
            lastRecenterCount = tracking.recenter_count
        }
    }

    /// Pose of a reference space's origin in tracking space.
    func referenceOrigin(_ type: XrReferenceSpaceType, tracking: tether_xr_state?) -> Pose? {
        let floor = tracking?.floor_height ?? 1.6
        switch type {
        case XR_REFERENCE_SPACE_TYPE_VIEW:
            guard let tracking else { return nil }
            return Pose(tracking.head)
        case XR_REFERENCE_SPACE_TYPE_LOCAL:
            return localOrigin
        case XR_REFERENCE_SPACE_TYPE_STAGE, XR_REFERENCE_SPACE_TYPE_LOCAL_FLOOR:
            var origin = localOrigin
            origin.position.y -= floor
            return origin
        default:
            return nil
        }
    }
}

final class Space {
    enum Kind {
        case reference(XrReferenceSpaceType)
        case action(Action, subaction: XrPath)
    }

    unowned let session: Session
    let kind: Kind
    let offset: Pose

    init(session: Session, kind: Kind, offset: Pose) {
        self.session = session
        self.kind = kind
        self.offset = offset
    }

    /// The space's pose in tracking space, and whether it's actively tracked.
    func poseInTracking(_ tracking: tether_xr_state?) -> (Pose, tracked: Bool)? {
        switch kind {
        case .reference(let type):
            guard let origin = session.referenceOrigin(type, tracking: tracking) else { return nil }
            return (origin * offset, type == XR_REFERENCE_SPACE_TYPE_VIEW ? (tracking?.streaming == 1) : true)
        case .action(let action, let subaction):
            guard let tracking, let (controller, aim) = action.poseSource(subaction: subaction, instance: session.instance) else { return nil }
            let state = controller == 0 ? tracking.controllers.0 : tracking.controllers.1
            guard state.pose_valid else { return nil }
            var pose = Pose(state.pose)
            if aim {
                // Quest's aim pose: the grip pose turned up about its X axis (matches Tether's laser).
                pose = pose * Pose(orientation: simd_quatf(angle: 15 * .pi / 180, axis: SIMD3(1, 0, 0)))
            }
            return (pose * offset, tracking.streaming == 1)
        }
    }
}

final class Swapchain {
    unowned let session: Session
    let textures: [MTLTexture]
    let format: MTLPixelFormat
    let arraySize: Int
    var acquired: [Int] = []
    var nextIndex = 0
    var lastReleased: Int?

    init(session: Session, textures: [MTLTexture], format: MTLPixelFormat, arraySize: Int) {
        self.session = session
        self.textures = textures
        self.format = format
        self.arraySize = arraySize
    }
}

/// Swapchain formats in preference order (Metal pixel format raw values).
let supportedSwapchainFormats: [MTLPixelFormat] = [
    .bgra8Unorm_srgb, .rgba8Unorm_srgb, .bgra8Unorm, .rgba8Unorm, .rgba16Float, .rgb10a2Unorm,
    .depth32Float, .depth32Float_stencil8, .depth16Unorm,
]

func isDepthFormat(_ format: MTLPixelFormat) -> Bool {
    format == .depth32Float || format == .depth32Float_stencil8 || format == .depth16Unorm
}
