import AppKit
import CoreVideo
import CXRSP
import Metal
import simd

/// Renders the Link home scene — a floor grid and a large virtual screen — into the
/// side-by-side stereo layout the Quest streaming client decodes, then splits it into slices.
final class VRRenderer {
    struct Uniforms {
        var viewProjection: simd_float4x4
        var model: simd_float4x4
        var params: SIMD4<Float>
        var extra: SIMD4<Float>
    }

    enum ScreenSource {
        case desktop(CVPixelBuffer)
        case card(MTLTexture)
    }

    static let frameWidth = Int(QLH_FRAME_WIDTH)
    static let frameHeight = Int(QLH_FRAME_HEIGHT)
    static let sliceHeight = Int(QLH_SLICE_HEIGHT)
    static let sliceCount = Int(QLH_SLICE_COUNT)

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let floorPipeline: MTLRenderPipelineState
    private let screenPipeline: MTLRenderPipelineState
    private let rayPipeline: MTLRenderPipelineState
    private let previewPipeline: MTLRenderPipelineState
    private var previewPool: CVPixelBufferPool!
    private let previewLock = NSLock()
    private var latestPreviewBuffer: CVPixelBuffer?

    static let previewSize = (width: 720, height: 600)

    /// The most recent left-eye frame, downscaled, for the live window in the Mac app.
    func latestPreview() -> CVPixelBuffer? {
        previewLock.withLock { latestPreviewBuffer }
    }
    private let msaaTarget: MTLTexture
    private let frameTexture: MTLTexture
    private var textureCache: CVMetalTextureCache!
    private var slicePool: CVPixelBufferPool!
    private let eyeFOV: [qlh_fov]

    var ipd: Float = 0.063
    /// The virtual screen: width and distance from the anchor, in metres.
    private let screenWidth: Float = 4.0
    private let screenDistance: Float = 2.2

    private struct Anchor {
        var position: SIMD3<Float>
        var yaw: Float
        var floorY: Float
    }
    private var anchor: Anchor?
    private let anchorLock = NSLock()
    private var recenterRequested = true

    init(device: MTLDevice, eyeFOV: [qlh_fov]) throws {
        self.device = device
        self.eyeFOV = eyeFOV
        guard let queue = device.makeCommandQueue() else { throw RendererError("No Metal command queue") }
        self.queue = queue

        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        func pipeline(_ fragment: String, blended: Bool = false) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "quad_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            descriptor.rasterSampleCount = 4
            if blended {
                let color = descriptor.colorAttachments[0]!
                color.isBlendingEnabled = true
                color.sourceRGBBlendFactor = .sourceAlpha
                color.destinationRGBBlendFactor = .oneMinusSourceAlpha
                color.sourceAlphaBlendFactor = .one
                color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        floorPipeline = try pipeline("floor_fragment")
        screenPipeline = try pipeline("screen_fragment")
        rayPipeline = try pipeline("ray_fragment", blended: true)
        let previewDescriptor = MTLRenderPipelineDescriptor()
        previewDescriptor.vertexFunction = library.makeFunction(name: "fullscreen_vertex")
        previewDescriptor.fragmentFunction = library.makeFunction(name: "preview_fragment")
        previewDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        previewPipeline = try device.makeRenderPipelineState(descriptor: previewDescriptor)

        let msaa = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Self.frameWidth,
                                                            height: Self.frameHeight, mipmapped: false)
        msaa.textureType = .type2DMultisample
        msaa.sampleCount = 4
        msaa.usage = .renderTarget
        msaa.storageMode = .private
        let frame = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Self.frameWidth,
                                                             height: Self.frameHeight, mipmapped: false)
        frame.usage = [.renderTarget, .shaderRead]
        frame.storageMode = .private
        guard let msaaTarget = device.makeTexture(descriptor: msaa),
              let frameTexture = device.makeTexture(descriptor: frame) else { throw RendererError("Couldn't allocate render targets") }
        self.msaaTarget = msaaTarget
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
        let previewAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: Self.previewSize.width,
            kCVPixelBufferHeightKey: Self.previewSize.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary,
                                previewAttributes as CFDictionary, &previewPool)
    }

    private var desktopTexture: MTLTexture?

    private func mipmappedDesktop(width: Int, height: Int) -> MTLTexture? {
        if let desktopTexture, desktopTexture.width == width, desktopTexture.height == height { return desktopTexture }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: true)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .private
        desktopTexture = device.makeTexture(descriptor: descriptor)
        return desktopTexture
    }

    // MARK: End Link panel

    /// Panel size in metres; its texture is drawn at 2:1.
    static let panelSize = SIMD2<Float>(0.64, 0.32)
    private var panelTextures: [MTLTexture] = []
    private var panelVisible = false
    private var panelOpenRequested = false
    private var panelAnchor: (center: SIMD3<Float>, yaw: Float) = (.zero, 0)

    var isPanelVisible: Bool { anchorLock.withLock { panelVisible } }

    func setPanelVisible(_ visible: Bool) {
        anchorLock.withLock {
            panelVisible = visible
            if visible { panelOpenRequested = true }
        }
    }

    /// Which panel button a uv lands on: 1 End Link, 2 Cancel, 0 neither.
    static func panelButton(at uv: SIMD2<Float>) -> Int {
        guard uv.y > 0.56 && uv.y < 0.88 else { return 0 }
        if uv.x > 0.07 && uv.x < 0.485 { return 1 }
        if uv.x > 0.515 && uv.x < 0.93 { return 2 }
        return 0
    }

    func preparePanelTextures() {
        guard panelTextures.isEmpty else { return }
        panelTextures = (0..<3).compactMap { makePanelTexture(highlight: $0) }
    }

    private func makePanelTexture(highlight: Int) -> MTLTexture? {
        let width = 1280, height = 640
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 0.078, green: 0.102, blue: 0.149, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, in rect: CGRect) {
            let font = NSFont.systemFont(ofSize: size, weight: weight)
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: center]).draw(in: rect)
        }
        draw("End Quest Link?", size: 76, weight: .semibold, color: .white, in: CGRect(x: 60, y: 420, width: width - 120, height: 100))
        draw("Your headset returns to Quest Home.", size: 40, weight: .regular,
             color: NSColor(white: 0.72, alpha: 1), in: CGRect(x: 60, y: 350, width: width - 120, height: 60))

        // Buttons in texture coordinates (y up): uv.y 0.56...0.88 from the top is y 77...282 here.
        let gold = NSColor(red: 0.914, green: 0.761, blue: 0.478, alpha: 1)
        let endRect = CGRect(x: 90, y: 90, width: 530, height: 180)
        let cancelRect = CGRect(x: 660, y: 90, width: 530, height: 180)
        gold.withAlphaComponent(highlight == 1 ? 1 : 0.82).setFill()
        NSBezierPath(roundedRect: endRect, xRadius: 36, yRadius: 36).fill()
        NSColor(red: 0.16, green: 0.2, blue: 0.27, alpha: highlight == 2 ? 1 : 0.75).setFill()
        NSBezierPath(roundedRect: cancelRect, xRadius: 36, yRadius: 36).fill()
        if highlight == 2 {
            NSColor.white.withAlphaComponent(0.35).setStroke()
            let outline = NSBezierPath(roundedRect: cancelRect.insetBy(dx: 2, dy: 2), xRadius: 34, yRadius: 34)
            outline.lineWidth = 4
            outline.stroke()
        }
        draw("End Link", size: 58, weight: .semibold, color: NSColor(red: 0.11, green: 0.086, blue: 0.03, alpha: 1),
             in: endRect.insetBy(dx: 10, dy: 52))
        draw("Cancel", size: 58, weight: .medium, color: .white, in: cancelRect.insetBy(dx: 10, dy: 52))
        NSGraphicsContext.restoreGraphicsState()

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: true)
        guard let texture = device.makeTexture(descriptor: descriptor), let data = context.data else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: data, bytesPerRow: width * 4)
        if let commandBuffer = queue.makeCommandBuffer(), let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }
        return texture
    }

    func requestRecenter() {
        anchorLock.withLock { recenterRequested = true }
    }

    /// Where a controller points: the Touch grip pose turned up about its X axis toward Quest's aim pose.
    /// Monado used 35°; on Horizon OS v207 that points visibly too high, so 15°.
    static let aimPitchDegrees: Float = 15
    static func aimRay(_ controller: qlh_controller) -> (origin: SIMD3<Float>, direction: SIMD3<Float>)? {
        guard controller.pose_valid else { return nil }
        let o = controller.pose.orientation
        let grip = simd_quatf(ix: o.0, iy: o.1, iz: o.2, r: o.3)
        let aim = grip * simd_quatf(angle: aimPitchDegrees * .pi / 180, axis: SIMD3(1, 0, 0))
        let p = controller.pose.position
        return (SIMD3(p.0, p.1, p.2), simd_normalize(aim.act(SIMD3(0, 0, -1))))
    }

    /// Renders one stereo frame for `pose` and hands back one pixel buffer per slice once the GPU is done.
    /// Controller rays are drawn and hit-tested against the screen; `hits` receives each hand's uv (0...1, y down).
    /// Returns false if nothing was submitted, in which case `completion` is never called.
    @discardableResult
    func render(pose: qlh_pose, source: ScreenSource, controllers: [qlh_controller] = [], activeHand: Int = 1,
                pressed: Bool = false, hits: inout [SIMD2<Float>?], panelHits: inout [SIMD2<Float>?],
                completion: @escaping ([CVPixelBuffer]) -> Void) -> Bool {
        let orientation = simd_quatf(ix: pose.orientation.0, iy: pose.orientation.1, iz: pose.orientation.2, r: pose.orientation.3)
        let position = SIMD3<Float>(pose.position.0, pose.position.1, pose.position.2)
        let head = simd_float4x4.translation(position) * simd_float4x4(orientation)
        let anchor = currentAnchor(headPosition: position, orientation: orientation)

        guard let commandBuffer = queue.makeCommandBuffer() else { return false }

        // Resolve the screen texture for this frame.
        var keepAlive: [Any] = []
        var screenTexture: MTLTexture?
        var aspect: Float = 16.0 / 9.0
        switch source {
        case .desktop(let buffer):
            if let captured = makeTexture(from: buffer, keepAlive: &keepAlive),
               let mipmapped = mipmappedDesktop(width: captured.width, height: captured.height),
               let blit = commandBuffer.makeBlitCommandEncoder() {
                // The desktop is minified ~4-5x on its way to the headset; without mips, text shimmers and breaks up.
                blit.copy(from: captured, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                          sourceSize: MTLSize(width: captured.width, height: captured.height, depth: 1),
                          to: mipmapped, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
                blit.generateMipmaps(for: mipmapped)
                blit.endEncoding()
                screenTexture = mipmapped
                aspect = Float(captured.width) / Float(captured.height)
            }
        case .card(let texture):
            screenTexture = texture
            aspect = Float(texture.width) / Float(texture.height)
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = msaaTarget
        pass.colorAttachments[0].resolveTexture = frameTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.018, green: 0.022, blue: 0.035, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        let eyeWidth = Self.frameWidth / 2
        let floorModel = simd_float4x4.translation(SIMD3(position.x, anchor.floorY, position.z))
            * simd_float4x4.rotationX(-.pi / 2) * simd_float4x4.scale(SIMD3(80, 80, 1))
        let screenHeight = screenWidth / aspect
        let screenCenter = anchor.position + SIMD3(-sin(anchor.yaw), 0, -cos(anchor.yaw)) * screenDistance
        let screenModel = simd_float4x4.translation(screenCenter) * simd_float4x4.rotationY(anchor.yaw)
            * simd_float4x4.scale(SIMD3(screenWidth, screenHeight, 1))

        // Controller rays against the screen plane.
        let screenRight = SIMD3<Float>(cos(anchor.yaw), 0, -sin(anchor.yaw))
        let screenNormal = SIMD3<Float>(sin(anchor.yaw), 0, cos(anchor.yaw))
        var rays: [(from: SIMD3<Float>, to: SIMD3<Float>, active: Bool)] = []
        hits = [nil, nil]
        for (index, controller) in controllers.enumerated() where index < 2 {
            guard let ray = Self.aimRay(controller) else { continue }
            var end = ray.origin + ray.direction * 4
            let facing = simd_dot(ray.direction, screenNormal)
            if facing < -0.05 {
                let t = simd_dot(screenCenter - ray.origin, screenNormal) / facing
                if t > 0 {
                    let point = ray.origin + ray.direction * t
                    let local = point - screenCenter
                    let uv = SIMD2<Float>(simd_dot(local, screenRight) / screenWidth + 0.5, 0.5 - local.y / screenHeight)
                    if uv.x > -0.02 && uv.x < 1.02 && uv.y > -0.02 && uv.y < 1.02 {
                        hits[index] = uv
                        end = point
                    }
                }
            }
            rays.append((ray.origin + ray.direction * 0.03, end, index == activeHand))
        }
        // The End Link panel floats in front of where you were looking when it opened, and takes the rays first.
        let (showPanel, panel) = anchorLock.withLock { () -> (Bool, (center: SIMD3<Float>, yaw: Float)) in
            if panelOpenRequested {
                let forward = orientation.act(SIMD3<Float>(0, 0, -1))
                let yaw = atan2(-forward.x, -forward.z)
                panelAnchor = (position + SIMD3(-sin(yaw), 0, -cos(yaw)) * 0.9 + SIMD3(0, -0.08, 0), yaw)
                panelOpenRequested = false
            }
            return (panelVisible, panelAnchor)
        }
        panelHits = [nil, nil]
        if showPanel {
            let right = SIMD3<Float>(cos(panel.yaw), 0, -sin(panel.yaw))
            let normal = SIMD3<Float>(sin(panel.yaw), 0, cos(panel.yaw))
            for (index, controller) in controllers.enumerated() where index < 2 {
                guard let ray = Self.aimRay(controller) else { continue }
                let facing = simd_dot(ray.direction, normal)
                guard facing < -0.05 else { continue }
                let t = simd_dot(panel.center - ray.origin, normal) / facing
                guard t > 0 else { continue }
                let point = ray.origin + ray.direction * t
                let local = point - panel.center
                let uv = SIMD2<Float>(simd_dot(local, right) / Self.panelSize.x + 0.5, 0.5 - local.y / Self.panelSize.y)
                if uv.x >= 0 && uv.x <= 1 && uv.y >= 0 && uv.y <= 1 {
                    panelHits[index] = uv
                    hits[index] = nil
                    if let rayIndex = rays.firstIndex(where: { $0.active == (index == activeHand) }) {
                        rays[rayIndex].to = point
                    }
                }
            }
        }
        let panelCursor = panelHits.indices.contains(activeHand) ? panelHits[activeHand] : nil
        let cursor = hits.indices.contains(activeHand) ? hits[activeHand] : nil

        for eye in 0..<2 {
            let offset = SIMD3<Float>(eye == 0 ? -ipd / 2 : ipd / 2, 0, 0)
            let view = (head * simd_float4x4.translation(offset)).inverse
            let viewProjection = Self.projection(eyeFOV[eye], near: 0.05, far: 200) * view
            encoder.setViewport(MTLViewport(originX: Double(eye * eyeWidth), originY: 0, width: Double(eyeWidth),
                                            height: Double(Self.frameHeight), znear: 0, zfar: 1))
            encoder.setScissorRect(MTLScissorRect(x: eye * eyeWidth, y: 0, width: eyeWidth, height: Self.frameHeight))

            var floor = Uniforms(viewProjection: viewProjection, model: floorModel,
                                 params: SIMD4(position.x, position.z, 0, 0), extra: .zero)
            encoder.setRenderPipelineState(floorPipeline)
            encoder.setVertexBytes(&floor, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentBytes(&floor, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

            if let screenTexture {
                var screen = Uniforms(viewProjection: viewProjection, model: screenModel,
                                      params: SIMD4(aspect, 0, 0, 0),
                                      extra: cursor.map { SIMD4($0.x, $0.y, 1, pressed ? 1 : 0) } ?? .zero)
                encoder.setRenderPipelineState(screenPipeline)
                encoder.setVertexBytes(&screen, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.setFragmentBytes(&screen, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.setFragmentTexture(screenTexture, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }

            if showPanel, panelTextures.count == 3 {
                let hover = panelCursor.map { Self.panelButton(at: $0) } ?? 0
                var uniforms = Uniforms(viewProjection: viewProjection,
                                        model: simd_float4x4.translation(panel.center) * simd_float4x4.rotationY(panel.yaw)
                                            * simd_float4x4.scale(SIMD3(Self.panelSize.x, Self.panelSize.y, 1)),
                                        params: SIMD4(2, 0, 0, 0),
                                        extra: panelCursor.map { SIMD4($0.x, $0.y, 1, pressed ? 1 : 0) } ?? .zero)
                encoder.setRenderPipelineState(screenPipeline)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.setFragmentTexture(panelTextures[hover], index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }

            // Laser rays: thin strips turned to face this eye.
            let eyeWorld = head * SIMD4<Float>(offset, 1)
            let eyePosition = SIMD3<Float>(eyeWorld.x, eyeWorld.y, eyeWorld.z)
            encoder.setRenderPipelineState(rayPipeline)
            for ray in rays {
                let axis = ray.from - ray.to
                let middle = (ray.from + ray.to) / 2
                var side = simd_cross(axis, eyePosition - middle)
                guard simd_length(side) > 1e-5 else { continue }
                side = simd_normalize(side) * 0.004
                let normal = simd_normalize(simd_cross(side, axis))
                var uniforms = Uniforms(
                    viewProjection: viewProjection,
                    model: simd_float4x4(columns: (SIMD4(side, 0), SIMD4(axis, 0), SIMD4(normal, 0), SIMD4(middle, 1))),
                    params: .zero,
                    extra: ray.active ? SIMD4(0.914, 0.761, 0.478, 0.9) : SIMD4(0.93, 0.95, 0.97, 0.35))
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }
        encoder.endEncoding()

        // Copy each 384-row strip into its own encoder input buffer.
        var slices: [CVPixelBuffer] = []
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            for index in 0..<Self.sliceCount {
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, slicePool, &buffer)
                guard let buffer, let target = makeTexture(from: buffer, keepAlive: &keepAlive) else { continue }
                blit.copy(from: frameTexture, sourceSlice: 0, sourceLevel: 0,
                          sourceOrigin: MTLOrigin(x: 0, y: index * Self.sliceHeight, z: 0),
                          sourceSize: MTLSize(width: Self.frameWidth, height: Self.sliceHeight, depth: 1),
                          to: target, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
                slices.append(buffer)
            }
            blit.endEncoding()
        }
        guard slices.count == Self.sliceCount else { return false }

        // A downscaled copy of the left eye for the Mac app's live window.
        var previewBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, previewPool, &previewBuffer)
        if let previewBuffer, let previewTarget = makeTexture(from: previewBuffer, keepAlive: &keepAlive) {
            let previewPass = MTLRenderPassDescriptor()
            previewPass.colorAttachments[0].texture = previewTarget
            previewPass.colorAttachments[0].loadAction = .dontCare
            previewPass.colorAttachments[0].storeAction = .store
            if let previewEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: previewPass) {
                previewEncoder.setRenderPipelineState(previewPipeline)
                previewEncoder.setFragmentTexture(frameTexture, index: 0)
                previewEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                previewEncoder.endEncoding()
            }
        }
        commandBuffer.addCompletedHandler { [weak self] _ in
            _ = keepAlive
            if let previewBuffer { self?.previewLock.withLock { self?.latestPreviewBuffer = previewBuffer } }
            completion(slices)
        }
        commandBuffer.commit()
        return true
    }

    /// Text card shown on the virtual screen when there's no desktop to mirror.
    func makeCard(title: String, subtitle: String) -> MTLTexture? {
        let width = 1920, height = 1080
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [CGColor(red: 0.0, green: 0.30, blue: 0.85, alpha: 1),
                                           CGColor(red: 0.36, green: 0.16, blue: 0.78, alpha: 1)] as CFArray,
                                  locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 96, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: paragraph,
        ]
        let subtitleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 44, weight: .regular), .foregroundColor: NSColor.white.withAlphaComponent(0.85),
            .paragraphStyle: paragraph,
        ]
        NSAttributedString(string: title, attributes: titleAttributes)
            .draw(in: CGRect(x: 80, y: Double(height) / 2 + 10, width: Double(width) - 160, height: 130))
        NSAttributedString(string: subtitle, attributes: subtitleAttributes)
            .draw(in: CGRect(x: 160, y: Double(height) / 2 - 200, width: Double(width) - 320, height: 190))
        NSGraphicsContext.restoreGraphicsState()

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: true)
        guard let texture = device.makeTexture(descriptor: descriptor), let data = context.data else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: data, bytesPerRow: width * 4)
        if let commandBuffer = queue.makeCommandBuffer(), let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }
        return texture
    }

    // MARK: - Helpers

    private func currentAnchor(headPosition: SIMD3<Float>, orientation: simd_quatf) -> Anchor {
        anchorLock.withLock {
            if recenterRequested || anchor == nil {
                let forward = orientation.act(SIMD3<Float>(0, 0, -1))
                // Ignore pitch so the screen stays upright in front of you.
                let yaw = (abs(forward.x) + abs(forward.z) > 0.05) ? atan2(-forward.x, -forward.z) : 0
                anchor = Anchor(position: headPosition, yaw: yaw, floorY: headPosition.y - 1.6)
                recenterRequested = false
            }
            return anchor!
        }
    }

    private func makeTexture(from buffer: CVPixelBuffer, keepAlive: inout [Any]) -> MTLTexture? {
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        keepAlive.append(cvTexture)
        keepAlive.append(buffer)
        return texture
    }

    /// Off-axis projection from the lens half-angles (degrees), Metal clip space (z in 0...1).
    static func projection(_ fov: qlh_fov, near: Float, far: Float) -> simd_float4x4 {
        let radians = Float.pi / 180
        let left = -tan(fov.left * radians) * near
        let right = tan(fov.right * radians) * near
        let bottom = -tan(fov.down * radians) * near
        let top = tan(fov.up * radians) * near
        return simd_float4x4(columns: (
            SIMD4(2 * near / (right - left), 0, 0, 0),
            SIMD4(0, 2 * near / (top - bottom), 0, 0),
            SIMD4((right + left) / (right - left), (top + bottom) / (top - bottom), far / (near - far), -1),
            SIMD4(0, 0, near * far / (near - far), 0)
        ))
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4x4 viewProjection;
        float4x4 model;
        float4 params;
        float4 extra;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
        float3 world;
    };

    struct PreviewOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex PreviewOut fullscreen_vertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        PreviewOut out;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        out.uv = float2(p.x, 1.0 - p.y);
        return out;
    }

    // Left eye only, cropped to the preview's aspect around the eye centre.
    fragment float4 preview_fragment(PreviewOut in [[stage_in]], texture2d<float> frame [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float eyeAspect = (frame.get_width() * 0.5) / float(frame.get_height());
        float previewAspect = 720.0 / 600.0;
        float2 uv = in.uv;
        float scale = eyeAspect / previewAspect;
        uv.y = 0.5 + (uv.y - 0.5) * scale;
        return float4(frame.sample(s, float2(uv.x * 0.5, uv.y)).rgb, 1.0);
    }

    vertex VertexOut quad_vertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
        const float2 corners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };
        float2 c = corners[vid];
        float4 world = u.model * float4(c.x - 0.5, 0.5 - c.y, 0.0, 1.0);
        VertexOut out;
        out.position = u.viewProjection * world;
        out.uv = c;
        out.world = world.xyz;
        return out;
    }

    fragment float4 floor_fragment(VertexOut in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
        float2 p = in.world.xz;
        float2 g = abs(fract(p - 0.5) - 0.5) / max(fwidth(p), float2(1e-4));
        float line = 1.0 - min(min(g.x, g.y), 1.0);
        float dist = length(p - u.params.xy);
        float fade = exp(-dist * 0.11);
        float3 base = float3(0.03, 0.035, 0.055) * (0.6 + 0.4 * fade);
        float3 color = mix(base, float3(0.28, 0.45, 0.85), line * 0.55 * fade);
        return float4(color, 1.0);
    }

    fragment float4 ray_fragment(VertexOut in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
        float across = 1.0 - smoothstep(0.15, 0.5, abs(in.uv.x - 0.5));
        float along = mix(0.35, 1.0, in.uv.y);
        return float4(u.extra.rgb, u.extra.a * across * along);
    }

    fragment float4 screen_fragment(VertexOut in [[stage_in]], constant Uniforms &u [[buffer(0)]],
                                    texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(mag_filter::linear, min_filter::linear, mip_filter::linear, max_anisotropy(16), address::clamp_to_edge);
        float aspect = u.params.x;
        // Rounded corners with a soft edge.
        float2 q = abs(in.uv - 0.5) * float2(aspect, 1.0);
        float2 halfSize = float2(aspect, 1.0) * 0.5;
        float radius = 0.02;
        float2 d = q - (halfSize - radius);
        float dist = length(max(d, 0.0)) - radius;
        float alpha = 1.0 - smoothstep(-0.002, 0.002, dist);
        float3 color = tex.sample(s, in.uv).rgb;
        // Controller cursor: a white dot with a dark rim, gold while the trigger is held.
        if (u.extra.z > 0.5) {
            float c = length((in.uv - u.extra.xy) * float2(aspect, 1.0));
            float3 dotColor = u.extra.w > 0.5 ? float3(0.914, 0.761, 0.478) : float3(1.0);
            color = mix(color, float3(0.02), 1.0 - smoothstep(0.0085, 0.0105, c));
            color = mix(color, dotColor, 1.0 - smoothstep(0.0062, 0.0078, c));
        }
        float3 background = float3(0.018, 0.022, 0.035);
        return float4(mix(background, color, alpha), 1.0);
    }
    """
}

struct RendererError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension simd_float4x4 {
    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(t.x, t.y, t.z, 1)))
    }

    static func scale(_ s: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(diagonal: SIMD4(s.x, s.y, s.z, 1))
    }

    static func rotationX(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle), s = sin(angle)
        return simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, c, s, 0), SIMD4(0, -s, c, 0), SIMD4(0, 0, 0, 1)))
    }

    static func rotationY(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle), s = sin(angle)
        return simd_float4x4(columns: (SIMD4(c, 0, -s, 0), SIMD4(0, 1, 0, 0), SIMD4(s, 0, c, 0), SIMD4(0, 0, 0, 1)))
    }
}
