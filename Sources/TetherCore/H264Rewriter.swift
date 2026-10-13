import Foundation

/// Rewrites VideoToolbox H.264 (pic_order_cnt_type 0) into pic_order_cnt_type 2, which the Quest's
/// low-latency strip decoder requires ("pic_order_cnt_type != 2"). Valid because the stream has no
/// B-frames: with type 2, picture order follows decode order. Handles Baseline/CAVLC progressive streams.
struct H264Rewriter {
    struct Parameters {
        var log2MaxFrameNum = 4
        var pocType = 0
        var log2MaxPocLsb = 4
        var bottomFieldPocPresent = false
        var frameMbsOnly = true
    }

    private(set) var parameters = Parameters()

    /// Rewrites an SPS NAL (header byte included) and records the fields slices depend on.
    /// Returns nil if the SPS is a layout this rewriter doesn't handle.
    mutating func rewriteSPS(_ nal: Data) -> Data? {
        guard nal.count > 4 else { return nil }
        let rbsp = Self.removeEmulationPrevention(nal.dropFirst())
        var reader = BitReader(rbsp)
        var writer = BitWriter()
        guard let profile = reader.read(8) else { return nil }
        // High-profile SPS carry chroma/bit-depth fields; VideoToolbox Baseline output never does.
        guard [66, 77, 88].contains(profile) else { return nil }
        writer.write(profile, 8)
        guard let constraints = reader.read(8), let level = reader.read(8), let spsID = reader.readUE(),
              let log2MaxFrameNumMinus4 = reader.readUE(), let pocType = reader.readUE() else { return nil }
        writer.write(constraints, 8)
        writer.write(level, 8)
        writer.writeUE(spsID)
        writer.writeUE(log2MaxFrameNumMinus4)
        parameters.log2MaxFrameNum = log2MaxFrameNumMinus4 + 4
        parameters.pocType = pocType
        switch pocType {
        case 0:
            guard let lsbMinus4 = reader.readUE() else { return nil }
            parameters.log2MaxPocLsb = lsbMinus4 + 4
        case 2:
            return nal // already what the headset wants
        default:
            return nil
        }
        writer.writeUE(2)

        // max_num_ref_frames, gaps flag, width, height, frame_mbs_only — read only to learn frame_mbs_only.
        var peek = reader
        guard peek.readUE() != nil, peek.read(1) != nil, peek.readUE() != nil, peek.readUE() != nil,
              let frameMbsOnly = peek.read(1) else { return nil }
        parameters.frameMbsOnly = frameMbsOnly == 1
        guard parameters.frameMbsOnly else { return nil }

        guard Self.copyPayload(from: rbsp, reader: reader, into: &writer) else { return nil }
        return Self.finish(header: nal[nal.startIndex], rbsp: writer.bytes)
    }

    mutating func readPPS(_ nal: Data) {
        let rbsp = Self.removeEmulationPrevention(nal.dropFirst())
        var reader = BitReader(rbsp)
        _ = reader.readUE() // pps id
        _ = reader.readUE() // sps id
        _ = reader.read(1)  // entropy_coding_mode_flag
        parameters.bottomFieldPocPresent = reader.read(1) == 1
    }

    /// Drops pic_order_cnt_lsb (and delta_pic_order_cnt_bottom) from a coded-slice NAL header.
    func rewriteSlice(_ nal: Data) -> Data? {
        guard parameters.pocType == 0, nal.count > 2 else { return nal }
        let header = nal[nal.startIndex]
        let isIDR = header & 0x1F == 5
        let rbsp = Self.removeEmulationPrevention(nal.dropFirst())
        var reader = BitReader(rbsp)
        var writer = BitWriter()
        guard let firstMb = reader.readUE(), let sliceType = reader.readUE(), let ppsID = reader.readUE(),
              let frameNum = reader.read(parameters.log2MaxFrameNum) else { return nil }
        writer.writeUE(firstMb)
        writer.writeUE(sliceType)
        writer.writeUE(ppsID)
        writer.write(frameNum, parameters.log2MaxFrameNum)
        if isIDR {
            guard let idrPicID = reader.readUE() else { return nil }
            writer.writeUE(idrPicID)
        }
        guard reader.read(parameters.log2MaxPocLsb) != nil else { return nil }
        if parameters.bottomFieldPocPresent {
            guard reader.readSE() != nil else { return nil }
        }
        guard Self.copyPayload(from: rbsp, reader: reader, into: &writer) else { return nil }
        return Self.finish(header: header, rbsp: writer.bytes)
    }

    // MARK: - Bitstream plumbing

    /// Copies everything from the reader position up to the rbsp_stop_one_bit, then re-terminates.
    private static func copyPayload(from rbsp: [UInt8], reader: BitReader, into writer: inout BitWriter) -> Bool {
        guard let lastIndex = rbsp.lastIndex(where: { $0 != 0 }) else { return false }
        let stopBit = lastIndex * 8 + (7 - rbsp[lastIndex].trailingZeroBitCount)
        guard stopBit >= reader.position else { return false }
        writer.copyBits(from: rbsp, start: reader.position, end: stopBit)
        writer.write(1, 1)
        writer.alignWithZeros()
        return true
    }

    private static func finish(header: UInt8, rbsp: [UInt8]) -> Data {
        var out = Data(capacity: rbsp.count + rbsp.count / 64 + 2)
        out.append(header)
        var zeros = 0
        for byte in rbsp {
            if zeros >= 2 && byte <= 3 {
                out.append(3)
                zeros = 0
            }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return out
    }

    static func removeEmulationPrevention<C: Collection>(_ bytes: C) -> [UInt8] where C.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var zeros = 0
        for byte in bytes {
            if zeros >= 2 && byte == 3 {
                zeros = 0
                continue
            }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return out
    }
}

struct BitReader {
    private let bytes: [UInt8]
    private(set) var position = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func read(_ count: Int) -> Int? {
        guard count >= 0, position + count <= bytes.count * 8 else { return nil }
        var value = 0
        for _ in 0..<count {
            let bit = (bytes[position >> 3] >> (7 - UInt8(position & 7))) & 1
            value = (value << 1) | Int(bit)
            position += 1
        }
        return value
    }

    mutating func readUE() -> Int? {
        var zeros = 0
        while true {
            guard let bit = read(1) else { return nil }
            if bit == 1 { break }
            zeros += 1
            if zeros > 31 { return nil }
        }
        guard let suffix = read(zeros) else { return nil }
        return (1 << zeros) - 1 + suffix
    }

    mutating func readSE() -> Int? {
        guard let k = readUE() else { return nil }
        return k & 1 == 1 ? (k + 1) / 2 : -(k / 2)
    }
}

struct BitWriter {
    private(set) var bytes: [UInt8] = []
    private var bitCount = 0

    mutating func write(_ value: Int, _ count: Int) {
        guard count > 0 else { return }
        for shift in stride(from: count - 1, through: 0, by: -1) {
            appendBit(UInt8((value >> shift) & 1))
        }
    }

    mutating func writeUE(_ value: Int) {
        let coded = value + 1
        let length = Int.bitWidth - coded.leadingZeroBitCount
        write(0, length - 1)
        write(coded, length)
    }

    mutating func alignWithZeros() {
        while bitCount & 7 != 0 { appendBit(0) }
    }

    /// Bulk copy of bits [start, end) from `source`, a byte at a time once aligned to the writer.
    mutating func copyBits(from source: [UInt8], start: Int, end: Int) {
        var position = start
        // Bring the writer to a byte boundary.
        while bitCount & 7 != 0 && position < end {
            appendBit((source[position >> 3] >> (7 - UInt8(position & 7))) & 1)
            position += 1
        }
        let shift = position & 7
        bytes.reserveCapacity(bytes.count + (end - position) / 8 + 1)
        source.withUnsafeBufferPointer { src in
            if shift == 0 {
                while position + 8 <= end {
                    bytes.append(src[position >> 3])
                    position += 8
                    bitCount += 8
                }
            } else {
                let s = UInt8(shift)
                while position + 8 <= end {
                    let i = position >> 3
                    bytes.append((src[i] << s) | (src[i + 1] >> (8 - s)))
                    position += 8
                    bitCount += 8
                }
            }
        }
        while position < end {
            appendBit((source[position >> 3] >> (7 - UInt8(position & 7))) & 1)
            position += 1
        }
    }

    private mutating func appendBit(_ bit: UInt8) {
        if bitCount & 7 == 0 { bytes.append(0) }
        if bit != 0 { bytes[bytes.count - 1] |= 1 << (7 - UInt8(bitCount & 7)) }
        bitCount += 1
    }
}
