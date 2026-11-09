import Foundation
import Darwin

/// 校验编排器。
///
/// 架构 §5 / PRD P0-04 / Q5：
/// - **tee 校验**：边复制边算哈希（流式路径，单遍）
/// - **回读校验**：复制完成后回读源/目标比对（克隆路径必须用这个，因为克隆没有 tee）
/// - **降级判定**（Q5）：源不可寻址 **且** tee 不可用时，
///   校验状态为 `.notVerified`，**UI 必须显著警示，不可静默通过**
public struct Verifier: Sendable {
    /// 校验结论。
    public struct Conclusion: Sendable, Equatable {
        /// 校验状态。
        public let status: VerificationStatus
        /// 是否发生了降级（未做内容哈希）。
        public let isDegraded: Bool
        /// 降级原因（降级时非空）。
        public let reason: String?
        /// 各算法的结果。
        public let results: [VerificationResult]

        /// 构造结论。
        public init(
            status: VerificationStatus,
            isDegraded: Bool,
            reason: String?,
            results: [VerificationResult]
        ) {
            self.status = status
            self.isDegraded = isDegraded
            self.reason = reason
            self.results = results
        }

        /// 全部通过（降级**不算**通过）。
        public var isPassed: Bool {
            status == .passed && !isDegraded
        }
    }

    /// 校验器。
    private let registry: ChecksumRegistry

    /// 构造校验器。
    ///
    /// - Parameter registry: 算法注册表（默认全局共享）。
    public init(registry: ChecksumRegistry = .shared) {
        self.registry = registry
    }

    /// 对已计算好的摘要做比对（tee 路径）。
    ///
    /// - Parameters:
    ///   - fileID: 文件条目 ID。
    ///   - expected: 源侧摘要。
    ///   - actual: 目标侧摘要。
    /// - Returns: 校验结论。
    public func compare(
        fileID: UUID,
        expected: [ChecksumAlgorithmID: String],
        actual: [ChecksumAlgorithmID: String]
    ) -> Conclusion {
        var results = [VerificationResult]()
        var hasFailure = false
        let degradedReason: String? = nil

        for algorithm in expected.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let expectedValue = expected[algorithm] ?? ""
            let actualValue = actual[algorithm] ?? ""
            let matched = expectedValue == actualValue
            if !matched { hasFailure = true }

            results.append(
                VerificationResult(
                    fileID: fileID,
                    algorithm: algorithm,
                    status: matched ? .passed : .failed,
                    expected: expectedValue,
                    actual: actualValue,
                    duration: 0
                )
            )
        }

        if results.isEmpty {
            // 没有任何算法 → 未做内容哈希。
            return Conclusion(
                status: .notVerified,
                isDegraded: true,
                reason: Localization.string(
                    "verification.degraded.noAlgorithm",
                    default: "未选择任何校验算法，本次复制未做内容哈希校验"
                ),
                results: results
            )
        }

        return Conclusion(
            status: hasFailure ? .failed : .passed,
            isDegraded: false,
            reason: degradedReason,
            results: results
        )
    }

    /// 回读校验（克隆路径必须用这个）。
    ///
    /// 流程：回读源算摘要 → 回读目标算摘要 → 比对。
    ///
    /// - Parameters:
    ///   - fileID: 文件条目 ID。
    ///   - sourcePath: 源路径。
    ///   - destinationPath: 目标路径。
    ///   - algorithms: 算法集合。
    ///   - bufferSize: 读缓冲大小。
    /// - Returns: 校验结论。
    public func verifyByReadBack(
        fileID: UUID,
        sourcePath: String,
        destinationPath: String,
        algorithms: Set<ChecksumAlgorithmID>,
        bufferSize: Int = 1024 * 1024
    ) -> Conclusion {
        guard !algorithms.isEmpty else {
            return Conclusion(
                status: .notVerified,
                isDegraded: true,
                reason: Localization.string(
                    "verification.degraded.noAlgorithm",
                    default: "未选择任何校验算法，本次复制未做内容哈希校验"
                ),
                results: []
            )
        }

        let start = Date()
        let sourceDigests = Self.digest(
            of: sourcePath,
            algorithms: algorithms,
            registry: registry,
            bufferSize: bufferSize
        )
        let destinationDigests = Self.digest(
            of: destinationPath,
            algorithms: algorithms,
            registry: registry,
            bufferSize: bufferSize
        )

        var conclusion = compare(
            fileID: fileID,
            expected: sourceDigests,
            actual: destinationDigests
        )
        // 补上耗时。
        let duration = Date().timeIntervalSince(start)
        let results = conclusion.results.map { result in
            VerificationResult(
                fileID: result.fileID,
                algorithm: result.algorithm,
                status: result.status,
                expected: result.expected,
                actual: result.actual,
                firstDifferenceOffset: result.firstDifferenceOffset,
                differenceContext: result.differenceContext,
                duration: duration
            )
        }
        conclusion = Conclusion(
            status: conclusion.status,
            isDegraded: conclusion.isDegraded,
            reason: conclusion.reason,
            results: results
        )
        return conclusion
    }

    /// 判定是否降级（Q5）。
    ///
    /// 降级条件：**源不可寻址** 且 **tee 不可用**（即克隆路径且无法回读源）。
    ///
    /// - Parameters:
    ///   - sourceIsSeekable: 源是否可寻址。
    ///   - teeEnabled: 是否走了 tee 路径。
    ///   - readBackSucceeded: 回读是否成功。
    /// - Returns: 降级结论（未降级返回 nil）。
    public static func degradationReason(
        sourceIsSeekable: Bool,
        teeEnabled: Bool,
        readBackSucceeded: Bool
    ) -> String? {
        if teeEnabled { return nil }
        if !sourceIsSeekable && !readBackSucceeded {
            return Localization.string(
                "verification.degraded.sourceNotSeekable",
                default: "源文件不可寻址且无法回读校验，本次复制未做内容哈希校验"
            )
        }
        if !readBackSucceeded {
            return Localization.string(
                "verification.degraded.readBackFailed",
                default: "回读校验失败，本次复制未做内容哈希校验"
            )
        }
        return nil
    }

    /// 计算文件的摘要（回读）。
    ///
    /// - Parameters:
    ///   - path: 文件路径。
    ///   - algorithms: 算法集合。
    ///   - registry: 算法注册表。
    ///   - bufferSize: 读缓冲大小。
    /// - Returns: 摘要字典。
    public static func digest(
        of path: String,
        algorithms: Set<ChecksumAlgorithmID>,
        registry: ChecksumRegistry,
        bufferSize: Int
    ) -> [ChecksumAlgorithmID: String] {
        guard !algorithms.isEmpty else { return [:] }

        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return [:] }
        defer { close(fd) }

        var hasher = MultiHasher(algorithms: Array(algorithms), registry: registry)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 64)
        defer { buffer.deallocate() }

        while true {
            let count = buffer.withMemoryRebound(to: UInt8.self, capacity: bufferSize) { pointer in
                Syscall.resetErrno()
                return read(fd, pointer, bufferSize)
            }
            if count <= 0 { break }
            hasher.update(buffer: UnsafeRawBufferPointer(start: buffer, count: count))
        }

        return hasher.finalizeHex()
    }
}
