import COpenXR
import CXRSP
import Foundation
import Metal
import simd

// MARK: - Loader negotiation

@_cdecl("xrNegotiateLoaderRuntimeInterface")
public func xrNegotiateLoaderRuntimeInterface(_ loaderInfo: UnsafePointer<XrNegotiateLoaderInfo>?,
                                              _ request: UnsafeMutablePointer<XrNegotiateRuntimeRequest>?) -> XrResult {
    guard let loaderInfo, let request,
          loaderInfo.pointee.structType == XR_LOADER_INTERFACE_STRUCT_LOADER_INFO,
          request.pointee.structType == XR_LOADER_INTERFACE_STRUCT_RUNTIME_REQUEST else { return XR_ERROR_INITIALIZATION_FAILED }
    let version = UInt32(XR_CURRENT_LOADER_RUNTIME_VERSION)
    guard loaderInfo.pointee.minInterfaceVersion <= version, loaderInfo.pointee.maxInterfaceVersion >= version else {
        return XR_ERROR_INITIALIZATION_FAILED
    }
    request.pointee.runtimeInterfaceVersion = version
    request.pointee.runtimeApiVersion = runtimeAPIVersion
    request.pointee.getInstanceProcAddr = xrGetInstanceProcAddrImpl
    log("Negotiated with loader")
    return XR_SUCCESS
}

private let xrGetInstanceProcAddrImpl: PFN_xrGetInstanceProcAddr = { instance, name, function in
    guard let name, let function else { return XR_ERROR_VALIDATION_FAILURE }
    let key = String(cString: name)
    log("getInstanceProcAddr(\(instance == nil ? "null" : "instance"), \(key)) -> \(functionTable[key] == nil ? "unsupported" : "ok")")
    guard let pointer = functionTable[key] else {
        function.pointee = nil
        return XR_ERROR_FUNCTION_UNSUPPORTED
    }
    let global = ["xrEnumerateInstanceExtensionProperties", "xrEnumerateApiLayerProperties", "xrCreateInstance", "xrGetInstanceProcAddr"]
    if instance == nil && !global.contains(key) {
        function.pointee = nil
        return XR_ERROR_HANDLE_INVALID
    }
    function.pointee = pointer
    return XR_SUCCESS
}

private func fn<T>(_ f: T) -> PFN_xrVoidFunction { unsafeBitCast(f, to: PFN_xrVoidFunction.self) }

private let functionTable: [String: PFN_xrVoidFunction] = [
    "xrGetInstanceProcAddr": fn(xrGetInstanceProcAddrImpl),
    "xrEnumerateApiLayerProperties": fn(enumerateApiLayerProperties),
    "xrEnumerateInstanceExtensionProperties": fn(enumerateInstanceExtensionProperties),
    "xrCreateInstance": fn(createInstance),
    "xrDestroyInstance": fn(destroyInstance),
    "xrGetInstanceProperties": fn(getInstanceProperties),
    "xrPollEvent": fn(pollEvent),
    "xrResultToString": fn(resultToString),
    "xrStructureTypeToString": fn(structureTypeToString),
    "xrGetSystem": fn(getSystem),
    "xrGetSystemProperties": fn(getSystemProperties),
    "xrEnumerateEnvironmentBlendModes": fn(enumerateEnvironmentBlendModes),
    "xrEnumerateViewConfigurations": fn(enumerateViewConfigurations),
    "xrGetViewConfigurationProperties": fn(getViewConfigurationProperties),
    "xrEnumerateViewConfigurationViews": fn(enumerateViewConfigurationViews),
    "xrGetMetalGraphicsRequirementsKHR": fn(getMetalGraphicsRequirements),
    // Unity's OpenXR plugin (1.18) still uses the provisional KHRX2 names; the structs are identical.
    "xrGetMetalGraphicsRequirementsKHRX2": fn(getMetalGraphicsRequirements),
    "xrCreateSession": fn(createSession),
    "xrDestroySession": fn(destroySession),
    "xrBeginSession": fn(beginSession),
    "xrEndSession": fn(endSession),
    "xrRequestExitSession": fn(requestExitSession),
    "xrEnumerateReferenceSpaces": fn(enumerateReferenceSpaces),
    "xrCreateReferenceSpace": fn(createReferenceSpace),
    "xrGetReferenceSpaceBoundsRect": fn(getReferenceSpaceBoundsRect),
    "xrCreateActionSpace": fn(createActionSpace),
    "xrLocateSpace": fn(locateSpace),
    "xrLocateSpaces": fn(locateSpaces),
    "xrLocateSpacesKHR": fn(locateSpaces),
    "xrDestroySpace": fn(destroySpace),
    "xrEnumerateSwapchainFormats": fn(enumerateSwapchainFormats),
    "xrCreateSwapchain": fn(createSwapchain),
    "xrDestroySwapchain": fn(destroySwapchain),
    "xrEnumerateSwapchainImages": fn(enumerateSwapchainImages),
    "xrAcquireSwapchainImage": fn(acquireSwapchainImage),
    "xrWaitSwapchainImage": fn(waitSwapchainImage),
    "xrReleaseSwapchainImage": fn(releaseSwapchainImage),
    "xrWaitFrame": fn(waitFrame),
    "xrBeginFrame": fn(beginFrame),
    "xrEndFrame": fn(endFrame),
    "xrLocateViews": fn(locateViews),
    "xrStringToPath": fn(stringToPath),
    "xrPathToString": fn(pathToString),
    "xrCreateActionSet": fn(createActionSet),
    "xrDestroyActionSet": fn(destroyActionSet),
    "xrCreateAction": fn(createAction),
    "xrDestroyAction": fn(destroyAction),
    "xrSuggestInteractionProfileBindings": fn(suggestInteractionProfileBindings),
    "xrAttachSessionActionSets": fn(attachSessionActionSets),
    "xrGetCurrentInteractionProfile": fn(getCurrentInteractionProfile),
    "xrGetActionStateBoolean": fn(getActionStateBoolean),
    "xrGetActionStateFloat": fn(getActionStateFloat),
    "xrGetActionStateVector2f": fn(getActionStateVector2f),
    "xrGetActionStatePose": fn(getActionStatePose),
    "xrSyncActions": fn(syncActions),
    "xrEnumerateBoundSourcesForAction": fn(enumerateBoundSourcesForAction),
    "xrGetInputSourceLocalizedName": fn(getInputSourceLocalizedName),
    "xrApplyHapticFeedback": fn(applyHapticFeedback),
    "xrStopHapticFeedback": fn(stopHapticFeedback),
]

private let handles = HandleTable.shared

private let supportedExtensions: [(String, UInt32)] = [
    ("XR_KHR_metal_enable", 1),
    ("XR_KHRX2_metal_enable", 1),
    ("XR_KHR_composition_layer_depth", 6),
    ("XR_EXT_local_floor", 1),
    // Only to unlock these controllers' interaction profiles; they map onto Touch.
    ("XR_META_touch_controller_plus", 1),
    ("XR_FB_touch_controller_pro", 1),
]

// MARK: - Instance

private let enumerateApiLayerProperties: PFN_xrEnumerateApiLayerProperties = { _, count, _ in
    count?.pointee = 0
    return XR_SUCCESS
}

private let enumerateInstanceExtensionProperties: PFN_xrEnumerateInstanceExtensionProperties = { layer, capacity, count, properties in
    if layer != nil { return XR_ERROR_API_LAYER_NOT_PRESENT }
    count?.pointee = UInt32(supportedExtensions.count)
    if capacity == 0 { return XR_SUCCESS }
    guard capacity >= supportedExtensions.count, let properties else { return XR_ERROR_SIZE_INSUFFICIENT }
    for (index, (name, version)) in supportedExtensions.enumerated() {
        copyFixedString(name, into: &properties[index].extensionName)
        properties[index].extensionVersion = version
    }
    return XR_SUCCESS
}

private let createInstance: PFN_xrCreateInstance = { info, out in
    guard let info, let out else { return XR_ERROR_VALIDATION_FAILURE }
    let requested = info.pointee.applicationInfo.apiVersion
    let major = requested >> 48, minor = (requested >> 32) & 0xFFFF
    guard major == 1, minor <= 1 else { return XR_ERROR_API_VERSION_UNSUPPORTED }
    for index in 0..<Int(info.pointee.enabledExtensionCount) {
        guard let name = info.pointee.enabledExtensionNames?[index].map({ String(cString: $0) }),
              supportedExtensions.contains(where: { $0.0 == name }) else { return XR_ERROR_EXTENSION_NOT_PRESENT }
    }
    let appName = readFixedString(info.pointee.applicationInfo.applicationName)
    let instance = Instance(apiVersion: requested, applicationName: appName)
    out.pointee = handles.register(instance)
    log("Instance created for \(appName) (API \(major).\(minor))")
    return XR_SUCCESS
}

private let destroyInstance: PFN_xrDestroyInstance = { handle in
    guard let instance = handles.lookup(handle, as: Instance.self) else { return XR_ERROR_HANDLE_INVALID }
    // Destroying an instance destroys every handle created from it.
    if let session = instance.session { destroySessionTree(session) }
    handles.removeAll { ($0 as? ActionSet)?.instance === instance || ($0 as? Action)?.set.instance === instance }
    handles.remove(handle)
    return XR_SUCCESS
}

private let getInstanceProperties: PFN_xrGetInstanceProperties = { handle, properties in
    guard handles.lookup(handle, as: Instance.self) != nil else { return XR_ERROR_HANDLE_INVALID }
    guard let properties else { return XR_ERROR_VALIDATION_FAILURE }
    properties.pointee.runtimeVersion = makeVersion(0, 1, 0)
    copyFixedString("Tether", into: &properties.pointee.runtimeName)
    return XR_SUCCESS
}

private let pollEvent: PFN_xrPollEvent = { handle, buffer in
    guard let instance = handles.lookup(handle, as: Instance.self) else { return XR_ERROR_HANDLE_INVALID }
    guard let buffer else { return XR_ERROR_VALIDATION_FAILURE }
    // Session lifecycle advances here, driven by the app polling.
    if let session = instance.session { advanceSession(session) }
    guard let event = instance.lock.withLock({ instance.events.isEmpty ? nil : instance.events.removeFirst() }) else {
        return XR_EVENT_UNAVAILABLE
    }
    let size = min(event.bytes.count, MemoryLayout<XrEventDataBuffer>.size)
    event.bytes.withUnsafeBytes { UnsafeMutableRawPointer(buffer).copyMemory(from: $0.baseAddress!, byteCount: size) }
    return XR_SUCCESS
}

private let resultToString: PFN_xrResultToString = { _, value, buffer in
    guard let buffer else { return XR_ERROR_VALIDATION_FAILURE }
    let text = value.rawValue >= 0 ? "XR_SUCCESS_\(value.rawValue)" : "XR_ERROR_\(-value.rawValue)"
    let bytes = Array(text.utf8CString.prefix(Int(XR_MAX_RESULT_STRING_SIZE)))
    for (index, byte) in bytes.enumerated() { buffer[index] = byte }
    return XR_SUCCESS
}

private let structureTypeToString: PFN_xrStructureTypeToString = { _, value, buffer in
    guard let buffer else { return XR_ERROR_VALIDATION_FAILURE }
    let bytes = Array("XR_TYPE_\(value.rawValue)".utf8CString.prefix(Int(XR_MAX_STRUCTURE_NAME_SIZE)))
    for (index, byte) in bytes.enumerated() { buffer[index] = byte }
    return XR_SUCCESS
}

// MARK: - System

private let getSystem: PFN_xrGetSystem = { handle, info, systemId in
    guard handles.lookup(handle, as: Instance.self) != nil else { return XR_ERROR_HANDLE_INVALID }
    guard let info, let systemId else { return XR_ERROR_VALIDATION_FAILURE }
    guard info.pointee.formFactor == XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY else { return XR_ERROR_FORM_FACTOR_UNSUPPORTED }
    // Tether must be running with a headset; otherwise the app should keep polling.
    guard SharedTracking.shared.snapshot() != nil else { return XR_ERROR_FORM_FACTOR_UNAVAILABLE }
    systemId.pointee = systemID
    return XR_SUCCESS
}

private let getSystemProperties: PFN_xrGetSystemProperties = { handle, id, properties in
    guard handles.lookup(handle, as: Instance.self) != nil else { return XR_ERROR_HANDLE_INVALID }
    guard id == systemID else { return XR_ERROR_SYSTEM_INVALID }
    guard let properties else { return XR_ERROR_VALIDATION_FAILURE }
    properties.pointee.systemId = systemID
    properties.pointee.vendorId = 0x2833
    copyFixedString("Quest via Tether", into: &properties.pointee.systemName)
    properties.pointee.graphicsProperties.maxSwapchainImageWidth = 4096
    properties.pointee.graphicsProperties.maxSwapchainImageHeight = 4096
    properties.pointee.graphicsProperties.maxLayerCount = 16
    properties.pointee.trackingProperties.orientationTracking = XrBool32(XR_TRUE)
    properties.pointee.trackingProperties.positionTracking = XrBool32(XR_TRUE)
    return XR_SUCCESS
}

private let enumerateEnvironmentBlendModes: PFN_xrEnumerateEnvironmentBlendModes = { handle, _, viewType, capacity, count, modes in
    guard handles.lookup(handle, as: Instance.self) != nil else { return XR_ERROR_HANDLE_INVALID }
    guard viewType == XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO else { return XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED }
    count?.pointee = 1
    if capacity == 0 { return XR_SUCCESS }
    guard let modes else { return XR_ERROR_VALIDATION_FAILURE }
    modes[0] = XR_ENVIRONMENT_BLEND_MODE_OPAQUE
    return XR_SUCCESS
}

private let enumerateViewConfigurations: PFN_xrEnumerateViewConfigurations = { handle, _, capacity, count, types in
    guard handles.lookup(handle, as: Instance.self) != nil else { return XR_ERROR_HANDLE_INVALID }
    count?.pointee = 1
    if capacity == 0 { return XR_SUCCESS }
    guard let types else { return XR_ERROR_VALIDATION_FAILURE }
    types[0] = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO
    return XR_SUCCESS
}

private let getViewConfigurationProperties: PFN_xrGetViewConfigurationProperties = { handle, _, viewType, properties in
    guard handles.lookup(handle, as: Instance.self) != nil else { return XR_ERROR_HANDLE_INVALID }
    guard viewType == XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO else { return XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED }
    properties?.pointee.viewConfigurationType = viewType
    properties?.pointee.fovMutable = XrBool32(XR_FALSE)
    return XR_SUCCESS
}

private let enumerateViewConfigurationViews: PFN_xrEnumerateViewConfigurationViews = { handle, _, viewType, capacity, count, views in
    guard handles.lookup(handle, as: Instance.self) != nil else { return XR_ERROR_HANDLE_INVALID }
    guard viewType == XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO else { return XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED }
    count?.pointee = 2
    if capacity == 0 { return XR_SUCCESS }
    guard capacity >= 2, let views else { return XR_ERROR_SIZE_INSUFFICIENT }
    let state = SharedTracking.shared.snapshot()
    let width = state.map { $0.eye_width } ?? 1808
    let height = state.map { $0.eye_height } ?? 1920
    for index in 0..<2 {
        views[index].recommendedImageRectWidth = width > 0 ? width : 1808
        views[index].recommendedImageRectHeight = height > 0 ? height : 1920
        views[index].maxImageRectWidth = 4096
        views[index].maxImageRectHeight = 4096
        views[index].recommendedSwapchainSampleCount = 1
        views[index].maxSwapchainSampleCount = 4
    }
    return XR_SUCCESS
}

private let getMetalGraphicsRequirements: PFN_xrGetMetalGraphicsRequirementsKHR = { handle, _, requirements in
    guard handles.lookup(handle, as: Instance.self) != nil else { return XR_ERROR_HANDLE_INVALID }
    guard let requirements, let device = MTLCreateSystemDefaultDevice() else { return XR_ERROR_VALIDATION_FAILURE }
    requirements.pointee.metalDevice = Unmanaged.passUnretained(device as AnyObject).toOpaque()
    return XR_SUCCESS
}

// MARK: - Session

private let createSession: PFN_xrCreateSession = { handle, info, out in
    guard let instance = handles.lookup(handle, as: Instance.self) else { return XR_ERROR_HANDLE_INVALID }
    guard let info, let out else { return XR_ERROR_VALIDATION_FAILURE }
    guard info.pointee.systemId == systemID else { return XR_ERROR_SYSTEM_INVALID }
    guard instance.session == nil else { return XR_ERROR_LIMIT_REACHED }
    guard let binding = findInChain(info.pointee.next, type: XR_TYPE_GRAPHICS_BINDING_METAL_KHR)?
        .assumingMemoryBound(to: XrGraphicsBindingMetalKHR.self),
          let queuePointer = binding.pointee.commandQueue else { return XR_ERROR_GRAPHICS_DEVICE_INVALID }
    guard let queue = Unmanaged<AnyObject>.fromOpaque(queuePointer).takeUnretainedValue() as? MTLCommandQueue else {
        return XR_ERROR_GRAPHICS_DEVICE_INVALID
    }
    let session = Session(instance: instance, queue: queue)
    let sessionHandle = handles.register(session)
    session.handle = sessionHandle
    instance.session = session
    session.setState(XR_SESSION_STATE_IDLE)
    session.setState(XR_SESSION_STATE_READY)
    out.pointee = sessionHandle
    log("Session created")
    return XR_SUCCESS
}

/// Shuts a session down and destroys it together with its spaces and swapchains.
private func destroySessionTree(_ session: Session) {
    session.compositor?.shutdown()
    session.compositor = nil
    session.instance.session = nil
    handles.removeAll { ($0 as? Space)?.session === session || ($0 as? Swapchain)?.session === session }
    handles.remove(session.handle)
}

private let destroySession: PFN_xrDestroySession = { handle in
    guard let session = handles.lookup(handle, as: Session.self) else { return XR_ERROR_HANDLE_INVALID }
    destroySessionTree(session)
    return XR_SUCCESS
}

private let beginSession: PFN_xrBeginSession = { handle, info in
    guard let session = handles.lookup(handle, as: Session.self) else { return XR_ERROR_HANDLE_INVALID }
    guard info?.pointee.primaryViewConfigurationType == XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO else {
        return XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED
    }
    guard !session.running else { return XR_ERROR_SESSION_RUNNING }
    let tracking = SharedTracking.shared.snapshot()
    do {
        session.compositor = try Compositor(device: session.queue.device, refreshHz: tracking?.refresh_hz ?? 72)
    } catch {
        log("Compositor failed: \(error)")
        return XR_ERROR_RUNTIME_FAILURE
    }
    session.running = true
    session.updateLocalOrigin(tracking)
    session.setState(XR_SESSION_STATE_SYNCHRONIZED)
    session.setState(XR_SESSION_STATE_VISIBLE)
    session.setState(XR_SESSION_STATE_FOCUSED)
    log("Session began")
    return XR_SUCCESS
}

private let endSession: PFN_xrEndSession = { handle in
    guard let session = handles.lookup(handle, as: Session.self) else { return XR_ERROR_HANDLE_INVALID }
    guard session.running else { return XR_ERROR_SESSION_NOT_RUNNING }
    session.running = false
    session.compositor?.shutdown()
    session.compositor = nil
    session.setState(XR_SESSION_STATE_IDLE)
    if session.exitRequested { session.setState(XR_SESSION_STATE_EXITING) }
    return XR_SUCCESS
}

private let requestExitSession: PFN_xrRequestExitSession = { handle in
    guard let session = handles.lookup(handle, as: Session.self) else { return XR_ERROR_HANDLE_INVALID }
    guard session.running else { return XR_ERROR_SESSION_NOT_RUNNING }
    session.exitRequested = true
    session.setState(XR_SESSION_STATE_STOPPING)
    return XR_SUCCESS
}

/// Reflects whether the headset is streaming: an app loses focus while Link isn't running.
private func advanceSession(_ session: Session) {
    guard session.running, !session.exitRequested else { return }
    let streaming = SharedTracking.shared.snapshot()?.streaming == 1
    if streaming && session.state == XR_SESSION_STATE_VISIBLE {
        session.setState(XR_SESSION_STATE_FOCUSED)
    } else if !streaming && session.state == XR_SESSION_STATE_FOCUSED {
        session.setState(XR_SESSION_STATE_VISIBLE)
    }
}

// MARK: - Spaces

private let referenceSpaceTypes: [XrReferenceSpaceType] = [
    XR_REFERENCE_SPACE_TYPE_VIEW, XR_REFERENCE_SPACE_TYPE_LOCAL, XR_REFERENCE_SPACE_TYPE_STAGE, XR_REFERENCE_SPACE_TYPE_LOCAL_FLOOR,
]

private let enumerateReferenceSpaces: PFN_xrEnumerateReferenceSpaces = { handle, capacity, count, spaces in
    guard handles.lookup(handle, as: Session.self) != nil else { return XR_ERROR_HANDLE_INVALID }
    count?.pointee = UInt32(referenceSpaceTypes.count)
    if capacity == 0 { return XR_SUCCESS }
    guard capacity >= referenceSpaceTypes.count, let spaces else { return XR_ERROR_SIZE_INSUFFICIENT }
    for (index, type) in referenceSpaceTypes.enumerated() { spaces[index] = type }
    return XR_SUCCESS
}

private let createReferenceSpace: PFN_xrCreateReferenceSpace = { handle, info, out in
    guard let session = handles.lookup(handle, as: Session.self) else { return XR_ERROR_HANDLE_INVALID }
    guard let info, let out else { return XR_ERROR_VALIDATION_FAILURE }
    guard referenceSpaceTypes.contains(info.pointee.referenceSpaceType) else { return XR_ERROR_REFERENCE_SPACE_UNSUPPORTED }
    let space = Space(session: session, kind: .reference(info.pointee.referenceSpaceType), offset: Pose(info.pointee.poseInReferenceSpace))
    out.pointee = handles.register(space)
    return XR_SUCCESS
}

private let getReferenceSpaceBoundsRect: PFN_xrGetReferenceSpaceBoundsRect = { handle, _, bounds in
    guard handles.lookup(handle, as: Session.self) != nil else { return XR_ERROR_HANDLE_INVALID }
    bounds?.pointee = XrExtent2Df(width: 0, height: 0)
    return XR_SPACE_BOUNDS_UNAVAILABLE
}

private let createActionSpace: PFN_xrCreateActionSpace = { handle, info, out in
    guard let session = handles.lookup(handle, as: Session.self) else { return XR_ERROR_HANDLE_INVALID }
    guard let info, let out, let action = handles.lookup(info.pointee.action, as: Action.self) else { return XR_ERROR_HANDLE_INVALID }
    guard action.type == XR_ACTION_TYPE_POSE_INPUT else { return XR_ERROR_ACTION_TYPE_MISMATCH }
    let space = Space(session: session, kind: .action(action, subaction: info.pointee.subactionPath),
                      offset: Pose(info.pointee.poseInActionSpace))
    out.pointee = handles.register(space)
    return XR_SUCCESS
}

private func locate(_ space: Space, in base: Space, tracking: tether_xr_state?) -> (XrPosef, XrSpaceLocationFlags) {
    guard let (spacePose, spaceTracked) = space.poseInTracking(tracking),
          let (basePose, baseTracked) = base.poseInTracking(tracking) else { return (Pose.identity.xr, 0) }
    let relative = basePose.inverse * spacePose
    var flags = XrSpaceLocationFlags(XR_SPACE_LOCATION_ORIENTATION_VALID_BIT | XR_SPACE_LOCATION_POSITION_VALID_BIT)
    if spaceTracked && baseTracked {
        flags |= XrSpaceLocationFlags(XR_SPACE_LOCATION_ORIENTATION_TRACKED_BIT | XR_SPACE_LOCATION_POSITION_TRACKED_BIT)
    }
    return (relative.xr, flags)
}

private let locateSpace: PFN_xrLocateSpace = { spaceHandle, baseHandle, _, location in
    guard let space = handles.lookup(spaceHandle, as: Space.self), let base = handles.lookup(baseHandle, as: Space.self) else {
        return XR_ERROR_HANDLE_INVALID
    }
    guard let location else { return XR_ERROR_VALIDATION_FAILURE }
    let tracking = SharedTracking.shared.snapshot()
    space.session.updateLocalOrigin(tracking)
    let (pose, flags) = locate(space, in: base, tracking: tracking)
    location.pointee.pose = pose
    location.pointee.locationFlags = flags
    return XR_SUCCESS
}

private let locateSpaces: PFN_xrLocateSpaces = { sessionHandle, info, locations in
    guard handles.lookup(sessionHandle, as: Session.self) != nil else { return XR_ERROR_HANDLE_INVALID }
    guard let info, let locations, let base = handles.lookup(info.pointee.baseSpace, as: Space.self) else {
        return XR_ERROR_VALIDATION_FAILURE
    }
    let tracking = SharedTracking.shared.snapshot()
    for index in 0..<Int(info.pointee.spaceCount) {
        guard let handle = info.pointee.spaces?[index], let space = handles.lookup(handle, as: Space.self),
              let output = locations.pointee.locations?.advanced(by: index) else { continue }
        let (pose, flags) = locate(space, in: base, tracking: tracking)
        output.pointee.pose = pose
        output.pointee.locationFlags = flags
    }
    return XR_SUCCESS
}

private let destroySpace: PFN_xrDestroySpace = { handle in
    guard handles.lookup(handle, as: Space.self) != nil else { return XR_ERROR_HANDLE_INVALID }
    handles.remove(handle)
    return XR_SUCCESS
}

// MARK: - Swapchains

private let enumerateSwapchainFormats: PFN_xrEnumerateSwapchainFormats = { handle, capacity, count, formats in
    guard handles.lookup(handle, as: Session.self) != nil else { return XR_ERROR_HANDLE_INVALID }
    count?.pointee = UInt32(supportedSwapchainFormats.count)
    if capacity == 0 { return XR_SUCCESS }
    guard capacity >= supportedSwapchainFormats.count, let formats else { return XR_ERROR_SIZE_INSUFFICIENT }
    for (index, format) in supportedSwapchainFormats.enumerated() { formats[index] = Int64(format.rawValue) }
    return XR_SUCCESS
}

private let createSwapchain: PFN_xrCreateSwapchain = { handle, info, out in
    guard let session = handles.lookup(handle, as: Session.self) else { return XR_ERROR_HANDLE_INVALID }
    guard let info, let out else { return XR_ERROR_VALIDATION_FAILURE }
    guard let format = MTLPixelFormat(rawValue: UInt(info.pointee.format)), supportedSwapchainFormats.contains(format) else {
        return XR_ERROR_SWAPCHAIN_FORMAT_UNSUPPORTED
    }
    let device = session.queue.device
    let arraySize = max(1, Int(info.pointee.arraySize))
    let samples = max(1, Int(info.pointee.sampleCount))
    let descriptor = MTLTextureDescriptor()
    descriptor.pixelFormat = format
    descriptor.width = Int(info.pointee.width)
    descriptor.height = Int(info.pointee.height)
    descriptor.mipmapLevelCount = max(1, Int(info.pointee.mipCount))
    descriptor.sampleCount = samples
    descriptor.arrayLength = arraySize
    descriptor.textureType = samples > 1 ? (arraySize > 1 ? .type2DMultisampleArray : .type2DMultisample)
                                         : (arraySize > 1 ? .type2DArray : .type2D)
    descriptor.storageMode = .private
    descriptor.usage = [.renderTarget, .shaderRead, .pixelFormatView]
    if info.pointee.usageFlags & XrSwapchainUsageFlags(XR_SWAPCHAIN_USAGE_UNORDERED_ACCESS_BIT) != 0 && !isDepthFormat(format) {
        descriptor.usage.insert(.shaderWrite)
    }
    var textures: [MTLTexture] = []
    for _ in 0..<3 {
        guard let texture = device.makeTexture(descriptor: descriptor) else { return XR_ERROR_OUT_OF_MEMORY }
        textures.append(texture)
    }
    let swapchain = Swapchain(session: session, textures: textures, format: format, arraySize: arraySize)
    out.pointee = handles.register(swapchain)
    log("Swapchain \(descriptor.width)x\(descriptor.height) x\(arraySize) format \(format.rawValue) samples \(samples)")
    return XR_SUCCESS
}

private let destroySwapchain: PFN_xrDestroySwapchain = { handle in
    guard handles.lookup(handle, as: Swapchain.self) != nil else { return XR_ERROR_HANDLE_INVALID }
    handles.remove(handle)
    return XR_SUCCESS
}

private let enumerateSwapchainImages: PFN_xrEnumerateSwapchainImages = { handle, capacity, count, images in
    guard let swapchain = handles.lookup(handle, as: Swapchain.self) else { return XR_ERROR_HANDLE_INVALID }
    count?.pointee = UInt32(swapchain.textures.count)
    if capacity == 0 { return XR_SUCCESS }
    guard capacity >= swapchain.textures.count, let images else { return XR_ERROR_SIZE_INSUFFICIENT }
    let metal = UnsafeMutableRawPointer(images).assumingMemoryBound(to: XrSwapchainImageMetalKHR.self)
    for (index, texture) in swapchain.textures.enumerated() {
        guard metal[index].type == XR_TYPE_SWAPCHAIN_IMAGE_METAL_KHR else { return XR_ERROR_VALIDATION_FAILURE }
        metal[index].texture = Unmanaged.passUnretained(texture as AnyObject).toOpaque()
    }
    return XR_SUCCESS
}

private let acquireSwapchainImage: PFN_xrAcquireSwapchainImage = { handle, _, index in
    guard let swapchain = handles.lookup(handle, as: Swapchain.self) else { return XR_ERROR_HANDLE_INVALID }
    guard swapchain.acquired.count < swapchain.textures.count else { return XR_ERROR_CALL_ORDER_INVALID }
    let next = swapchain.nextIndex
    swapchain.nextIndex = (next + 1) % swapchain.textures.count
    swapchain.acquired.append(next)
    index?.pointee = UInt32(next)
    return XR_SUCCESS
}

private let waitSwapchainImage: PFN_xrWaitSwapchainImage = { handle, _ in
    handles.lookup(handle, as: Swapchain.self) != nil ? XR_SUCCESS : XR_ERROR_HANDLE_INVALID
}

private let releaseSwapchainImage: PFN_xrReleaseSwapchainImage = { handle, _ in
    guard let swapchain = handles.lookup(handle, as: Swapchain.self) else { return XR_ERROR_HANDLE_INVALID }
    guard !swapchain.acquired.isEmpty else { return XR_ERROR_CALL_ORDER_INVALID }
    swapchain.lastReleased = swapchain.acquired.removeFirst()
    return XR_SUCCESS
}

// MARK: - Frames

private let waitFrame: PFN_xrWaitFrame = { handle, _, frameState in
    guard let session = handles.lookup(handle, as: Session.self) else { return XR_ERROR_HANDLE_INVALID }
    guard session.running else { return XR_ERROR_SESSION_NOT_RUNNING }
    guard let frameState else { return XR_ERROR_VALIDATION_FAILURE }
    let tracking = SharedTracking.shared.snapshot()
    let hz = Double(tracking?.refresh_hz ?? 72)
    let period = XrTime(1_000_000_000 / (hz > 0 ? hz : 72))
    // Pace the app to the headset's refresh rate.
    var current = now()
    if session.nextFrameTime > current {
        let wait = session.nextFrameTime - current
        var request = timespec(tv_sec: Int(wait / 1_000_000_000), tv_nsec: Int(wait % 1_000_000_000))
        nanosleep(&request, nil)
        current = now()
    }
    session.nextFrameTime = max(session.nextFrameTime, current) + period
    frameState.pointee.predictedDisplayTime = current + 2 * period
    frameState.pointee.predictedDisplayPeriod = XrDuration(period)
    frameState.pointee.shouldRender = XrBool32(session.state == XR_SESSION_STATE_VISIBLE || session.state == XR_SESSION_STATE_FOCUSED ? XR_TRUE : XR_FALSE)
    return XR_SUCCESS
}

private let beginFrame: PFN_xrBeginFrame = { handle, _ in
    guard let session = handles.lookup(handle, as: Session.self) else { return XR_ERROR_HANDLE_INVALID }
    guard session.running else { return XR_ERROR_SESSION_NOT_RUNNING }
    let discarded = session.frameBegun
    session.frameBegun = true
    return discarded ? XR_FRAME_DISCARDED : XR_SUCCESS
}

private let endFrame: PFN_xrEndFrame = { handle, info in
    guard let session = handles.lookup(handle, as: Session.self) else { return XR_ERROR_HANDLE_INVALID }
    guard session.running else { return XR_ERROR_SESSION_NOT_RUNNING }
    guard session.frameBegun else { return XR_ERROR_CALL_ORDER_INVALID }
    session.frameBegun = false
    guard let info else { return XR_ERROR_VALIDATION_FAILURE }

    // Use the first stereo projection layer; other layer types are ignored for now.
    for index in 0..<Int(info.pointee.layerCount) {
        guard let layerPointer = info.pointee.layers?[index] else { continue }
        let base = UnsafeRawPointer(layerPointer).assumingMemoryBound(to: XrCompositionLayerBaseHeader.self)
        guard base.pointee.type == XR_TYPE_COMPOSITION_LAYER_PROJECTION else { continue }
        let layer = UnsafeRawPointer(layerPointer).assumingMemoryBound(to: XrCompositionLayerProjection.self)
        guard layer.pointee.viewCount == 2, let projectionViews = layer.pointee.views else { continue }
        var views: [Compositor.View] = []
        for eye in 0..<2 {
            let view = projectionViews[eye]
            guard let swapchain = handles.lookup(view.subImage.swapchain, as: Swapchain.self),
                  let image = swapchain.lastReleased else { break }
            views.append(Compositor.View(texture: swapchain.textures[image], arrayIndex: Int(view.subImage.imageArrayIndex),
                                         rect: view.subImage.imageRect))
        }
        guard views.count == 2 else { break }

        // The head pose these views were rendered for, in tracking space, for reprojection on the headset.
        var pose = session.lastViewHead ?? qlh_pose()
        if let layerSpace = handles.lookup(layer.pointee.space, as: Space.self),
           let (spacePose, _) = layerSpace.poseInTracking(SharedTracking.shared.snapshot()) {
            let left = spacePose * Pose(projectionViews[0].pose)
            let right = spacePose * Pose(projectionViews[1].pose)
            let head = Pose(orientation: left.orientation, position: (left.position + right.position) / 2)
            pose.orientation = (head.orientation.imag.x, head.orientation.imag.y, head.orientation.imag.z, head.orientation.real)
            pose.position = (head.position.x, head.position.y, head.position.z)
        }
        session.compositor?.submit(views: views, pose: pose, queue: session.queue)
        break
    }
    return XR_SUCCESS
}

private let locateViews: PFN_xrLocateViews = { handle, info, viewState, capacity, count, views in
    guard let session = handles.lookup(handle, as: Session.self) else { return XR_ERROR_HANDLE_INVALID }
    guard let info, let viewState else { return XR_ERROR_VALIDATION_FAILURE }
    guard info.pointee.viewConfigurationType == XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO else {
        return XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED
    }
    count?.pointee = 2
    if capacity == 0 { return XR_SUCCESS }
    guard capacity >= 2, let views else { return XR_ERROR_SIZE_INSUFFICIENT }
    guard let space = handles.lookup(info.pointee.space, as: Space.self) else { return XR_ERROR_HANDLE_INVALID }

    let tracking = SharedTracking.shared.snapshot()
    session.updateLocalOrigin(tracking)
    let ipd = tracking.map { $0.ipd > 0 ? $0.ipd : 0.063 } ?? 0.063
    let head = tracking.map { Pose($0.head) } ?? Pose.identity
    let base = space.poseInTracking(tracking)?.0 ?? Pose.identity
    let tangents: [(Float, Float, Float, Float)] = tracking.map { [$0.fov_tangents.0, $0.fov_tangents.1] }
        ?? [(1.376, 0.839, 0.966, 1.428), (0.839, 1.376, 0.966, 1.428)]
    for eye in 0..<2 {
        let offset = Pose(position: SIMD3(eye == 0 ? -ipd / 2 : ipd / 2, 0, 0))
        views[eye].pose = (base.inverse * head * offset).xr
        let t = tangents[eye] // left, right, up, down
        views[eye].fov = XrFovf(angleLeft: -atan(t.0), angleRight: atan(t.1), angleUp: atan(t.2), angleDown: -atan(t.3))
    }
    let live = tracking?.streaming == 1
    viewState.pointee.viewStateFlags = live
        ? XrViewStateFlags(XR_VIEW_STATE_ORIENTATION_VALID_BIT | XR_VIEW_STATE_POSITION_VALID_BIT |
                           XR_VIEW_STATE_ORIENTATION_TRACKED_BIT | XR_VIEW_STATE_POSITION_TRACKED_BIT)
        : 0
    if let tracking { session.lastViewHead = tracking.head }
    return XR_SUCCESS
}

// MARK: - Paths and actions

private let stringToPath: PFN_xrStringToPath = { handle, string, path in
    guard let instance = handles.lookup(handle, as: Instance.self) else { return XR_ERROR_HANDLE_INVALID }
    guard let string, let path else { return XR_ERROR_VALIDATION_FAILURE }
    let value = String(cString: string)
    guard value.hasPrefix("/"), !value.hasSuffix("/") || value == "/" else { return XR_ERROR_PATH_FORMAT_INVALID }
    path.pointee = instance.paths.path(value)
    return XR_SUCCESS
}

private let pathToString: PFN_xrPathToString = { handle, path, capacity, count, buffer in
    guard let instance = handles.lookup(handle, as: Instance.self) else { return XR_ERROR_HANDLE_INVALID }
    guard let string = instance.paths.string(path) else { return XR_ERROR_PATH_INVALID }
    return writeString(string, capacity: capacity, count: count, buffer: buffer)
}

private let createActionSet: PFN_xrCreateActionSet = { handle, info, out in
    guard let instance = handles.lookup(handle, as: Instance.self) else { return XR_ERROR_HANDLE_INVALID }
    guard let info, let out else { return XR_ERROR_VALIDATION_FAILURE }
    out.pointee = handles.register(ActionSet(instance: instance, name: readFixedString(info.pointee.actionSetName)))
    return XR_SUCCESS
}

private let destroyActionSet: PFN_xrDestroyActionSet = { handle in
    guard let set = handles.lookup(handle, as: ActionSet.self) else { return XR_ERROR_HANDLE_INVALID }
    // Its actions go with it; an attached set keeps working for the session through attachedSets.
    handles.removeAll { ($0 as? Action)?.set === set }
    handles.remove(handle)
    return XR_SUCCESS
}

private let createAction: PFN_xrCreateAction = { handle, info, out in
    guard let set = handles.lookup(handle, as: ActionSet.self) else { return XR_ERROR_HANDLE_INVALID }
    guard let info, let out else { return XR_ERROR_VALIDATION_FAILURE }
    guard !set.attached else { return XR_ERROR_ACTIONSETS_ALREADY_ATTACHED }
    let subactions = (0..<Int(info.pointee.countSubactionPaths)).compactMap { info.pointee.subactionPaths?[$0] }
    let action = Action(set: set, name: readFixedString(info.pointee.actionName), type: info.pointee.actionType, subactionPaths: subactions)
    set.actions.append(action)
    out.pointee = handles.register(action)
    return XR_SUCCESS
}

private let destroyAction: PFN_xrDestroyAction = { handle in
    guard handles.lookup(handle, as: Action.self) != nil else { return XR_ERROR_HANDLE_INVALID }
    handles.remove(handle)
    return XR_SUCCESS
}

private let suggestInteractionProfileBindings: PFN_xrSuggestInteractionProfileBindings = { handle, info in
    guard let instance = handles.lookup(handle, as: Instance.self) else { return XR_ERROR_HANDLE_INVALID }
    guard let info else { return XR_ERROR_VALIDATION_FAILURE }
    var bindings: [(action: Action, binding: XrPath)] = []
    for index in 0..<Int(info.pointee.countSuggestedBindings) {
        guard let suggestion = info.pointee.suggestedBindings?[index],
              let action = handles.lookup(suggestion.action, as: Action.self) else { return XR_ERROR_HANDLE_INVALID }
        bindings.append((action, suggestion.binding))
    }
    instance.suggested[info.pointee.interactionProfile] = bindings
    return XR_SUCCESS
}

private let attachSessionActionSets: PFN_xrAttachSessionActionSets = { handle, info in
    guard let session = handles.lookup(handle, as: Session.self) else { return XR_ERROR_HANDLE_INVALID }
    guard let info else { return XR_ERROR_VALIDATION_FAILURE }
    guard session.attachedSets.isEmpty else { return XR_ERROR_ACTIONSETS_ALREADY_ATTACHED }
    for index in 0..<Int(info.pointee.countActionSets) {
        guard let set = handles.lookup(info.pointee.actionSets?[index], as: ActionSet.self) else { return XR_ERROR_HANDLE_INVALID }
        set.attached = true
        session.attachedSets.append(set)
    }
    session.resolveBindings()
    return XR_SUCCESS
}

private let getCurrentInteractionProfile: PFN_xrGetCurrentInteractionProfile = { handle, topLevel, profile in
    guard let session = handles.lookup(handle, as: Session.self) else { return XR_ERROR_HANDLE_INVALID }
    guard !session.attachedSets.isEmpty else { return XR_ERROR_ACTIONSET_NOT_ATTACHED }
    profile?.pointee.interactionProfile = handIndex(topLevel, instance: session.instance) != nil ? session.interactionProfile : 0
    return XR_SUCCESS
}

private func actionState(_ session: Session, _ info: UnsafePointer<XrActionStateGetInfo>?, type: XrActionType)
    -> (Action, (bool: Bool, float: Float, vector: SIMD2<Float>, active: Bool), changed: Bool, time: XrTime)? {
    guard let info, let action = handles.lookup(info.pointee.action, as: Action.self), action.type == type else { return nil }
    let key = info.pointee.subactionPath
    let value = action.current[key] ?? (false, 0, .zero, false)
    return (action, value, action.changed[key] ?? false, action.lastChange[key] ?? 0)
}

private let getActionStateBoolean: PFN_xrGetActionStateBoolean = { handle, info, state in
    guard let session = handles.lookup(handle, as: Session.self) else { return XR_ERROR_HANDLE_INVALID }
    guard let result = actionState(session, info, type: XR_ACTION_TYPE_BOOLEAN_INPUT), let state else { return XR_ERROR_ACTION_TYPE_MISMATCH }
    state.pointee.currentState = XrBool32(result.1.bool ? XR_TRUE : XR_FALSE)
    state.pointee.changedSinceLastSync = XrBool32(result.changed ? XR_TRUE : XR_FALSE)
    state.pointee.lastChangeTime = result.time
    state.pointee.isActive = XrBool32(result.1.active ? XR_TRUE : XR_FALSE)
    return XR_SUCCESS
}

private let getActionStateFloat: PFN_xrGetActionStateFloat = { handle, info, state in
    guard let session = handles.lookup(handle, as: Session.self) else { return XR_ERROR_HANDLE_INVALID }
    guard let result = actionState(session, info, type: XR_ACTION_TYPE_FLOAT_INPUT), let state else { return XR_ERROR_ACTION_TYPE_MISMATCH }
    state.pointee.currentState = result.1.float
    state.pointee.changedSinceLastSync = XrBool32(result.changed ? XR_TRUE : XR_FALSE)
    state.pointee.lastChangeTime = result.time
    state.pointee.isActive = XrBool32(result.1.active ? XR_TRUE : XR_FALSE)
    return XR_SUCCESS
}

private let getActionStateVector2f: PFN_xrGetActionStateVector2f = { handle, info, state in
    guard let session = handles.lookup(handle, as: Session.self) else { return XR_ERROR_HANDLE_INVALID }
    guard let result = actionState(session, info, type: XR_ACTION_TYPE_VECTOR2F_INPUT), let state else { return XR_ERROR_ACTION_TYPE_MISMATCH }
    state.pointee.currentState = XrVector2f(x: result.1.vector.x, y: result.1.vector.y)
    state.pointee.changedSinceLastSync = XrBool32(result.changed ? XR_TRUE : XR_FALSE)
    state.pointee.lastChangeTime = result.time
    state.pointee.isActive = XrBool32(result.1.active ? XR_TRUE : XR_FALSE)
    return XR_SUCCESS
}

private let getActionStatePose: PFN_xrGetActionStatePose = { handle, info, state in
    guard let session = handles.lookup(handle, as: Session.self) else { return XR_ERROR_HANDLE_INVALID }
    guard let info, let state, let action = handles.lookup(info.pointee.action, as: Action.self) else { return XR_ERROR_HANDLE_INVALID }
    guard action.type == XR_ACTION_TYPE_POSE_INPUT else { return XR_ERROR_ACTION_TYPE_MISMATCH }
    let tracking = SharedTracking.shared.snapshot()
    var active = false
    if let tracking, tracking.streaming == 1, let (hand, _) = action.poseSource(subaction: info.pointee.subactionPath, instance: session.instance) {
        active = (hand == 0 ? tracking.controllers.0 : tracking.controllers.1).pose_valid
    }
    state.pointee.isActive = XrBool32(active ? XR_TRUE : XR_FALSE)
    return XR_SUCCESS
}

private let syncActions: PFN_xrSyncActions = { handle, _ in
    guard let session = handles.lookup(handle, as: Session.self) else { return XR_ERROR_HANDLE_INVALID }
    guard !session.attachedSets.isEmpty else { return XR_ERROR_ACTIONSET_NOT_ATTACHED }
    // Unfocused, every action reads inactive (so nothing stays held while Link is down).
    guard session.state == XR_SESSION_STATE_FOCUSED else {
        session.syncActions(nil)
        return XR_SESSION_NOT_FOCUSED
    }
    session.syncActions(SharedTracking.shared.snapshot())
    return XR_SUCCESS
}

private let enumerateBoundSourcesForAction: PFN_xrEnumerateBoundSourcesForAction = { handle, info, capacity, count, sources in
    guard handles.lookup(handle, as: Session.self) != nil else { return XR_ERROR_HANDLE_INVALID }
    guard let info, let action = handles.lookup(info.pointee.action, as: Action.self) else { return XR_ERROR_HANDLE_INVALID }
    count?.pointee = UInt32(action.boundPaths.count)
    if capacity == 0 { return XR_SUCCESS }
    guard capacity >= action.boundPaths.count, let sources else { return XR_ERROR_SIZE_INSUFFICIENT }
    for (index, path) in action.boundPaths.enumerated() { sources[index] = path }
    return XR_SUCCESS
}

private let getInputSourceLocalizedName: PFN_xrGetInputSourceLocalizedName = { handle, info, capacity, count, buffer in
    guard let session = handles.lookup(handle, as: Session.self) else { return XR_ERROR_HANDLE_INVALID }
    guard let info else { return XR_ERROR_VALIDATION_FAILURE }
    let name = session.instance.paths.string(info.pointee.sourcePath) ?? "Touch controller"
    return writeString(name, capacity: capacity, count: count, buffer: buffer)
}

private let applyHapticFeedback: PFN_xrApplyHapticFeedback = { handle, _, _ in
    handles.lookup(handle, as: Session.self) != nil ? XR_SUCCESS : XR_ERROR_HANDLE_INVALID
}

private let stopHapticFeedback: PFN_xrStopHapticFeedback = { handle, _ in
    handles.lookup(handle, as: Session.self) != nil ? XR_SUCCESS : XR_ERROR_HANDLE_INVALID
}
