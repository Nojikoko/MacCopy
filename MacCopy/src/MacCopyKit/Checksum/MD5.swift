import Foundation

/// MD5 纯 Swift 实现（RFC 1321）。
///
/// CryptoKit 不提供 MD5，故自研。标准 64 轮 + 4 轮函数。
public struct MD5Hasher: ChecksumAlgorithm {
    /// 算法标识。
    public let id: ChecksumAlgorithmID = .md5
    /// 中文展示名。
    public let displayName = "MD5"
    /// 摘要字节长度。
    public let digestLength = 16

    /// 消息块缓冲区（64 字节）。
    private var block = [UInt8](repeating: 0, count: 64)
    /// 块内已填充字节数。
    private var blockLength = 0
    /// 已处理的总字节数。
    private var totalLength: UInt64 = 0
    /// 状态向量 A/B/C/D。
    private var state: (UInt32, UInt32, UInt32, UInt32) = (0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476)

    /// 构造 MD5 计算器。
    public init() {
        reset()
    }

    /// 追加数据。
    public mutating func update(buffer: UnsafeRawBufferPointer) {
        guard !buffer.isEmpty else { return }
        totalLength &+= UInt64(buffer.count)

        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            var offset = 0

            // 先填满当前块。
            if blockLength > 0 {
                let need = 64 - blockLength
                let take = min(need, raw.count)
                for index in 0..<take {
                    block[blockLength + index] = bytes[offset + index]
                }
                blockLength += take
                offset += take
                if blockLength == 64 {
                    processBlock()
                    blockLength = 0
                }
            }

            // 整块处理。
            while offset + 64 <= raw.count {
                for index in 0..<64 {
                    block[index] = bytes[offset + index]
                }
                processBlock()
                offset += 64
            }

            // 剩余不足一块。
            if offset < raw.count {
                let remaining = raw.count - offset
                for index in 0..<remaining {
                    block[index] = bytes[offset + index]
                }
                blockLength = remaining
            }
        }
    }

    /// 计算最终摘要（小端序 16 字节）。
    public mutating func finalize() -> [UInt8] {
        let bitLength = totalLength &* 8

        // 填充 0x80，再补零到 56 (mod 64)，最后 8 字节长度（小端）。
        var padding = [UInt8]()
        padding.reserveCapacity(72)
        padding.append(0x80)
        let remainder = Int((totalLength &+ 1) % 64)
        let zeroCount = remainder <= 56 ? 56 - remainder : 120 - remainder
        padding.append(contentsOf: [UInt8](repeating: 0, count: zeroCount))
        for index in 0..<8 {
            padding.append(UInt8((bitLength >> (8 * UInt64(index))) & 0xFF))
        }

        padding.withUnsafeBytes { raw in
            update(buffer: raw)
        }
        // 注意：padding 不计入 totalLength 语义，故上面 update 会改变 totalLength，
        // 但 bitLength 已在填充前快照。

        let a = state.0
        let b = state.1
        let c = state.2
        let d = state.3

        var digest = [UInt8]()
        digest.reserveCapacity(16)
        for word in [a, b, c, d] {
            digest.append(UInt8(word & 0xFF))
            digest.append(UInt8((word >> 8) & 0xFF))
            digest.append(UInt8((word >> 16) & 0xFF))
            digest.append(UInt8((word >> 24) & 0xFF))
        }
        return digest
    }

    /// 重置。
    public mutating func reset() {
        block = [UInt8](repeating: 0, count: 64)
        blockLength = 0
        totalLength = 0
        state = (0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476)
    }

    // MARK: - 内部实现

    /// 每轮使用的移位量。
    private static let shifts: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ]

    /// 每轮使用的常量 K[i] = floor(abs(sin(i+1)) * 2^32)。
    private static let sines: [UInt32] = [
        0xd76a_a478, 0xe8c7_b756, 0x2420_70db, 0xc1bd_ceee,
        0xf57c_0faf, 0x4787_c62a, 0xa830_4613, 0xfd46_9501,
        0x6980_98d8, 0x8b44_f7af, 0xffff_5bb1, 0x895c_d7be,
        0x6b90_1122, 0xfd98_7193, 0xa679_438e, 0x49b4_0821,
        0xf61e_2562, 0xc040_b340, 0x265e_5a51, 0xe9b6_c7aa,
        0xd62f_105d, 0x0244_1453, 0xd8a1_e681, 0xe7d3_fbc8,
        0x21e1_cde6, 0xc337_07d6, 0xf4d5_0d87, 0x455a_14ed,
        0xa9e3_e905, 0xfcefa_3f8, 0x676f_02d9, 0x8d2a_4c8a,
        0xfffa_3942, 0x8771_f681, 0x6d9d_6122, 0xfde5_380c,
        0xa4be_ea44, 0x4bde_cfa9, 0xf6bb_4b60, 0xbebf_bc70,
        0x289b_7ec6, 0xeaa1_27fa, 0xd4ef_3085, 0x0488_1d05,
        0xd9d4_d039, 0xe6db_99e5, 0x1fa2_7cf8, 0xc4ac_5665,
        0xf429_2244, 0x432a_ff97, 0xab94_23a7, 0xfc93_a039,
        0x655b_59c3, 0x8f0c_cc92, 0xffef_f47d, 0x8584_5dd1,
        0x6fa8_7e4f, 0xfe2c_e6e0, 0xa301_4314, 0x4e08_11a1,
        0xf753_7e82, 0xbd3a_f235, 0x2ad7_d2bb, 0xeb86_d391,
    ]

    /// 处理一个 64 字节消息块。
    private mutating func processBlock() {        var m = [UInt32](repeating: 0, count: 16)
        for index in 0..<16 {
            let base = index * 4
            m[index] = UInt32(block[base])
                | (UInt32(block[base + 1]) << 8)
                | (UInt32(block[base + 2]) << 16)
                | (UInt32(block[base + 3]) << 24)
        }

        var a = state.0
        var b = state.1
        var c = state.2
        var d = state.3

        for index in 0..<64 {
            var f: UInt32
            var g: Int
            switch index {
            case 0..<16:
                f = (b & c) | (~b & d)
                g = index
            case 16..<32:
                f = (d & b) | (~d & c)
                g = (5 * index + 1) % 16
            case 32..<48:
                f = b ^ c ^ d
                g = (3 * index + 5) % 16
            default:
                f = c ^ (b | ~d)
                g = (7 * index) % 16
            }

            f = f &+ a &+ Self.sines[index] &+ m[g]
            // RFC 1321 轮函数：F 用旧的 A/B/C/D 计算，随后
            // newA = oldD, newD = oldC, newC = oldB, newB = oldB + rot(F, s[i])。
            a = d
            d = c
            c = b
            b = b &+ ((f << Self.shifts[index]) | (f >> (32 - Self.shifts[index])))
        }

        state.0 = state.0 &+ a
        state.1 = state.1 &+ b
        state.2 = state.2 &+ c
        state.3 = state.3 &+ d
    }

    /// 一次性计算 MD5（十六进制）。
    public static func hexDigest(of bytes: [UInt8]) -> String {
        Checksum.hexDigest(of: MD5Hasher(), bytes: bytes)
    }
}
