import Foundation

/// 一次数据更新，多算法并行计算。避免为每个算法各读一遍文件。
///
/// 性能注意：`[any ChecksumAlgorithm]` 存在**存在类型（existential）的动态派发开销**。
/// 在 8 MiB 缓冲下开销可忽略（每 8 MiB 才 1 次派发），**不要**为了消除它而牺牲可扩展性。
public struct MultiHasher: Sendable {
    /// 参与计算的算法实例。
    private var hashers: [any ChecksumAlgorithm]

    /// 构造多算法计算器。
    ///
    /// - Parameters:
    ///   - algorithms: 算法标识集合。
    ///   - registry: 算法注册表，默认使用全局共享实例。
    public init(algorithms: [ChecksumAlgorithmID], registry: ChecksumRegistry = .shared) {
        self.hashers = algorithms.map { registry.make($0) }
    }

    /// 参与计算的算法标识。
    public var algorithmIDs: [ChecksumAlgorithmID] {
        hashers.map(\.id)
    }

    /// 追加数据到所有算法。
    public mutating func update(buffer: UnsafeRawBufferPointer) {
        for index in hashers.indices {
            hashers[index].update(buffer: buffer)
        }
    }

    /// 追加 `Data` 到所有算法。
    public mutating func update(data: Data) {
        data.withUnsafeBytes { buffer in
            update(buffer: UnsafeRawBufferPointer(buffer))
        }
    }

    /// 追加字节数组到所有算法。
    public mutating func update(bytes: [UInt8]) {
        bytes.withUnsafeBytes { buffer in
            update(buffer: UnsafeRawBufferPointer(buffer))
        }
    }

    /// 计算所有算法的最终摘要。
    public mutating func finalize() -> [ChecksumAlgorithmID: [UInt8]] {
        var result = [ChecksumAlgorithmID: [UInt8]]()
        for index in hashers.indices {
            result[hashers[index].id] = hashers[index].finalize()
        }
        return result
    }

    /// 计算所有算法的最终摘要（十六进制）。
    public mutating func finalizeHex() -> [ChecksumAlgorithmID: String] {
        var result = [ChecksumAlgorithmID: String]()
        for index in hashers.indices {
            result[hashers[index].id] = Bytes.hexString(hashers[index].finalize())
        }
        return result
    }

    /// 重置所有算法。
    public mutating func reset() {
        for index in hashers.indices {
            hashers[index].reset()
        }
    }
}
