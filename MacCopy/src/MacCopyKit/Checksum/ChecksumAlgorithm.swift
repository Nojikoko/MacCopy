import Foundation

/// 可增量更新的摘要计算器（架构 §3.2.2）。
///
/// 性能要点：`update` 接收 `UnsafeRawBufferPointer` 而非 `Data`，
/// 避免每次调用产生一次内存拷贝。
public protocol ChecksumAlgorithm: Sendable {
    /// 算法标识。
    var id: ChecksumAlgorithmID { get }
    /// 中文展示名。
    var displayName: String { get }
    /// 摘要字节长度。
    var digestLength: Int { get }

    /// 追加数据。
    mutating func update(buffer: UnsafeRawBufferPointer)
    /// 计算最终摘要。调用后实现应进入终态（需先 `reset` 才能复用）。
    mutating func finalize() -> [UInt8]
    /// 重置为初始状态。
    mutating func reset()
}

extension ChecksumAlgorithm {
    /// 追加 `Data` 的便捷方法。
    public mutating func update(data: Data) {
        data.withUnsafeBytes { buffer in
            update(buffer: UnsafeRawBufferPointer(buffer))
        }
    }

    /// 追加字节数组的便捷方法。
    public mutating func update(bytes: [UInt8]) {
        bytes.withUnsafeBytes { buffer in
            update(buffer: UnsafeRawBufferPointer(buffer))
        }
    }
}

/// 校验算法的便捷工具。
public enum Checksum {
    /// 计算摘要（一次性）。
    ///
    /// - Parameters:
    ///   - algorithm: 算法实例。
    ///   - bytes: 待摘要的字节。
    /// - Returns: 摘要字节。
    public static func digest(of algorithm: any ChecksumAlgorithm, bytes: [UInt8]) -> [UInt8] {
        var hasher = algorithm
        hasher.update(bytes: bytes)
        return hasher.finalize()
    }

    /// 计算摘要（一次性，十六进制）。
    ///
    /// - Parameters:
    ///   - algorithm: 算法实例。
    ///   - bytes: 待摘要的字节。
    /// - Returns: 十六进制摘要。
    public static func hexDigest(of algorithm: any ChecksumAlgorithm, bytes: [UInt8]) -> String {
        Bytes.hexString(digest(of: algorithm, bytes: bytes))
    }
}

/// 算法注册表。v1 内置 5 种；P2-01 走同一注册机制扩展。
public struct ChecksumRegistry: Sendable {
    /// 全局共享注册表。
    public static let shared = ChecksumRegistry()

    /// 算法工厂表。
    private var factories: [ChecksumAlgorithmID: @Sendable () -> any ChecksumAlgorithm]

    /// 构造注册表（内置全部 v1 算法）。
    public init() {
        factories = [
            .crc32:  { CRC32Hasher() },
            .md5:    { MD5Hasher() },
            .sha1:   { SHA1Hasher() },
            .sha256: { SHA256Hasher() },
            .blake3: { BLAKE3Hasher() },
        ]
    }

    /// 用自定义工厂构造注册表。
    public init(factories: [ChecksumAlgorithmID: @Sendable () -> any ChecksumAlgorithm]) {
        self.factories = factories
    }

    /// 创建指定算法的实例。
    ///
    /// - Parameter id: 算法标识。
    /// - Returns: 算法实例。
    public func make(_ id: ChecksumAlgorithmID) -> any ChecksumAlgorithm {
        guard let factory = factories[id] else {
            preconditionFailure("未注册的校验算法：\(id.rawValue)")
        }
        return factory()
    }

    /// 已注册的算法列表（按 rawValue 排序）。
    public var available: [ChecksumAlgorithmID] {
        factories.keys.sorted { $0.rawValue < $1.rawValue }
    }

    /// 注册（或覆盖）一个算法。
    ///
    /// - Parameters:
    ///   - id: 算法标识。
    ///   - factory: 算法工厂。
    public mutating func register(_ id: ChecksumAlgorithmID, factory: @escaping @Sendable () -> any ChecksumAlgorithm) {
        factories[id] = factory
    }
}
