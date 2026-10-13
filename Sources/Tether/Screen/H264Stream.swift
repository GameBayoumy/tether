import AVFoundation
import CoreImage
import CoreMedia
import VideoToolbox

/// Splits an Annex-B byte stream into NAL units.
struct AnnexBParser {
    private var buffer = Data()

    /// `onNAL` receives each complete NAL unit. `onBoundary` is told the header byte and the
    /// following byte of a NAL that has just *started*, so a finished picture can be shown
    /// without waiting for the next start code to arrive.
    mutating func append(_ data: Data, onNAL: (Data) -> Void, onBoundary: (UInt8, UInt8) -> Void) {
        buffer.append(data)
        var consumed = 0
        buffer.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            var starts: [(offset: Int, length: Int)] = []
            var i = 0
            while i + 3 <= count {
                if bytes[i] == 0 && bytes[i + 1] == 0 {
                    if bytes[i + 2] == 1 {
                        starts.append((i, 3)); i += 3; continue
                    }
                    if i + 4 <= count && bytes[i + 2] == 0 && bytes[i + 3] == 1 {
                        starts.append((i, 4)); i += 4; continue
                    }
                }
                i += 1
            }
            guard !starts.isEmpty else { return }
            for k in 0..<(starts.count - 1) {
                let begin = starts[k].offset + starts[k].length
                let end = starts[k + 1].offset
                if end > begin { onNAL(Data(bytes: raw.baseAddress! + begin, count: end - begin)) }
            }
            let last = starts[starts.count - 1]
            let payload = last.offset + last.length
            if payload + 1 < count { onBoundary(bytes[payload], bytes[payload + 1]) }
            consumed = last.offset
        }
        if consumed > 0 { buffer = Data(buffer[(buffer.startIndex + consumed)...]) }
    }
}

/// Turns H.264 NAL units into decoded frames on a display layer.
/// Not thread-safe: drive it from a single serial queue.
final class H264Decoder {
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onFormatChange: ((CGSize) -> Void)?

    private var sps: Data?
    private var pps: Data?
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var pending: [Data] = []

    deinit { invalidate() }

    func invalidate() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
    }

    func handle(_ nal: Data) {
        guard let header = nal.first else { return }
        switch header & 0x1F {
        case 7:
            flush()
            if sps != nal { sps = nal; invalidate() }
        case 8:
            flush()
            if pps != nal { pps = nal; invalidate() }
        case 9:
            flush()
        case 1, 5:
            if nal.count > 1 && nal[nal.startIndex + 1] & 0x80 != 0 { flush() }
            pending.append(nal)
        default:
            break
        }
    }

    /// Called when a new NAL begins; flushes the current picture if this NAL starts another.
    func boundary(header: UInt8, next: UInt8) {
        let type = header & 0x1F
        // first_mb_in_slice == 0 is ue(v) "1", i.e. the top bit of the first slice-header byte.
        if type == 7 || type == 8 || type == 9 || ((type == 1 || type == 5) && next & 0x80 != 0) {
            flush()
        }
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        defer { pending.removeAll(keepingCapacity: true) }
        guard let session = sessionIfReady(), let format else { return }

        var avcc = Data()
        for nal in pending {
            var length = UInt32(nal.count).bigEndian
            avcc.append(Data(bytes: &length, count: 4))
            avcc.append(nal)
        }

        var block: CMBlockBuffer?
        let size = avcc.count
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: size,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: size, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == noErr, let block else { return }
        let copied = avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: size)
        }
        guard copied == noErr else { return }

        var sample: CMSampleBuffer?
        var sampleSize = size
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample
        ) == noErr, let sample else { return }

        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { [weak self] status, _, imageBuffer, _, _ in
            guard status == noErr, let imageBuffer else { return }
            self?.onFrame?(imageBuffer)
        }
        if status == kVTInvalidSessionErr { invalidate() }
    }

    private func sessionIfReady() -> VTDecompressionSession? {
        if let session { return session }
        guard let sps, let pps else { return nil }

        var newFormat: CMVideoFormatDescription?
        let spsBytes = [UInt8](sps)
        let ppsBytes = [UInt8](pps)
        let status = spsBytes.withUnsafeBufferPointer { spsPtr in
            ppsBytes.withUnsafeBufferPointer { ppsPtr in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: [spsPtr.baseAddress!, ppsPtr.baseAddress!],
                    parameterSetSizes: [spsBytes.count, ppsBytes.count],
                    nalUnitHeaderLength: 4, formatDescriptionOut: &newFormat)
            }
        }
        guard status == noErr, let newFormat else { return nil }

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var newSession: VTDecompressionSession?
        guard VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: newFormat, decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
            decompressionSessionOut: &newSession
        ) == noErr, let newSession else { return nil }

        format = newFormat
        session = newSession
        let dims = CMVideoFormatDescriptionGetDimensions(newFormat)
        onFormatChange?(CGSize(width: Int(dims.width), height: Int(dims.height)))
        return newSession
    }
}

/// Owns the decode queue: bytes in, frames out to an `AVSampleBufferDisplayLayer`.
final class DecodePipeline: @unchecked Sendable {
    private let queue = DispatchQueue(label: "tether.screen.decode", qos: .userInteractive)
    private var parser = AnnexBParser()
    private var decoder = H264Decoder()
    private var renderer: AVSampleBufferVideoRenderer?

    private let lock = NSLock()
    private var frameCount = 0
    private var byteCount = 0
    private var latestFrame: CVPixelBuffer?

    var onFormatChange: ((CGSize) -> Void)?

    func reset(renderer: AVSampleBufferVideoRenderer) {
        queue.sync {
            decoder.invalidate()
            parser = AnnexBParser()
            decoder = H264Decoder()
            decoder.onFormatChange = { [weak self] size in self?.onFormatChange?(size) }
            decoder.onFrame = { [weak self] frame in self?.present(frame) }
            self.renderer = renderer
            renderer.flush(removingDisplayedImage: true, completionHandler: nil)
        }
    }

    func ingest(_ data: Data) {
        queue.async { [self] in
            lock.withLock { byteCount += data.count }
            parser.append(data, onNAL: { decoder.handle($0) }, onBoundary: { decoder.boundary(header: $0, next: $1) })
        }
    }

    /// Returns frames and bytes seen since the previous call.
    func takeStats() -> (frames: Int, bytes: Int) {
        lock.withLock {
            defer { frameCount = 0; byteCount = 0 }
            return (frameCount, byteCount)
        }
    }

    func snapshot() -> CGImage? {
        guard let frame = lock.withLock({ latestFrame }) else { return nil }
        let image = CIImage(cvPixelBuffer: frame)
        return CIContext().createCGImage(image, from: image.extent)
    }

    private func present(_ frame: CVPixelBuffer) {
        lock.withLock {
            frameCount += 1
            latestFrame = frame
        }
        guard let renderer else { return }
        if renderer.status == .failed { renderer.flush() }

        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: frame, formatDescriptionOut: &format) == noErr,
              let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: frame, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sample
        ) == noErr, let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        renderer.enqueue(sample)
    }
}
