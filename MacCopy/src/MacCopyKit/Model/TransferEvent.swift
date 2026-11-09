import Foundation

/// 引擎 → UI 的单向事件。UI 只消费，不反向调用（架构 §8.6）。
public enum TransferEvent: Sendable {
    /// 任务状态迁移。
    case taskStateChanged(taskID: UUID, state: TaskState)
    /// 全局进度更新（1 Hz 节流）。
    case progress(taskID: UUID, progress: TransferProgress)
    /// 单文件状态迁移。
    case fileStatusChanged(taskID: UUID, fileID: UUID, status: FileStatus)
    /// 单文件完成。
    case fileCompleted(taskID: UUID, fileID: UUID, result: FileOutcome)
    /// 单文件失败（含中文原因）。
    case fileFailed(taskID: UUID, fileID: UUID, error: MacCopyError, attempt: Int)
    /// 校验结果。
    case verification(taskID: UUID, result: VerificationResult)
    /// 校验降级警示（Q5：「未做内容哈希」必须可见）。
    case verificationDegraded(taskID: UUID, fileID: UUID, reason: String)
    /// 任务结束。
    case taskFinished(taskID: UUID, summary: TransferSummary)
    /// 可恢复提示（断点元数据已保存）。
    case resumable(taskID: UUID, resumeToken: ResumeToken)

    /// 事件所属的任务 ID（用于按任务过滤）。
    public var taskID: UUID {
        switch self {
        case .taskStateChanged(let id, _),
             .progress(let id, _),
             .fileStatusChanged(let id, _, _),
             .fileCompleted(let id, _, _),
             .fileFailed(let id, _, _, _),
             .verification(let id, _),
             .verificationDegraded(let id, _, _),
             .taskFinished(let id, _),
             .resumable(let id, _):
            return id
        }
    }
}
