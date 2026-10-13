import CoreMedia
import CXRSP
import Foundation
import VideoToolbox

/// One frame's worth of encoded slices, ready for `qlh_send_frame`.
public struct EncodedFrame {
    public let frameID: UInt32
    public let pose: qlh_pose
    public var codecConfig: [Data]
    public var video: [Data]

    public init(frameID: UInt32, pose: qlh_pose, codecConfig: [Data], video: [Data]) {
        self.frameID = frameID
        self.pose = pose
        self.codecConfig = codecConfig
        self.video = video
    }
}

/// Encodes each horizontal strip of the stereo frame with its own hardware H.264 session,
/// matching the five independently decodable slices the Quest streaming client expects.
public final class SliceEncoder: @unchecked Sendable {
    public var onFrame: ((EncodedFrame) -> Void)?
    /// Called when any slice of a frame failed or was dropped; the caller must force a keyframe.
    public var onFailure: ((UInt32) -> Void)?

    private struct Pending {
        let pose: qlh_pose
        var codecConfig: [Data?]
        var video: [Data?]
        var remaining: Int
        var failed = false
    }

    /// Per-slice POC rewriter state; each session's output handler runs serially.
    private final class RewriterBox {
        let lock = NSLock()
        var rewriter = H264Rewriter()
    }

    private var sessions: [VTCompressionSession] = []
    private var rewriters: [RewriterBox] = []
    private let lock = NSLock()
    private var pending: [UInt32: Pending] = [:]
    private let fps: Int32

    private static let startCode: [UInt8] = [0, 0, 0, 1]

    public init(width: Int, height: Int, count: Int, fps: Int, bitRatePerSlice: Int) throws {
        self.fps = Int32(fps)
        let specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]
        for _ in 0..<count {
            var session: VTCompressionSession?
            let status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
                codecType: kCMVideoCodecType_H264, encoderSpecification: specification as CFDictionary,
                imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
                refcon: nil, compressionSessionOut: &session)
            guard status == noErr, let session else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                              userInfo: [NSLocalizedDescriptionKey: "Couldn't create the H.264 encoder (\(status))."])
            }
            let properties: [CFString: Any] = [
                kVTCompressionPropertyKey_RealTime: true,
                // Matches the stream profile proven against the stock client: Baseline 5.1, BT.601.
                kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Baseline_5_1,
                kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4,
                kVTCompressionPropertyKey_AllowFrameReordering: false,
                kVTCompressionPropertyKey_AverageBitRate: bitRatePerSlice,
                kVTCompressionPropertyKey_ExpectedFrameRate: fps,
                // Keyframes are forced together across all slices by the pipeline.
                kVTCompressionPropertyKey_MaxKeyFrameInterval: 100_000,
                kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality: true,
            ]
            for (key, value) in properties {
                VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
            }
            VTCompressionSessionPrepareToEncodeFrames(session)
            sessions.append(session)
            rewriters.append(RewriterBox())
        }
    }

    deinit { invalidate() }

    public func invalidate() {
        let closing = lock.withLock {
            defer { sessions.removeAll() }
            return sessions
        }
        for session in closing {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
    }

    public func encode(frameID: UInt32, pose: qlh_pose, slices: [CVPixelBuffer], keyframe: Bool) {
        let sessions = lock.withLock { self.sessions }
        // GPU completion handlers can still deliver a frame after invalidate().
        guard !sessions.isEmpty else { return }
        precondition(slices.count == sessions.count)
        lock.withLock {
            pending[frameID] = Pending(pose: pose,
                                       codecConfig: Array(repeating: nil, count: slices.count),
                                       video: Array(repeating: nil, count: slices.count),
                                       remaining: slices.count)
        }
        let properties = keyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let pts = CMTime(value: CMTimeValue(frameID), timescale: fps)
        for (index, buffer) in slices.enumerated() {
            let status = VTCompressionSessionEncodeFrame(
                sessions[index], imageBuffer: buffer, presentationTimeStamp: pts, duration: .invalid,
                frameProperties: properties, infoFlagsOut: nil
            ) { [weak self] status, flags, sample in
                self?.finish(frameID: frameID, slice: index, status: status,
                             dropped: flags.contains(.frameDropped), sample: sample)
            }
            if status != noErr {
                finish(frameID: frameID, slice: index, status: status, dropped: false, sample: nil)
            }
        }
    }

    private func finish(frameID: UInt32, slice: Int, status: OSStatus, dropped: Bool, sample: CMSampleBuffer?) {
        var converted: (Data, Data)?
        if status == noErr, !dropped, let sample {
            let box = rewriters[slice]
            converted = box.lock.withLock { Self.annexB(sample, rewriter: &box.rewriter) }
        }
        var completed: Pending?
        lock.withLock {
            guard var entry = pending[frameID] else { return }
            if let converted {
                entry.codecConfig[slice] = converted.0
                entry.video[slice] = converted.1
            } else {
                entry.failed = true
            }
            entry.remaining -= 1
            if entry.remaining == 0 {
                pending[frameID] = nil
                completed = entry
            } else {
                pending[frameID] = entry
            }
        }
        guard let completed else { return }
        if completed.failed {
            onFailure?(frameID)
        } else {
            onFrame?(EncodedFrame(frameID: frameID, pose: completed.pose,
                                  codecConfig: completed.codecConfig.map { $0 ?? Data() },
                                  video: completed.video.map { $0 ?? Data() }))
        }
    }

    /// Converts VideoToolbox's AVCC output into Annex-B: SPS/PPS (keyframes only) and slice NALs,
    /// rewritten to pic_order_cnt_type 2 for the headset's decoder.
    private static func annexB(_ sample: CMSampleBuffer, rewriter: inout H264Rewriter) -> (Data, Data)? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var isKeyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let notSync = attachments.first?[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKeyframe = !notSync
        }

        var codecConfig = Data()
        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                               nalUnitHeaderLengthOut: nil)
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                      parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                      nalUnitHeaderLengthOut: nil) == noErr, let pointer, size > 0 {
                    var nal = Data(bytes: pointer, count: size)
                    switch nal[0] & 0x1F {
                    case 7:
                        guard let rewritten = rewriter.rewriteSPS(nal) else { return nil }
                        nal = rewritten
                    case 8:
                        rewriter.readPPS(nal)
                    default:
                        break
                    }
                    codecConfig.append(contentsOf: startCode)
                    codecConfig.append(nal)
                }
            }
        }

        let length = CMBlockBufferGetDataLength(block)
        var avcc = Data(count: length)
        let copied = avcc.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
        }
        guard copied == noErr else { return nil }

        var video = Data(capacity: length + 64)
        var offset = 0
        var rewriteFailed = false
        avcc.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            while offset + 4 <= length {
                let size = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
                let start = offset + 4
                guard size > 0, start + size <= length else { break }
                let type = bytes[start] & 0x1F
                // Only coded slices; the client gets parameter sets separately and doesn't need SEI.
                if type == 1 || type == 5 {
                    let nal = Data(UnsafeBufferPointer(rebasing: bytes[start..<(start + size)]))
                    if let rewritten = rewriter.rewriteSlice(nal) {
                        video.append(contentsOf: startCode)
                        video.append(rewritten)
                    } else {
                        rewriteFailed = true
                    }
                }
                offset = start + size
            }
        }
        return rewriteFailed ? nil : (codecConfig, video)
    }
}
