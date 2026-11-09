import Foundation

/// 目标冲突解析器。
///
/// 架构 §5：目标已存在时的四种策略（跳过 / 覆盖 / 重命名 / 每次询问）。
///
/// 架构 §8.6：引擎→UI **单向**，所以「询问」通过注入的**异步决策闭包**实现，
/// 引擎不直接依赖任何 UI 类型。
public struct ConflictResolver: Sendable {
    /// 询问决策器（当策略为 `.ask` 时被调用）。
    ///
    /// - Parameters:
    ///   - sourcePath: 源路径。
    ///   - destinationPath: 目标路径（已存在）。
    ///   - sourceSize: 源文件大小。
    ///   - destinationSize: 目标文件大小。
    ///   - sourceModifiedAt: 源修改时间。
    ///   - destinationModifiedAt: 目标修改时间。
    /// - Returns: 用户选择的动作。
    public typealias DecisionProvider = @Sendable (
        _ sourcePath: String,
        _ destinationPath: String,
        _ sourceSize: Int64,
        _ destinationSize: Int64,
        _ sourceModifiedAt: Date,
        _ destinationModifiedAt: Date
    ) async -> ConflictDecision

    /// 冲突策略。
    public let policy: ConflictPolicy

    /// 询问决策器（可空；策略为 `.ask` 但未提供时降级为 `.rename`）。
    private let decisionProvider: DecisionProvider?

    /// 构造冲突解析器。
    ///
    /// - Parameters:
    ///   - policy: 冲突策略。
    ///   - decisionProvider: 询问决策器。
    public init(policy: ConflictPolicy, decisionProvider: DecisionProvider? = nil) {
        self.policy = policy
        self.decisionProvider = decisionProvider
    }

    /// 解析冲突。
    ///
    /// - Parameters:
    ///   - sourcePath: 源路径。
    ///   - destinationPath: 目标路径（可能已存在）。
    ///   - sourceSize: 源大小。
    ///   - destinationSize: 目标大小。
    ///   - sourceModifiedAt: 源修改时间。
    ///   - destinationModifiedAt: 目标修改时间。
    /// - Returns: 解析结果（`.proceed` 表示无冲突）。
    public func resolve(
        sourcePath: String,
        destinationPath: String,
        sourceSize: Int64,
        destinationSize: Int64,
        sourceModifiedAt: Date,
        destinationModifiedAt: Date
    ) async -> ConflictDecision {
        switch policy {
        case .skip:
            return .skip
        case .overwrite:
            return .overwrite
        case .rename:
            return .rename(await uniqueName(for: destinationPath))
        case .ask:
            guard let provider = decisionProvider else {
                // 没有决策器时不能默默覆盖 —— 降级为重命名（最安全）。
                Log.engine.error("策略为「每次询问」但未提供决策器，降级为自动重命名")
                return .rename(await uniqueName(for: destinationPath))
            }
            let decision = await provider(
                sourcePath,
                destinationPath,
                sourceSize,
                destinationSize,
                sourceModifiedAt,
                destinationModifiedAt
            )
            // 用户选择「重命名」时也要生成唯一名。
            if case .rename = decision {
                return .rename(await uniqueName(for: destinationPath))
            }
            return decision
        case .keepNewer:
            // 源更新 → 覆盖；否则跳过。
            return sourceModifiedAt > destinationModifiedAt ? .overwrite : .skip
        }
    }

    /// 生成不冲突的目标文件名（「名称 副本 N.ext」）。
    ///
    /// - Parameter destinationPath: 原目标路径。
    /// - Returns: 唯一的目标路径。
    public func uniqueName(for destinationPath: String) async -> String {
        let directory = (destinationPath as NSString).deletingLastPathComponent
        let name = (destinationPath as NSString).lastPathComponent

        for index in 1...9999 {
            let candidate = PathUtil.join(directory, PathUtil.renamed(name, index: index))
            if !FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        // 极端情况下用时间戳兜底。
        let fallback = PathUtil.renamed(name, index: Int(Date().timeIntervalSince1970) % 1_000_000)
        return PathUtil.join(directory, fallback)
    }
}
