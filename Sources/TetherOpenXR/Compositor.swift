import COpenXR
import CoreVideo
import CXRSP
import Foundation
import Metal
import TetherCore

/// Composites the app's two projection views into the headset's side-by-side frame, encodes it into
/// five H.264 slices, and hands it to the Tether app over its Unix socket.
final class Compositor: @unchecked Sendable {
    static let frameWidth = Int(QLH_FRAME_WIDTH)
    static let frameHeight = Int(QLH_FRAME_HEIGHT)
    static let sliceHeight = Int(QLH_SLICE_HEIGHT)
    static let sliceCount = Int(QLH_SLICE_COUNT)

    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let frameTexture: MTLTexture
    private var textureCache: CVMetalTextureCache!
    private var slicePool: CVPixelBufferPool!
    private let encoder: SliceEncoder
    private let sender = FrameSender()

    private let lock = NSLock()
    private var inFlight = 0
    private var frameID: UInt32 = 0
    private var lastKeyframe = Date.distantPast
    private var needsKeyframe = true

    struct View {
        let texture: MTLTexture
        let arrayIndex: Int
        let rect: XrRect2Di
    }

    init(device: MTLDevice, refreshHz: Float) throws {
        self.device = device
        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "eye_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "eye_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let frame = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Self.frameWidth,
                                                             height: Self.frameHeight, mipmapped: false)
        frame.usage = [.renderTarget, .shaderRead]
        frame.storageMode = .private
        guard let frameTexture = device.makeTexture(descriptor: frame) else {
            throw NSError(domain: "Tether", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't allocate the frame texture"])
        }
        self.frameTexture = frameTexture

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: Self.frameWidth,
            kCVPixelBufferHeightKey: Self.sliceHeight,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey: 15] as CFDictionary,
                                attributes as CFDictionary, &slicePool)

        encoder = try SliceEncoder(width: Self.frameWidth, height: Self.sliceHeight, count: Self.sliceCount,
                                   fps: Int(refreshHz.rounded()), bitRatePerSlice: 32_000_000)
        encoder.onFrame = { [weak self] frame in
            guard let self else { return }
            self.sender.send(frame)
            self.lock.withLock { self.inFlight -= 1 }
        }
        encoder.onFailure = { [weak self] _ in
            guard let self else { return }
            self.lock.withLock {
                self.inFlight -= 1
                self.needsKeyframe = true
            }
        }
    }

    func shutdown() {
        encoder.invalidate()
        sender.close()
    }

    /// Composites and submits one frame on the app's command queue, so it runs after the app's rendering.
    func submit(views: [View], pose: qlh_pose, queue: MTLCommandQueue) {
        guard views.count == 2 else { return }
        let proceed: Bool = lock.withLock {
            guard inFlight < 3 else { return false }
            inFlight += 1
            frameID &+= 1
            return true
        }
        guard proceed else { return }
        let (id, keyframe) = lock.withLock { () -> (UInt32, Bool) in
            let due = needsKeyframe || Date().timeIntervalSince(lastKeyframe) >= 2
            if due {
                needsKeyframe = false
                lastKeyframe = Date()
            }
            return (frameID, due)
        }

        guard let commandBuffer = queue.makeCommandBuffer() else {
            lock.withLock { inFlight -= 1 }
            return
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = frameTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        var keepAlive: [Any] = []
        if let render = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
            render.setRenderPipelineState(pipeline)
            let eyeWidth = Self.frameWidth / 2
            for (eye, view) in views.enumerated() {
                guard let source = sourceView(view) else { continue }
                keepAlive.append(source)
                render.setViewport(MTLViewport(originX: Double(eye * eyeWidth), originY: 0, width: Double(eyeWidth),
                                               height: Double(Self.frameHeight), znear: 0, zfar: 1))
                let w = Float(view.texture.width), h = Float(view.texture.height)
                var params = SIMD4<Float>(Float(view.rect.offset.x) / w, Float(view.rect.offset.y) / h,
                                          Float(view.rect.extent.width) / w, Float(view.rect.extent.height) / h)
                var encodeSRGB: UInt32 = Self.needsSRGBEncode(view.texture.pixelFormat) ? 1 : 0
                render.setFragmentTexture(source, index: 0)
                render.setFragmentBytes(&params, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
                render.setFragmentBytes(&encodeSRGB, length: MemoryLayout<UInt32>.size, index: 1)
                render.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            render.endEncoding()
        }

        var slices: [CVPixelBuffer] = []
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            for index in 0..<Self.sliceCount {
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, slicePool, &buffer)
                var cvTexture: CVMetalTexture?
                guard let buffer,
                      CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, buffer, nil, .bgra8Unorm,
                                                                Self.frameWidth, Self.sliceHeight, 0, &cvTexture) == kCVReturnSuccess,
                      let cvTexture, let target = CVMetalTextureGetTexture(cvTexture) else { continue }
                keepAlive.append(cvTexture)
                blit.copy(from: frameTexture, sourceSlice: 0, sourceLevel: 0,
                          sourceOrigin: MTLOrigin(x: 0, y: index * Self.sliceHeight, z: 0),
                          sourceSize: MTLSize(width: Self.frameWidth, height: Self.sliceHeight, depth: 1),
                          to: target, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
                slices.append(buffer)
            }
            blit.endEncoding()
        }
        guard slices.count == Self.sliceCount else {
            commandBuffer.commit()
            lock.withLock { inFlight -= 1 }
            return
        }
        commandBuffer.addCompletedHandler { [weak self] _ in
            _ = keepAlive
            self?.encoder.encode(frameID: id, pose: pose, slices: slices, keyframe: keyframe)
        }
        commandBuffer.commit()
    }

    /// A 2D view of the right array slice, reinterpreting sRGB formats as linear so gamma-encoded
    /// values pass straight through to the (non-sRGB) headset frame.
    private func sourceView(_ view: View) -> MTLTexture? {
        let format = Self.linearVariant(view.texture.pixelFormat)
        if view.texture.textureType == .type2D && format == view.texture.pixelFormat { return view.texture }
        return view.texture.makeTextureView(pixelFormat: format, textureType: .type2D,
                                            levels: 0..<1, slices: view.arrayIndex..<(view.arrayIndex + 1))
    }

    static func linearVariant(_ format: MTLPixelFormat) -> MTLPixelFormat {
        switch format {
        case .bgra8Unorm_srgb: return .bgra8Unorm
        case .rgba8Unorm_srgb: return .rgba8Unorm
        default: return format
        }
    }

    /// Float / 10-bit formats hold linear light and must be gamma-encoded for the headset.
    static func needsSRGBEncode(_ format: MTLPixelFormat) -> Bool {
        format == .rgba16Float || format == .rgb10a2Unorm
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct EyeOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex EyeOut eye_vertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        EyeOut out;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        out.uv = float2(p.x, 1.0 - p.y);
        return out;
    }

    float3 linear_to_srgb(float3 c) {
        c = saturate(c);
        return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
    }

    fragment float4 eye_fragment(EyeOut in [[stage_in]], texture2d<float> source [[texture(0)]],
                                 constant float4 &rect [[buffer(0)]], constant uint &encodeSRGB [[buffer(1)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 uv = rect.xy + in.uv * rect.zw;
        float3 color = source.sample(s, uv).rgb;
        if (encodeSRGB != 0) { color = linear_to_srgb(color); }
        return float4(color, 1.0);
    }
    """
}

/// Sends encoded frames to the Tether app (tether_xr_frame_header + payload) over its Unix socket.
final class FrameSender: @unchecked Sendable {
    private let queue = DispatchQueue(label: "tether.openxr.sender", qos: .userInteractive)
    private var fd: Int32 = -1
    private var lastAttempt = Date.distantPast

    func send(_ frame: EncodedFrame) {
        queue.async { [self] in
            if fd < 0 { connect() }
            guard fd >= 0 else { return }
            var header = tether_xr_frame_header()
            header.magic = TETHER_XR_FRAME_MAGIC
            header.frame_id = frame.frameID
            header.pose = frame.pose
            withUnsafeMutableBytes(of: &header.codec_config_bytes) { raw in
                let values = raw.bindMemory(to: UInt32.self)
                for i in 0..<min(values.count, frame.codecConfig.count) { values[i] = UInt32(frame.codecConfig[i].count) }
            }
            withUnsafeMutableBytes(of: &header.video_bytes) { raw in
                let values = raw.bindMemory(to: UInt32.self)
                for i in 0..<min(values.count, frame.video.count) { values[i] = UInt32(frame.video[i].count) }
            }
            var message = withUnsafeBytes(of: &header) { Data($0) }
            for index in 0..<frame.video.count {
                message.append(frame.codecConfig[index])
                message.append(frame.video[index])
            }
            let ok = message.withUnsafeBytes { raw -> Bool in
                var sent = 0
                while sent < raw.count {
                    let n = Darwin.send(fd, raw.baseAddress! + sent, raw.count - sent, 0)
                    if n > 0 { sent += n } else if n < 0 && errno == EINTR { continue } else { return false }
                }
                return true
            }
            if !ok {
                Darwin.close(fd)
                fd = -1
            }
        }
    }

    func close() {
        queue.sync {
            if fd >= 0 { Darwin.close(fd) }
            fd = -1
        }
    }

    private func connect() {
        guard Date().timeIntervalSince(lastAttempt) > 1 else { return }
        lastAttempt = Date()
        let socketPath = SharedTracking.directory + "/xr.sock"
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { Darwin.close(s); return }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in path.withUnsafeBytes { buffer.copyMemory(from: $0) } }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            log("Couldn't connect to Tether at \(socketPath) (errno \(errno)); is Tether running?")
            Darwin.close(s)
            return
        }
        var noSigPipe: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        fd = s
        log("Connected to Tether")
    }
}
