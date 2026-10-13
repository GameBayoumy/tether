import COpenXR
import CXRSP
import Foundation
import Metal

// A small C API next to OpenXR, for engine plugins that drive the headset themselves (the Unreal plugin):
// read the tracking Tether publishes, and submit a rendered stereo frame. Declared in tether_direct.h.

/// The latest tracking snapshot; false when Tether isn't running or the snapshot is stale.
@_cdecl("tether_direct_read_state")
public func tetherDirectReadState(_ out: UnsafeMutablePointer<tether_xr_state>?) -> Bool {
    guard let out, let state = SharedTracking.shared.snapshot() else { return false }
    out.pointee = state
    return true
}

/// Starts a frame submitter on the engine's command queue (an `id<MTLCommandQueue>`); nil on failure.
@_cdecl("tether_direct_create")
public func tetherDirectCreate(_ queue: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    guard let queue, let commandQueue = Unmanaged<AnyObject>.fromOpaque(queue).takeUnretainedValue() as? MTLCommandQueue
    else { return nil }
    let refresh = SharedTracking.shared.snapshot()?.refresh_hz ?? 72
    do {
        let submitter = DirectSubmitter(queue: commandQueue,
                                        compositor: try Compositor(device: commandQueue.device, refreshHz: refresh > 0 ? refresh : 72))
        return Unmanaged.passRetained(submitter).toOpaque()
    } catch {
        log("Direct submitter failed: \(error)")
        return nil
    }
}

/// Submits one frame: `texture` (an `id<MTLTexture>`, 2D) holds both eyes at the given pixel rects, rendered
/// for `pose` in Tether's tracking space. Call after the frame's rendering is encoded on the same queue.
@_cdecl("tether_direct_submit")
public func tetherDirectSubmit(_ handle: UnsafeMutableRawPointer?, _ texture: UnsafeMutableRawPointer?,
                               _ left: UnsafePointer<Int32>?, _ right: UnsafePointer<Int32>?,
                               _ pose: UnsafePointer<qlh_pose>?) -> Bool {
    guard let handle, let texture, let left, let right, let pose,
          let metalTexture = Unmanaged<AnyObject>.fromOpaque(texture).takeUnretainedValue() as? MTLTexture
    else { return false }
    let submitter = Unmanaged<DirectSubmitter>.fromOpaque(handle).takeUnretainedValue()
    func rect(_ r: UnsafePointer<Int32>) -> XrRect2Di {
        XrRect2Di(offset: XrOffset2Di(x: r[0], y: r[1]), extent: XrExtent2Di(width: r[2], height: r[3]))
    }
    submitter.compositor.submit(views: [Compositor.View(texture: metalTexture, arrayIndex: 0, rect: rect(left)),
                                        Compositor.View(texture: metalTexture, arrayIndex: 0, rect: rect(right))],
                                pose: pose.pointee, queue: submitter.queue)
    return true
}

/// Stops a submitter created by `tether_direct_create`.
@_cdecl("tether_direct_destroy")
public func tetherDirectDestroy(_ handle: UnsafeMutableRawPointer?) {
    guard let handle else { return }
    let submitter = Unmanaged<DirectSubmitter>.fromOpaque(handle).takeRetainedValue()
    submitter.compositor.shutdown()
}

final class DirectSubmitter {
    let queue: MTLCommandQueue
    let compositor: Compositor

    init(queue: MTLCommandQueue, compositor: Compositor) {
        self.queue = queue
        self.compositor = compositor
    }
}
