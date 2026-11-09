import Foundation

/// 复制任务定义：源/目标、冲突策略、校验配置、线程数、任务状态。
public struct TransferTask: Sendable, Codable, Identifiable, Equatable {
    /// 任务唯一标识。
    public let id: UUID
    /// 源根路径列表。
    public let sourceRoots: [String]
    /// 目标根路径。
    public let destinationRoot: String
    /// 传输配置。
    public let options: TransferOptions
    /// 创建时间。
    public let createdAt: Date
    /// 当前状态。
    public var state: TaskState

    /// 构造任务。
    public init(
        id: UUID = UUID(),
        sourceRoots: [String],
        destinationRoot: String,
        options: TransferOptions = .default,
        createdAt: Date = Date(),
        state: TaskState = .pending
    ) {
        self.id = id
        self.sourceRoots = sourceRoots
        self.destinationRoot = destinationRoot
        self.options = options
        self.createdAt = createdAt
        self.state = state
    }
}

/// 任务级进度快照（字节口径 + 文件口径）。
public struct TransferProgress: Sendable, Codable, Equatable {
    /// 总字节数。
    public var totalBytes: Int64
    /// 已传输字节数。
    public var transferredBytes: Int64
    /// 总文件数。
    public var totalFiles: Int
    /// 已完成文件数。
    public var completedFiles: Int
    /// 失败文件数。
    public var failedFiles: Int
    /// 跳过文件数。
    public var skippedFiles: Int
    /// 瞬时速度（字节/秒）。
    public var bytesPerSecond: Double
    /// 预计剩余时间（秒），nil 表示无法估算。
    public var estimatedRemaining: TimeInterval?

    /// 构造进度。
    public init(
        totalBytes: Int64 = 0,
        transferredBytes: Int64 = 0,
        totalFiles: Int = 0,
        completedFiles: Int = 0,
        failedFiles: Int = 0,
        skippedFiles: Int = 0,
        bytesPerSecond: Double = 0,
        estimatedRemaining: TimeInterval? = nil
    ) {
        self.totalBytes = totalBytes
        self.transferredBytes = transferredBytes
        self.totalFiles = totalFiles
        self.completedFiles = completedFiles
        self.failedFiles = failedFiles
        self.skippedFiles = skippedFiles
        self.bytesPerSecond = bytesPerSecond
        self.estimatedRemaining = estimatedRemaining
    }

    /// 字节口径完成比例（0…1）。
    public var byteFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, Double(transferredBytes) / Double(totalBytes))
    }

    /// 文件口径完成比例（0…1）。
    public var fileFraction: Double {
        guard totalFiles > 0 else { return 0 }
        return min(1.0, Double(completedFiles + failedFiles + skippedFiles) / Double(totalFiles))
    }
}

/// 单文件处理结果。
public struct FileOutcome: Sendable, Codable, Equatable {
    /// 文件条目 ID。
    public let fileID: UUID
    /// 最终状态。
    public let status: FileStatus
    /// 目标路径。
    public let destinationPath: String?
    /// 实际传输字节数。
    public let bytesTransferred: Int64
    /// 是否使用了 APFS 克隆。
    public let wasCloned: Bool
    /// 耗时（秒）。
    public let duration: TimeInterval
    /// 校验结果列表。
    public let verificationResults: [VerificationResult]
    /// 失败时的错误。
    public let error: MacCopyError?

    /// 构造文件结果。
    public init(
        fileID: UUID,
        status: FileStatus,
        destinationPath: String? = nil,
        bytesTransferred: Int64 = 0,
        wasCloned: Bool = false,
        duration: TimeInterval = 0,
        verificationResults: [VerificationResult] = [],
        error: MacCopyError? = nil
    ) {
        self.fileID = fileID
        self.status = status
        self.destinationPath = destinationPath
        self.bytesTransferred = bytesTransferred
        self.wasCloned = wasCloned
        self.duration = duration
        self.verificationResults = verificationResults
        self.error = error
    }
}

/// 任务结束汇总。
public struct TransferSummary: Sendable, Codable, Equatable {
    /// 任务 ID。
    public let taskID: UUID
    /// 成功文件数。
    public let succeededCount: Int
    /// 失败文件数。
    public let failedCount: Int
    /// 跳过文件数。
    public let skippedCount: Int
    /// 总字节数。
    public let totalBytes: Int64
    /// 实际传输字节数。
    public let transferredBytes: Int64
    /// 总耗时（秒）。
    public let duration: TimeInterval
    /// 校验降级次数（Q5：必须可见）。
    public let degradedCount: Int

    /// 构造汇总。
    public init(
        taskID: UUID,
        succeededCount: Int,
        failedCount: Int,
        skippedCount: Int,
        totalBytes: Int64,
        transferredBytes: Int64,
        duration: TimeInterval,
        degradedCount: Int = 0
    ) {
        self.taskID = taskID
        self.succeededCount = succeededCount
        self.failedCount = failedCount
        self.skippedCount = skippedCount
        self.totalBytes = totalBytes
        self.transferredBytes = transferredBytes
        self.duration = duration
        self.degradedCount = degradedCount
    }
}

/// 断点续传令牌（UI 用于提示「可恢复」）。
public struct ResumeToken: Sendable, Codable, Equatable {
    /// 任务 ID。
    public let taskID: UUID
    /// 文件条目 ID。
    public let fileID: UUID
    /// 已传输字节数。
    public let bytesTransferred: Int64
    /// 分片文件路径。
    public let partialPath: String

    /// 构造断点令牌。
    public init(taskID: UUID, fileID: UUID, bytesTransferred: Int64, partialPath: String) {
        self.taskID = taskID
        self.fileID = fileID
        self.bytesTransferred = bytesTransferred
        self.partialPath = partialPath
    }
}

/// 任务快照（供 UI 首次渲染与状态查询）。
public struct TransferTaskSnapshot: Sendable, Codable, Equatable {
    /// 任务 ID。
    public let taskID: UUID
    /// 任务定义。
    public let task: TransferTask
    /// 当前进度。
    public let progress: TransferProgress
    /// 结束汇总（未结束为 nil）。
    public let summary: TransferSummary?

    /// 构造快照。
    public init(taskID: UUID, task: TransferTask, progress: TransferProgress, summary: TransferSummary? = nil) {
        self.taskID = taskID
        self.task = task
        self.progress = progress
        self.summary = summary
    }
}
