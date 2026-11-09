import Foundation
import CryptoKit

/// SHA-256（CryptoKit 包装，有 SHA-NI 硬件加速）。
public struct SHA256Hasher: ChecksumAlgorithm {
    /// 算法标识。
    public let id: ChecksumAlgorithmID = .sha256
    /// 中文展示名。
    public let displayName = "SHA-256"
    /// 摘要字节长度。
    public let digestLength = 32

    /// CryptoKit 核心。
    private var core = SHA256()

    /// 构造 SHA-256 计算器。
    public init() {
        reset()
    }

    /// 追加数据。
    public mutating func update(buffer: UnsafeRawBufferPointer) {
        guard !buffer.isEmpty else { return }
        // `Data(_:)` 会拷贝一次；8 MiB 缓冲下相对 SHA 计算可忽略。
        core.update(data: Data(buffer))
    }

    /// 计算最终摘要。
    public mutating func finalize() -> [UInt8] {
        Array(core.finalize())
    }

    /// 重置。
    public mutating func reset() {
        core = SHA256()
    }

    /// 一次性计算 SHA-256（十六进制）。
    public static func hexDigest(of bytes: [UInt8]) -> String {
        Checksum.hexDigest(of: SHA256Hasher(), bytes: bytes)
    }
}

/// SHA-256 纯 Swift 实现（fallback）。
///
/// 保留原因同 ``SHA1PureSwift``：P2-01 扩展 SHA-224/384/512 时可复用此代码风格。
public struct SHA256PureSwift: ChecksumAlgorithm {
    /// 算法标识。
    public let id: ChecksumAlgorithmID = .sha256
    /// 中文展示名。
    public let displayName = "SHA-256"
    /// 摘要字节长度。
    public let digestLength = 32

    /// 状态向量。
    private var state: [UInt32] = [
        0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A,
        0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19,
    ]
    /// 消息块缓冲。
    private var block = [UInt8](repeating: 0, count: 64)
    /// 块内字节数。
    private var blockLength = 0
    /// 总字节数。
    private var totalLength: UInt64 = 0

    /// 构造 SHA-256 计算器。
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
            if blockLength > 0 {
                let take = min(64 - blockLength, raw.count)
                for index in 0..<take { block[blockLength + index] = bytes[offset + index] }
                blockLength += take
                offset += take
                if blockLength == 64 { processBlock(); blockLength = 0 }
            }
            while offset + 64 <= raw.count {
                for index in 0..<64 { block[index] = bytes[offset + index] }
                processBlock()
                offset += 64
            }
            if offset < raw.count {
                let remaining = raw.count - offset
                for index in 0..<remaining { block[index] = bytes[offset + index] }
                blockLength = remaining
            }
        }
    }

    /// 计算最终摘要（大端序 32 字节）。
    public mutating func finalize() -> [UInt8] {
        let bitLength = totalLength &* 8
        var padding = [UInt8]()
        padding.reserveCapacity(72)
        padding.append(0x80)
        let remainder = Int((totalLength &+ 1) % 64)
        let zeroCount = remainder <= 56 ? 56 - remainder : 120 - remainder
        padding.append(contentsOf: [UInt8](repeating: 0, count: zeroCount))
        for index in 0..<8 {
            // 大端序：byte[0] 是最高 8 位。
            padding.append(UInt8((bitLength >> (8 * UInt64(7 - index))) & 0xFF))
        }
        padding.withUnsafeBytes { raw in
            update(buffer: raw)
        }

        var digest = [UInt8]()
        digest.reserveCapacity(32)
        for word in state {
            digest.append(UInt8((word >> 24) & 0xFF))
            digest.append(UInt8((word >> 16) & 0xFF))
            digest.append(UInt8((word >> 8) & 0xFF))
            digest.append(UInt8(word & 0xFF))
        }
        return digest
    }

    /// 重置。
    public mutating func reset() {
        state = [
            0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A,
            0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19,
        ]
        block = [UInt8](repeating: 0, count: 64)
        blockLength = 0
        totalLength = 0
    }

    /// 64 个轮常量。
    private static let constants: [UInt32] = [
        0x428A_2F98, 0x7137_4491, 0xB5C0_FBCF, 0xE9B5_DBA5,
        0x3956_C25B, 0x59F1_11F1, 0x923F_82A4, 0xAB1C_5ED5,
        0xD807_AA98, 0x1283_5B01, 0x2431_85BE, 0x550C_7DC3,
        0x72BE_5D74, 0x80DE_B1FE, 0x9BDC_06A7, 0xC19B_F174,
        0xE49B_69C1, 0xEFBE_4786, 0x0FC1_9DC6, 0x240C_A1CC,
        0x2DE9_2C6F, 0x4A74_84AA, 0x5CB0_A9DC, 0x76F9_88DA,
        0x983E_5152, 0xA831_C66D, 0xB003_27C8, 0xBF59_7FC7,
        0xC6E0_0BF3, 0xD5A7_9147, 0x06CA_6351, 0x1429_2967,
        0x27B7_0A85, 0x2E1B_2138, 0x4D2C_6DFC, 0x5338_0D13,
        0x650A_7354, 0x766A_0ABB, 0x81C2_C92E, 0x9272_2C85,
        0xA2BF_E8A1, 0xA81A_664B, 0xC24B_8B70, 0xC76C_51A3,
        0xD192_E819, 0xD699_0624, 0xF40E_3585, 0x106A_A070,
        0x19A4_C116, 0x1E37_6C08, 0x2748_774C, 0x34B0_BCB5,
        0x391C_0CB3, 0x4ED8_AA4A, 0x5B9C_CA4F, 0x682E_6FF3,
        0x748F_82EE, 0x78A5_636F, 0x84C8_7814, 0x8CC7_0208,
        0x90BE_FFFA, 0xA450_6CEB, 0xBEF9_A3F7, 0xC671_78F2,
    ]

    /// 处理一个 64 字节块。
    private mutating func processBlock() {
        var w = [UInt32](repeating: 0, count: 64)
        for index in 0..<16 {
            let base = index * 4
            w[index] = (UInt32(block[base]) << 24)
                | (UInt32(block[base + 1]) << 16)
                | (UInt32(block[base + 2]) << 8)
                | UInt32(block[base + 3])
        }
        for index in 16..<64 {
            let s0 = rotateRight(w[index - 15], 7) ^ rotateRight(w[index - 15], 18) ^ (w[index - 15] >> 3)
            let s1 = rotateRight(w[index - 2], 17) ^ rotateRight(w[index - 2], 19) ^ (w[index - 2] >> 10)
            w[index] = w[index - 16] &+ s0 &+ w[index - 7] &+ s1
        }

        var a = state[0]
        var b = state[1]
        var c = state[2]
        var d = state[3]
        var e = state[4]
        var f = state[5]
        var g = state[6]
        var h = state[7]

        for index in 0..<64 {
            let s1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
            let ch = (e & f) ^ (~e & g)
            let temp1 = h &+ s1 &+ ch &+ Self.constants[index] &+ w[index]
            let s0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = s0 &+ maj

            h = g
            g = f
            f = e
            e = d &+ temp1
            d = c
            c = b
            b = a
            a = temp1 &+ temp2
        }

        state[0] = state[0] &+ a
        state[1] = state[1] &+ b
        state[2] = state[2] &+ c
        state[3] = state[3] &+ d
        state[4] = state[4] &+ e
        state[5] = state[5] &+ f
        state[6] = state[6] &+ g
        state[7] = state[7] &+ h
    }

    /// 32 位右循环移位。
    @inline(__always)
    private func rotateRight(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }
}
