import Foundation

/// 校验结果（架构 §3.2.1）。
public struct VerificationResult: Sendable, Codable, Equatable {
    /// 对应的文件条目 ID。
    public let fileID: UUID
    /// 使用的算法。
    public let algorithm: ChecksumAlgorithmID
    /// 校验状态。
    public let status: VerificationStatus
    /// 期望值（源侧摘要，十六进制）。
    public let expected: String?
    /// 实际值（目标侧摘要，十六进制）。
    public let actual: String?
    /// 首个差异字节偏移。
    public let firstDifferenceOffset: Int64?
    /// 差异上下文（前后各 16 字节）。
    public let differenceContext: [UInt8]?
    /// 耗时（秒）。
    public let duration: TimeInterval

    /// 构造校验结果。
    public init(
        fileID: UUID,
        algorithm: ChecksumAlgorithmID,
        status: VerificationStatus,
        expected: String? = nil,
        actual: String? = nil,
        firstDifferenceOffset: Int64? = nil,
        differenceContext: [UInt8]? = nil,
        duration: TimeInterval = 0
    ) {
        self.fileID = fileID
        self.algorithm = algorithm
        self.status = status
        self.expected = expected
        self.actual = actual
        self.firstDifferenceOffset = firstDifferenceOffset
        self.differenceContext = differenceContext
        self.duration = duration
    }

    /// 是否通过（`notVerified` 不算通过）。
    public var isPassed: Bool { status == .passed }
}
