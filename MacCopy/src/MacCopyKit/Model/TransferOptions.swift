import Foundation

/// 单次传输的全部可配置项。免费版/Pro 差异在 AppSettings 裁剪，
/// 引擎只接收**已被裁剪**的最终值（AD-03）。
public struct TransferOptions: Sendable, Codable, Equatable {
    /// 需要计算的校验算法集合（可多选同时校验）。
    public var checksumAlgorithms: Set<ChecksumAlgorithmID>
    /// 校验时机。
    public var verificationMode: VerificationMode
    /// 并发线程数（免费版已在 AppSettings 层强制 ≤ 2）。
    public var threadCount: Int
    /// 读写缓冲大小（字节）。
    public var bufferSize: Int
    /// 冲突策略。
    public var conflictPolicy: ConflictPolicy
    /// 是否保留时间戳。
    public var preserveTimestamps: Bool
    /// 是否启用 APFS 同卷克隆快路径。
    public var enableClone: Bool
    /// 稀疏文件处理策略。
    public var sparseMode: SparseMode
    /// 最大自动重试次数（默认 1，Q7）。
    public var maxRetries: Int
    /// 速率上限（字节/秒），nil 表示不限速。
    public var bandwidthLimitBytesPerSecond: Int?
    /// 是否生成 checksum 清单文件。
    public var generateChecksumFile: Bool
    /// 复制后动作（Pro 预留）。
    public var postAction: PostActionSpec?

    /// 默认配置。
    public static let `default` = TransferOptions(
        checksumAlgorithms: [.crc32],
        verificationMode: .teeDuringCopy,
        threadCount: 2,
        bufferSize: 8 * 1024 * 1024,
        conflictPolicy: .ask,
        preserveTimestamps: true,
        enableClone: true,
        sparseMode: .automatic,
        maxRetries: 1,
        bandwidthLimitBytesPerSecond: nil,
        generateChecksumFile: false,
        postAction: nil
    )

    /// 构造配置。
    public init(
        checksumAlgorithms: Set<ChecksumAlgorithmID> = [.crc32],
        verificationMode: VerificationMode = .teeDuringCopy,
        threadCount: Int = 2,
        bufferSize: Int = 8 * 1024 * 1024,
        conflictPolicy: ConflictPolicy = .ask,
        preserveTimestamps: Bool = true,
        enableClone: Bool = true,
        sparseMode: SparseMode = .automatic,
        maxRetries: Int = 1,
        bandwidthLimitBytesPerSecond: Int? = nil,
        generateChecksumFile: Bool = false,
        postAction: PostActionSpec? = nil
    ) {
        self.checksumAlgorithms = checksumAlgorithms
        self.verificationMode = verificationMode
        self.threadCount = threadCount
        self.bufferSize = bufferSize
        self.conflictPolicy = conflictPolicy
        self.preserveTimestamps = preserveTimestamps
        self.enableClone = enableClone
        self.sparseMode = sparseMode
        self.maxRetries = maxRetries
        self.bandwidthLimitBytesPerSecond = bandwidthLimitBytesPerSecond
        self.generateChecksumFile = generateChecksumFile
        self.postAction = postAction
    }

    /// 可选的缓冲大小档位（4 / 8 / 16 / 64 MiB）。
    public static let allowedBufferSizes: [Int] = [
        4 * 1024 * 1024,
        8 * 1024 * 1024,
        16 * 1024 * 1024,
        64 * 1024 * 1024,
    ]

    /// 是否启用任何内容哈希校验。
    public var isVerificationEnabled: Bool { !checksumAlgorithms.isEmpty }
}

/// 校验时机。
public enum VerificationMode: String, Sendable, Codable, CaseIterable {
    /// 边复制边哈希（默认，单遍）。
    case teeDuringCopy
    /// 仅失败时回读校验。
    case readBackOnDemand
    /// tee + 完成后再回读复核。
    case both

    /// 中文展示名。
    public var displayName: String {
        switch self {
        case .teeDuringCopy:
            return Localization.string("mode.verification.tee", default: "边复制边校验")
        case .readBackOnDemand:
            return Localization.string("mode.verification.readBack", default: "仅失败时回读校验")
        case .both:
            return Localization.string("mode.verification.both", default: "边复制边校验并回读复核")
        }
    }
}

/// 稀疏文件处理策略（PRD Q11）。
public enum SparseMode: String, Sendable, Codable, CaseIterable {
    /// 目标支持则保留，否则降级并标注。
    case automatic
    /// 强制尝试保留。
    case forceKeep
    /// 常规写入。
    case disabled

    /// 中文展示名。
    public var displayName: String {
        switch self {
        case .automatic: return Localization.string("mode.sparse.automatic", default: "自动")
        case .forceKeep: return Localization.string("mode.sparse.forceKeep", default: "强制保留")
        case .disabled: return Localization.string("mode.sparse.disabled", default: "不保留")
        }
    }
}

/// 复制后动作（P1-04 预留）。
public struct PostActionSpec: Sendable, Codable, Equatable {
    /// 脚本路径。
    public let scriptPath: String
    /// 脚本参数。
    public let arguments: [String]
    /// 是否为 Pro 专属功能。
    ///
    /// 恒为 true：复制后动作在 v1.0 属 P1-04 Pro 预留功能。
    /// 声明为计算属性而非存储属性，以避免 Codable 的「带初值的不可变属性不会解码」警告。
    public var isProOnly: Bool { true }

    /// 构造复制后动作。
    public init(scriptPath: String, arguments: [String] = []) {
        self.scriptPath = scriptPath
        self.arguments = arguments
    }
}

/// 校验失败时的处理动作。
public enum ChecksumFailureAction: String, Sendable, Codable, CaseIterable {
    /// 标记失败并自动重传。
    case markFailedAndRetry
    /// 仅标记失败，不重传。
    case markFailedOnly
    /// 标记失败但仍视为成功完成。
    case markFailedButContinue

    /// 中文展示名。
    public var displayName: String {
        switch self {
        case .markFailedAndRetry:
            return Localization.string("action.checksumFailure.retry", default: "标记失败并重新传输")
        case .markFailedOnly:
            return Localization.string("action.checksumFailure.markOnly", default: "仅标记失败")
        case .markFailedButContinue:
            return Localization.string("action.checksumFailure.continue", default: "标记失败但继续")
        }
    }
}
