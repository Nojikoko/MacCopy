import Foundation

/// 通用增量 hasher 骨架（架构 §2.2 `M/Checksum/Hasher.swift`）。
///
/// 提供对任意 `ChecksumAlgorithm` 的统一封装，让调用方不必直接依赖协议实现细节。
public struct Hasher: Sendable {
    /// 底层算法实现。
    private var algorithm: any ChecksumAlgorithm

    /// 构造 hasher。
    ///
    /// - Parameter algorithm: 底层算法实例。
    public init(_ algorithm: any ChecksumAlgorithm) {
        self.algorithm = algorithm
    }

    /// 用注册表按 ID 构造 hasher。
    ///
    /// - Parameters:
    ///   - id: 算法标识。
    ///   - registry: 算法注册表，默认使用全局共享实例。
    public init(_ id: ChecksumAlgorithmID, registry: ChecksumRegistry = .shared) {
        self.algorithm = registry.make(id)
    }

    /// 算法标识。
    public var id: ChecksumAlgorithmID { algorithm.id }

    /// 中文展示名。
    public var displayName: String { algorithm.displayName }

    /// 摘要字节长度。
    public var digestLength: Int { algorithm.digestLength }

    /// 追加数据。
    public mutating func update(buffer: UnsafeRawBufferPointer) {
        algorithm.update(buffer: buffer)
    }

    /// 追加 `Data`。
    public mutating func update(data: Data) {
        data.withUnsafeBytes { buffer in
            algorithm.update(buffer: UnsafeRawBufferPointer(buffer))
        }
    }

    /// 追加字节数组。
    public mutating func update(bytes: [UInt8]) {
        bytes.withUnsafeBytes { buffer in
            algorithm.update(buffer: UnsafeRawBufferPointer(buffer))
        }
    }

    /// 计算最终摘要（十六进制）。
    public mutating func finalizeHex() -> String {
        Bytes.hexString(algorithm.finalize())
    }

    /// 计算最终摘要。
    public mutating func finalize() -> [UInt8] {
        algorithm.finalize()
    }

    /// 重置。
    public mutating func reset() {
        algorithm.reset()
    }
}
