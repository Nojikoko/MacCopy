import Foundation

/// 设置项键名集中定义（架构 T02 施工步骤 6）。
public enum SettingsKey {
    /// 并发线程数。
    public static let threadCount = "com.maccopy.threadCount"
    /// 缓冲大小（MiB）。
    public static let bufferSizeMB = "com.maccopy.bufferSizeMB"
    /// 是否保留时间戳。
    public static let preserveTimestamps = "com.maccopy.preserveTimestamps"
    /// 是否启用克隆。
    public static let enableClone = "com.maccopy.enableClone"
    /// 稀疏文件策略。
    public static let sparseMode = "com.maccopy.sparseMode"
    /// 默认冲突策略。
    public static let defaultConflictPolicy = "com.maccopy.defaultConflictPolicy"
    /// 最大重试次数。
    public static let maxRetries = "com.maccopy.maxRetries"
    /// 默认校验算法集合（逗号分隔的 rawValue）。
    public static let defaultAlgorithms = "com.maccopy.defaultAlgorithms"
    /// 校验模式。
    public static let verificationMode = "com.maccopy.verificationMode"
    /// 是否生成校验清单。
    public static let generateChecksumFile = "com.maccopy.generateChecksumFile"
    /// 校验失败动作。
    public static let checksumFailureAction = "com.maccopy.checksumFailureAction"
    /// 限速（字节/秒，0 = 不限）。
    public static let bandwidthLimit = "com.maccopy.bandwidthLimit"
    /// Finder 服务是否启用。
    public static let serviceEnabled = "com.maccopy.serviceEnabled"
    /// v1.1：是否跟随系统语言（Q7 / P0-08）。
    public static let languageFollowsSystem = "com.maccopy.languageFollowsSystem"
    /// v1.1：用户手动选择的语言 tag（`SupportedLanguage.rawValue`）。
    public static let manualLanguageTag = "com.maccopy.manualLanguageTag"
}

/// 应用设置模型（架构 T02 施工步骤 6）。
public struct AppSettings: Sendable, Equatable {
    /// 用户期望的线程数（可能被 Pro 规则裁剪）。
    public var threadCount: Int = 2
    /// 缓冲大小（MiB）。
    public var bufferSizeMB: Int = 8
    /// 是否保留时间戳。
    public var preserveTimestamps: Bool = true
    /// 是否启用克隆。
    public var enableClone: Bool = true
    /// 稀疏文件策略。
    public var sparseMode: SparseMode = .automatic
    /// 默认冲突策略。
    public var defaultConflictPolicy: ConflictPolicy = .ask
    /// 最大重试次数。
    public var maxRetries: Int = 1
    /// 默认校验算法集合。
    public var defaultAlgorithms: Set<ChecksumAlgorithmID> = [.crc32]
    /// 校验模式。
    public var verificationMode: VerificationMode = .teeDuringCopy
    /// 是否生成校验清单。
    public var generateChecksumFile: Bool = false
    /// 校验失败动作。
    public var checksumFailureAction: ChecksumFailureAction = .markFailedAndRetry
    /// 限速（字节/秒），nil 表示不限。
    public var bandwidthLimit: Int? = nil
    /// Finder 服务是否启用。
    public var serviceEnabled: Bool = true

    // MARK: - v1.1 语言偏好（Q7 / P0-08 / P0-09）

    /// 是否跟随系统语言。新装默认 `true`；v1.0 升级用户首次加载写 `false` + 简中。
    public var languageFollowsSystem: Bool = true
    /// 用户手动选择的语言 tag；nil 表示未设置（跟随系统）。
    public var manualLanguageTag: String? = nil
    /// 是否为「v1.0 升级用户」的一次性迁移标记。
    ///
    /// **瞬态**：`save()` 不写此字段，重启后自然为 false（P0-08 ③）。
    public var didMigrateFromV10: Bool = false

    /// 构造设置（全部使用默认值）。
    public init() {}

    /// 免费版线程数裁剪（Q9）：设置里可调到 8，实际强制 ≤ 2。
    public var effectiveThreadCount: Int {
        FeatureFlags.effectiveThreadCount(threadCount)
    }

    /// 实际缓冲字节数。
    public var effectiveBufferSize: Int {
        bufferSizeMB * 1024 * 1024
    }

    /// 转换为一次传输的最终配置（AD-03：引擎只接收已裁剪的值）。
    public func makeTransferOptions() -> TransferOptions {
        TransferOptions(
            checksumAlgorithms: defaultAlgorithms,
            verificationMode: verificationMode,
            threadCount: effectiveThreadCount,
            bufferSize: effectiveBufferSize,
            conflictPolicy: defaultConflictPolicy,
            preserveTimestamps: preserveTimestamps,
            enableClone: enableClone,
            sparseMode: sparseMode,
            maxRetries: maxRetries,
            bandwidthLimitBytesPerSecond: bandwidthLimit,
            generateChecksumFile: generateChecksumFile,
            postAction: nil
        )
    }
}

/// 设置持久化（UserDefaults + 类型安全包装）。
public final class SettingsStore: @unchecked Sendable {
    /// 底层 UserDefaults。
    private let defaults: UserDefaults

    /// 构造设置存储。
    ///
    /// - Parameter defaults: UserDefaults 实例。nil 则用 `.standard`。
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 读取全部设置。
    public func load() -> AppSettings {
        var settings = AppSettings()

        let storedThreads = defaults.integer(forKey: SettingsKey.threadCount)
        if defaults.object(forKey: SettingsKey.threadCount) != nil {
            settings.threadCount = storedThreads
        }

        let storedBuffer = defaults.integer(forKey: SettingsKey.bufferSizeMB)
        if defaults.object(forKey: SettingsKey.bufferSizeMB) != nil {
            settings.bufferSizeMB = storedBuffer
        }

        if defaults.object(forKey: SettingsKey.preserveTimestamps) != nil {
            settings.preserveTimestamps = defaults.bool(forKey: SettingsKey.preserveTimestamps)
        }
        if defaults.object(forKey: SettingsKey.enableClone) != nil {
            settings.enableClone = defaults.bool(forKey: SettingsKey.enableClone)
        }
        if defaults.object(forKey: SettingsKey.generateChecksumFile) != nil {
            settings.generateChecksumFile = defaults.bool(forKey: SettingsKey.generateChecksumFile)
        }
        if defaults.object(forKey: SettingsKey.serviceEnabled) != nil {
            settings.serviceEnabled = defaults.bool(forKey: SettingsKey.serviceEnabled)
        }

        if let raw = defaults.string(forKey: SettingsKey.sparseMode),
           let mode = SparseMode(rawValue: raw) {
            settings.sparseMode = mode
        }
        if let raw = defaults.string(forKey: SettingsKey.defaultConflictPolicy),
           let policy = ConflictPolicy(rawValue: raw) {
            settings.defaultConflictPolicy = policy
        }
        if let raw = defaults.string(forKey: SettingsKey.verificationMode),
           let mode = VerificationMode(rawValue: raw) {
            settings.verificationMode = mode
        }
        if let raw = defaults.string(forKey: SettingsKey.checksumFailureAction),
           let action = ChecksumFailureAction(rawValue: raw) {
            settings.checksumFailureAction = action
        }
        if let raw = defaults.string(forKey: SettingsKey.defaultAlgorithms) {
            let ids = raw.split(separator: ",").compactMap { ChecksumAlgorithmID(rawValue: String($0)) }
            if !ids.isEmpty {
                settings.defaultAlgorithms = Set(ids)
            }
        }
        if defaults.object(forKey: SettingsKey.maxRetries) != nil {
            settings.maxRetries = defaults.integer(forKey: SettingsKey.maxRetries)
        }
        if defaults.object(forKey: SettingsKey.bandwidthLimit) != nil {
            let limit = defaults.integer(forKey: SettingsKey.bandwidthLimit)
            settings.bandwidthLimit = limit > 0 ? limit : nil
        }

        // MARK: v1.1 语言偏好 + 一次性迁移（P0-08 / Q1 裁决）
        //
        // ⚠️ 时序坑：迁移判定**必须**放在 `load()` 内。
        // Swift 中 `TransferViewModel.init()` 里 `self.settings = store.load()` 给
        // `@Published var` 赋值**不触发 `didSet`**，放 ViewModel 会永远不执行。
        let hasNewKey = defaults.object(forKey: SettingsKey.languageFollowsSystem) != nil
        if hasNewKey {
            settings.languageFollowsSystem = defaults.bool(forKey: SettingsKey.languageFollowsSystem)
            settings.manualLanguageTag = defaults.string(forKey: SettingsKey.manualLanguageTag)
            // 手动值非法/损坏 → 优雅降级为跟随系统（P0-09 ④）。
            if let tag = settings.manualLanguageTag, SupportedLanguage(rawValue: tag) == nil {
                settings.manualLanguageTag = nil
                settings.languageFollowsSystem = true
                Log.debug(Log.i18n, "非法手动语言值，已降级为跟随系统")
            }
        } else if Self.hasLegacyPreferences(defaults) {
            // Q1 裁决：v1.0 升级用户首次加载写 false + zh-Hans，避免静默变英文。
            settings.languageFollowsSystem = false
            settings.manualLanguageTag = SupportedLanguage.zhHans.rawValue
            settings.didMigrateFromV10 = true
            save(settings)   // 写入新键 → 迁移只发生一次
        }
        // 新装：无新键且无旧键 → 保持 true / nil（跟随系统）。

        return settings
    }

    /// 保存全部设置。
    ///
    /// - Parameter settings: 待保存设置。
    public func save(_ settings: AppSettings) {
        defaults.set(settings.threadCount, forKey: SettingsKey.threadCount)
        defaults.set(settings.bufferSizeMB, forKey: SettingsKey.bufferSizeMB)
        defaults.set(settings.preserveTimestamps, forKey: SettingsKey.preserveTimestamps)
        defaults.set(settings.enableClone, forKey: SettingsKey.enableClone)
        defaults.set(settings.sparseMode.rawValue, forKey: SettingsKey.sparseMode)
        defaults.set(settings.defaultConflictPolicy.rawValue, forKey: SettingsKey.defaultConflictPolicy)
        defaults.set(settings.maxRetries, forKey: SettingsKey.maxRetries)
        defaults.set(
            settings.defaultAlgorithms.map(\.rawValue).sorted().joined(separator: ","),
            forKey: SettingsKey.defaultAlgorithms
        )
        defaults.set(settings.verificationMode.rawValue, forKey: SettingsKey.verificationMode)
        defaults.set(settings.generateChecksumFile, forKey: SettingsKey.generateChecksumFile)
        defaults.set(settings.checksumFailureAction.rawValue, forKey: SettingsKey.checksumFailureAction)
        defaults.set(settings.bandwidthLimit ?? 0, forKey: SettingsKey.bandwidthLimit)
        defaults.set(settings.serviceEnabled, forKey: SettingsKey.serviceEnabled)

        // v1.1 语言偏好。`manualLanguageTag == nil` 时用 `removeObject(forKey:)`，
        // 不能用 `set(nil, ...)` —— 后者会让 `object(forKey:) != nil` 判定失真。
        defaults.set(settings.languageFollowsSystem, forKey: SettingsKey.languageFollowsSystem)
        if let tag = settings.manualLanguageTag {
            defaults.set(tag, forKey: SettingsKey.manualLanguageTag)
        } else {
            defaults.removeObject(forKey: SettingsKey.manualLanguageTag)
        }
        // 注意：`didMigrateFromV10` 是瞬态标记，**不写磁盘**。
    }

    /// 旧偏好判定：任意 `com.maccopy.*` 引擎设置键存在即视为 v1.0 安装。
    private static func hasLegacyPreferences(_ d: UserDefaults) -> Bool {
        [SettingsKey.threadCount, SettingsKey.bufferSizeMB, SettingsKey.preserveTimestamps,
         SettingsKey.defaultAlgorithms, SettingsKey.serviceEnabled]
            .contains { d.object(forKey: $0) != nil }
    }

    /// 恢复默认设置（**保留语言偏好**，Q7 / P0-09）。
    ///
    /// 语言是身份偏好，不随「恢复默认设置」重置。
    /// 仅供新装初始化使用；UI 应调用 `TransferViewModel.resetEngineSettings()`。
    ///
    /// - Parameter preserving: 现有设置，用于提取语言字段。nil 时用全默认。
    public func resetToDefaults(preserving current: AppSettings? = nil) {
        var fresh = AppSettings()
        if let current {
            fresh.languageFollowsSystem = current.languageFollowsSystem
            fresh.manualLanguageTag = current.manualLanguageTag
            fresh.didMigrateFromV10 = current.didMigrateFromV10
        }
        save(fresh)
    }
}
