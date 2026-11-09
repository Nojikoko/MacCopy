import Foundation

/// CRC32（IEEE 802.3 多项式 0xEDB88320），slice-by-8 实现。
///
/// 性能：8 张 256 项查表，每张 1 KiB，共 8 KiB，静态 `let` 一次性生成。
/// slice-by-8 每 8 字节处理一次，比逐字节表查快约 8 倍。
public struct CRC32Hasher: ChecksumAlgorithm {
    /// 算法标识。
    public let id: ChecksumAlgorithmID = .crc32
    /// 中文展示名。
    public let displayName = "CRC32"
    /// 摘要字节长度。
    public let digestLength = 4

    /// 当前 CRC 寄存器值。
    private var crc: UInt32 = 0xFFFF_FFFF
    /// 已处理的字节总数（用于 finalize 时补齐末尾 0）。
    private var byteCount: UInt64 = 0

    /// 构造 CRC32 计算器。
    public init() {
        reset()
    }

    /// 追加数据。
    public mutating func update(buffer: UnsafeRawBufferPointer) {
        guard !buffer.isEmpty else { return }
        byteCount &+= UInt64(buffer.count)

        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            crc = CRC32Table.update(crc: crc, base: base, count: raw.count)
        }
    }

    /// 计算最终摘要（大端序 4 字节）。
    public mutating func finalize() -> [UInt8] {
        let value = crc ^ 0xFFFF_FFFF
        return [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
    }

    /// 重置。
    public mutating func reset() {
        crc = 0xFFFF_FFFF
        byteCount = 0
    }

    /// 一次性计算 CRC32（十六进制）。
    public static func hexDigest(of bytes: [UInt8]) -> String {
        Checksum.hexDigest(of: CRC32Hasher(), bytes: bytes)
    }
}

/// CRC32 slice-by-8 查表。
enum CRC32Table {
    /// IEEE 802.3 反转多项式。
    static let polynomial: UInt32 = 0xEDB8_8320

    /// 8 张表，每张 256 项。
    ///
    /// 生成规则（标准 slice-by-8）：
    /// - T[0][i]：单字节 i 的 CRC 表项
    /// - T[k][i] = T[0][T[k-1][i] & 0xFF] ^ (T[k-1][i] >> 8)
    ///
    /// 注意：递推时查的必须是**基础表 T[0]**，不是 T[k-1]，
    /// 否则会算错（这是 slice-by-8 实现最容易踩的坑）。
    static let tables: [[UInt32]] = {
        var all = [[UInt32]]()
        all.reserveCapacity(8)

        // 基础表 T[0]。
        var base = [UInt32](repeating: 0, count: 256)
        for index in 0..<256 {
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) != 0 ? (value >> 1) ^ polynomial : value >> 1
            }
            base[index] = value
        }
        all.append(base)

        // 派生表 T[1] … T[7]。
        for _ in 1..<8 {
            var table = [UInt32](repeating: 0, count: 256)
            let previous = all[all.count - 1]
            for index in 0..<256 {
                let previousValue = previous[index]
                table[index] = base[Int(previousValue & 0xFF)] ^ (previousValue >> 8)
            }
            all.append(table)
        }
        return all
    }()

    /// slice-by-8 主循环。
    ///
    /// - Parameters:
    ///   - crc: 当前寄存器值。
    ///   - base: 输入字节基址。
    ///   - count: 字节数。
    /// - Returns: 更新后的寄存器值。
    @inline(__always)
    static func update(crc: UInt32, base: UnsafeRawPointer, count: Int) -> UInt32 {
        var value = crc
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var offset = 0

        // 主循环：每次处理 8 字节。
        let table0 = tables[0]
        let table1 = tables[1]
        let table2 = tables[2]
        let table3 = tables[3]
        let table4 = tables[4]
        let table5 = tables[5]
        let table6 = tables[6]
        let table7 = tables[7]

        while offset + 8 <= count {
            let b0 = UInt32(bytes[offset])
            let b1 = UInt32(bytes[offset + 1])
            let b2 = UInt32(bytes[offset + 2])
            let b3 = UInt32(bytes[offset + 3])
            let b4 = UInt32(bytes[offset + 4])
            let b5 = UInt32(bytes[offset + 5])
            let b6 = UInt32(bytes[offset + 6])
            let b7 = UInt32(bytes[offset + 7])

            value ^= b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
            value = table7[Int(value & 0xFF)]
                ^ table6[Int((value >> 8) & 0xFF)]
                ^ table5[Int((value >> 16) & 0xFF)]
                ^ table4[Int((value >> 24) & 0xFF)]
                ^ table3[Int(b4)]
                ^ table2[Int(b5)]
                ^ table1[Int(b6)]
                ^ table0[Int(b7)]
            offset += 8
        }

        // 尾部：逐字节处理（不足 8 字节）。
        while offset < count {
            value = table0[Int((value ^ UInt32(bytes[offset])) & 0xFF)] ^ (value >> 8)
            offset += 1
        }

        return value
    }
}
