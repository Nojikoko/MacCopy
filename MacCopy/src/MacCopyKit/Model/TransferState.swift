import Foundation

/// 任务级状态。文件级状态见 ``FileStatus``。
public enum TaskState: String, Sendable, Codable, CaseIterable {
    /// 待执行
    case pending
    /// 执行中
    case running
    /// 已暂停
    case paused
    /// 全部成功
    case succeeded
    /// 部分失败
    case partialFailed
    /// 已取消
    case cancelled

    /// 是否为终态（不可再迁移）。
    public var isTerminal: Bool {
        switch self {
        case .succeeded, .partialFailed, .cancelled:
            return true
        case .pending, .running, .paused:
            return false
        }
    }

    /// 任务级状态迁移表（架构 §3.1）。
    public static let allowedTransitions: [TaskState: Set<TaskState>] = [
        .pending: [.running, .cancelled],
        .running: [.paused, .succeeded, .partialFailed, .cancelled],
        .paused: [.running, .cancelled],
        .succeeded: [],
        .partialFailed: [],
        .cancelled: [],
    ]

    /// 判断迁移是否合法。
    public func canTransition(to next: TaskState) -> Bool {
        Self.allowedTransitions[self]?.contains(next) ?? false
    }

    /// 中文展示名。
    public var displayName: String {
        switch self {
        case .pending: return Localization.string("state.task.pending", default: "待执行")
        case .running: return Localization.string("state.task.running", default: "执行中")
        case .paused: return Localization.string("state.task.paused", default: "已暂停")
        case .succeeded: return Localization.string("state.task.succeeded", default: "全部成功")
        case .partialFailed: return Localization.string("state.task.partialFailed", default: "部分失败")
        case .cancelled: return Localization.string("state.task.cancelled", default: "已取消")
        }
    }
}

/// 单文件级状态机（见架构 §3.1 状态图）。
public enum FileStatus: String, Sendable, Codable, CaseIterable {
    /// 待复制
    case queued
    /// 传输中
    case transferring
    /// 校验中
    case verifying
    /// 成功
    case succeeded
    /// 失败（可重试）
    case failed
    /// 跳过
    case skipped
    /// 已取消
    ///
    /// 注：架构 §3.2.1 的枚举清单遗漏了本 case，但 §3.1 状态图与 T02 施工步骤 2 的
    /// 迁移表都包含「文件级取消」，故在此补齐以使迁移表可实现。
    case cancelled

    /// 合法的状态迁移表（架构 §3.1）。
    public static let allowedTransitions: [FileStatus: Set<FileStatus>] = [
        .queued: [.transferring, .skipped, .cancelled],
        .transferring: [.verifying, .failed, .skipped, .cancelled],
        .verifying: [.succeeded, .failed, .cancelled],
        .failed: [.queued],
        .succeeded: [],
        .skipped: [],
        .cancelled: [],
    ]

    /// 判断迁移是否合法。
    public func canTransition(to next: FileStatus) -> Bool {
        Self.allowedTransitions[self]?.contains(next) ?? false
    }

    /// 是否为终态（不可再迁移）。
    ///
    /// 注意：`.cancelled` 是**终态**（与 `TaskState.cancelled` 语义一致）。
    /// 之前它被归入非终态，与迁移表（无任何出边）自相矛盾 ——
    /// 「永远迁不出去」却告诉调用方「还可以继续动」。
    public var isTerminal: Bool {
        switch self {
        case .succeeded, .skipped, .cancelled:
            return true
        case .queued, .transferring, .verifying, .failed:
            return false
        }
    }

    /// 中文展示名。
    public var displayName: String {
        switch self {
        case .queued: return Localization.string("state.file.queued", default: "待复制")
        case .transferring: return Localization.string("state.file.transferring", default: "传输中")
        case .verifying: return Localization.string("state.file.verifying", default: "校验中")
        case .succeeded: return Localization.string("state.file.succeeded", default: "成功")
        case .failed: return Localization.string("state.file.failed", default: "失败")
        case .skipped: return Localization.string("state.file.skipped", default: "已跳过")
        case .cancelled: return Localization.string("state.file.cancelled", default: "已取消")
        }
    }
}

/// 校验维度的结论。`notVerified` 用于「源不可寻址且 tee 不可用」的降级场景（Q5）。
public enum VerificationStatus: String, Sendable, Codable, CaseIterable {
    /// 校验通过
    case passed
    /// 校验失败
    case failed
    /// 跳过校验
    case skipped
    /// 未做内容哈希 —— UI 必须显著警示，不可静默通过
    case notVerified

    /// 中文展示名。
    public var displayName: String {
        switch self {
        case .passed: return Localization.string("state.verification.passed", default: "通过")
        case .failed: return Localization.string("state.verification.failed", default: "失败")
        case .skipped: return Localization.string("state.verification.skipped", default: "跳过")
        case .notVerified: return Localization.string("state.verification.notVerified", default: "未校验")
        }
    }
}
