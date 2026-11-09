import Foundation

/// 进度聚合：字节 / 文件双口径、瞬时速度（1 s 滑窗）、ETA。
public struct ProgressTracker: Sendable {
    /// 速度采样器。
    private var sampler = SpeedSampler()
    /// 总字节数。
    private var totalBytes: Int64 = 0
    /// 已传输字节数。
    private var transferredBytes: Int64 = 0
    /// 总文件数。
    private var totalFiles: Int = 0
    /// 已完成文件数。
    private var completedFiles: Int = 0
    /// 失败文件数。
    private var failedFiles: Int = 0
    /// 跳过文件数。
    private var skippedFiles: Int = 0

    /// 构造进度追踪器。
    public init() {}

    /// 初始化总量。
    ///
    /// - Parameters:
    ///   - totalBytes: 总字节数。
    ///   - totalFiles: 总文件数。
    public mutating func begin(totalBytes: Int64, totalFiles: Int) {
        self.totalBytes = totalBytes
        self.totalFiles = totalFiles
        self.transferredBytes = 0
        self.completedFiles = 0
        self.failedFiles = 0
        self.skippedFiles = 0
        self.sampler = SpeedSampler()
    }

    /// 累加已传输字节。
    ///
    /// - Parameters:
    ///   - bytes: 本次新增字节数。
    ///   - now: 当前时刻。
    public mutating func addTransferred(bytes: Int64, now: Date = Date()) {
        transferredBytes += bytes
        sampler.sample(bytes: transferredBytes, now: now)
    }

    /// 记录一个文件完成。
    public mutating func completeFile() {
        completedFiles += 1
    }

    /// 记录一个文件失败。
    public mutating func failFile() {
        failedFiles += 1
    }

    /// 记录一个文件跳过。
    public mutating func skipFile() {
        skippedFiles += 1
    }

    /// 生成当前进度快照。
    ///
    /// - Returns: 进度。
    public func snapshot() -> TransferProgress {
        let remaining = max(0, totalBytes - transferredBytes)
        return TransferProgress(
            totalBytes: totalBytes,
            transferredBytes: transferredBytes,
            totalFiles: totalFiles,
            completedFiles: completedFiles,
            failedFiles: failedFiles,
            skippedFiles: skippedFiles,
            bytesPerSecond: sampler.throughput(),
            estimatedRemaining: sampler.eta(remainingBytes: remaining)
        )
    }

    /// 瞬时速度（字节/秒）。
    public var instantaneousSpeed: Double { sampler.instantaneous }

    /// 平均速度（字节/秒）。
    public var averageSpeed: Double { sampler.average }

    /// ETA（秒）。
    public func estimatedRemaining() -> TimeInterval? {
        sampler.eta(remainingBytes: max(0, totalBytes - transferredBytes))
    }
}
