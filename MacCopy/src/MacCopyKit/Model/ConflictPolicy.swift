import Foundation

/// 冲突策略（目标已存在同名文件时如何处理）。
public enum ConflictPolicy: String, Sendable, Codable, CaseIterable {
    /// 跳过目标已存在的文件。
    case skip
    /// 覆盖目标已存在的文件。
    case overwrite
    /// 自动重命名（追加「副本」序号）。
    case rename
    /// 每次询问用户。
    case ask
    /// 保留较新的一份（比较修改时间）。
    case keepNewer

    /// 中文展示名。
    public var displayName: String {
        switch self {
        case .skip: return Localization.string("policy.conflict.skip", default: "跳过")
        case .overwrite: return Localization.string("policy.conflict.overwrite", default: "覆盖")
        case .rename: return Localization.string("policy.conflict.rename", default: "自动重命名")
        case .ask: return Localization.string("policy.conflict.ask", default: "每次询问")
        case .keepNewer: return Localization.string("policy.conflict.keepNewer", default: "保留较新")
        }
    }
}

/// 冲突判定结果。由 `ConflictResolver` 产出，供 `FileTransferer` 决策。
public enum ConflictDecision: Sendable, Equatable {
    /// 跳过该文件。
    case skip
    /// 覆盖目标。
    case overwrite
    /// 使用新文件名。
    case rename(String)
    /// 直接继续（无冲突）。
    case proceed
}
