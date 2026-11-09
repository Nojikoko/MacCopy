import Foundation
import CryptoKit

/// SHA-1（CryptoKit 包装）。
///
/// CryptoKit 的 SHA-1 位于 `Insecure` 命名空间（`Insecure.SHA1`），
/// 因为 SHA-1 已不适合安全用途；但它是**内容校验**场景下的合法工具。
public struct SHA1Hasher: ChecksumAlgorithm {
    /// 算法标识。
    public let id: ChecksumAlgorithmID = .sha1
    /// 中文展示名。
    public let displayName = "SHA-1"
    /// 摘要字节长度。
    public let digestLength = 20

    /// CryptoKit 核心。
    private var core = Insecure.SHA1()

    /// 构造 SHA-1 计算器。
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
        core = Insecure.SHA1()
    }

    /// 一次性计算 SHA-1（十六进制）。
    public static func hexDigest(of bytes: [UInt8]) -> String {
        Checksum.hexDigest(of: SHA1Hasher(), bytes: bytes)
    }
}

/// SHA-1 纯 Swift 实现（fallback）。
/// 保留原因：架构 T03 施工步骤 4 要求提供纯 Swift fallback，
/// 且 P2-01 扩展 SHA-224/384/512 时可复用此代码风格。
public struct SHA1PureSwift: ChecksumAlgorithm {
    /// 算法标识。
    public let id: ChecksumAlgorithmID = .sha1
    /// 中文展示名。
    public let displayName = "SHA-1"
    /// 摘要字节长度。
    public let digestLength = 20

    /// 状态向量。
    private var state: (UInt32, UInt32, UInt32, UInt32, UInt32) = (0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0)
    /// 消息块缓冲。
    private var block = [UInt8](repeating: 0, count: 64)
    /// 块内字节数。
    private var blockLength = 0
    /// 总字节数。
    private var totalLength: UInt64 = 0

    /// 构造 SHA-1 计算器。
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

    /// 计算最终摘要（大端序 20 字节）。
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
        digest.reserveCapacity(20)
        for word in [state.0, state.1, state.2, state.3, state.4] {
            digest.append(UInt8((word >> 24) & 0xFF))
            digest.append(UInt8((word >> 16) & 0xFF))
            digest.append(UInt8((word >> 8) & 0xFF))
            digest.append(UInt8(word & 0xFF))
        }
        return digest
    }

    /// 重置。
    public mutating func reset() {
        state = (0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0)
        block = [UInt8](repeating: 0, count: 64)
        blockLength = 0
        totalLength = 0
    }

    /// 处理一个 64 字节块。
    private mutating func processBlock() {
        var w = [UInt32](repeating: 0, count: 80)
        for index in 0..<16 {
            let base = index * 4
            w[index] = (UInt32(block[base]) << 24)
                | (UInt32(block[base + 1]) << 16)
                | (UInt32(block[base + 2]) << 8)
                | UInt32(block[base + 3])
        }
        for index in 16..<80 {
            w[index] = rotateLeft(w[index - 3] ^ w[index - 8] ^ w[index - 14] ^ w[index - 16], 1)
        }

        var a = state.0
        var b = state.1
        var c = state.2
        var d = state.3
        var e = state.4

        for index in 0..<80 {
            let f: UInt32
            let k: UInt32
            switch index {
            case 0..<20:
                f = (b & c) | (~b & d)
                k = 0x5A82_7999
            case 20..<40:
                f = b ^ c ^ d
                k = 0x6ED9_EBA1
            case 40..<60:
                f = (b & c) | (b & d) | (c & d)
                k = 0x8F1B_BCDC
            default:
                f = b ^ c ^ d
                k = 0xCA62_C1D6
            }
            let temp = rotateLeft(a, 5) &+ f &+ e &+ k &+ w[index]
            e = d
            d = c
            c = rotateLeft(b, 30)
            b = a
            a = temp
        }

        state.0 = state.0 &+ a
        state.1 = state.1 &+ b
        state.2 = state.2 &+ c
        state.3 = state.3 &+ d
        state.4 = state.4 &+ e
    }

    /// 32 位左循环移位。
    @inline(__always)
    private func rotateLeft(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value << amount) | (value >> (32 - amount))
    }
}
