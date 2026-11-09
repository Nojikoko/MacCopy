import Foundation

/// 错误分类。每类都有中文文案与「是否值得重试」判定。
///
/// UI 直接用 `localizedDescription` 取中文，不自行拼字符串。
///
/// 铁律（架构 §8.3）：
/// - 所有底层 `errno` 必须经本类型分类，不允许把裸 `Error` 抛到上层
/// - `isRetryable` 是可重试判定的**唯一**入口，不散落在各处
///
/// 额外遵循 `Codable` 是因为 `FileOutcome` 需要持久化失败原因（架构 §8.3 要求
/// 原始错误信息保留在 `underlying` 字符串中）。`Codable` 实现以 `kind` 作为
/// 判别字段，编码结果稳定且可回读。
public enum MacCopyError: Error, Sendable, Equatable, Codable {
    /// 权限不足。
    case permissionDenied(path: String)
    /// 磁盘空间不足。
    case diskFull(path: String, needed: Int64, available: Int64)
    /// 文件被占用。
    case fileBusy(path: String)
    /// 网络不可用。
    case networkUnavailable(path: String, underlying: String)
    /// 路径过长。
    case pathTooLong(path: String, byteLength: Int)
    /// 源不可读。
    case sourceUnreadable(path: String, underlying: String)
    /// 复制过程中源发生变化。
    case sourceChangedDuringCopy(path: String)
    /// 目标不可写。
    case destinationUnwritable(path: String)
    /// 校验不匹配。
    case checksumMismatch(file: String, algorithm: ChecksumAlgorithmID, expected: String, actual: String)
    /// 克隆失败（已自动回退到流式路径，**不计为失败**）。
    case cloneFailed(path: String, underlying: String)
    /// 卷不存在。
    case volumeNotFound(path: String)
    /// 用户取消。
    case cancelled
    /// 未知错误。
    case unknown(underlying: String)

    /// 该错误是否值得自动重试（PRD Q7：校验失败自动重传 1 次）。
    public var isRetryable: Bool {
        switch self {
        case .fileBusy, .networkUnavailable, .cloneFailed:
            return true
        case .checksumMismatch:
            return true   // 多数是传输抖动，重传一次能消除
        case .permissionDenied, .diskFull, .pathTooLong, .sourceChangedDuringCopy:
            return false  // 重试无意义
        case .cancelled, .unknown:
            return false
        case .sourceUnreadable, .destinationUnwritable, .volumeNotFound:
            return false
        }
    }

    /// 稳定的错误分类标识（用于持久化 `error_kind` 列）。
    public var kind: String {
        switch self {
        case .permissionDenied: return "permissionDenied"
        case .diskFull: return "diskFull"
        case .fileBusy: return "fileBusy"
        case .networkUnavailable: return "networkUnavailable"
        case .pathTooLong: return "pathTooLong"
        case .sourceUnreadable: return "sourceUnreadable"
        case .sourceChangedDuringCopy: return "sourceChangedDuringCopy"
        case .destinationUnwritable: return "destinationUnwritable"
        case .checksumMismatch: return "checksumMismatch"
        case .cloneFailed: return "cloneFailed"
        case .volumeNotFound: return "volumeNotFound"
        case .cancelled: return "cancelled"
        case .unknown: return "unknown"
        }
    }

    /// 中文文案（覆盖「发生了什么 + 用户能做什么」）。
    public var localizedDescription: String {
        switch self {
        case .permissionDenied(let path):
            return Localization.format(
                "error.permissionDenied",
                default: "没有权限读取「%@」。请在「系统设置 → 隐私与安全性 → 完全磁盘访问权限」中授权 MacCopy。",
                path
            )
        case .diskFull(_, let needed, let available):
            return Localization.format(
                "error.diskFull",
                default: "目标磁盘空间不足：还需 %@，可用 %@。请清理空间后重试。",
                Bytes.humanReadable(needed),
                Bytes.humanReadable(available)
            )
        case .fileBusy(let path):
            return Localization.format(
                "error.fileBusy",
                default: "文件「%@」正被其他程序占用，无法读取。请关闭占用它的程序后重试。",
                path
            )
        case .networkUnavailable(let path, let underlying):
            return Localization.format(
                "error.networkUnavailable",
                default: "网络不可用，无法访问「%@」（%@）。请检查网络连接后重试。",
                path,
                underlying
            )
        case .pathTooLong(let path, let byteLength):
            return Localization.format(
                "error.pathTooLong",
                default: "路径长度 %d 字节超出 macOS 限制（1024 字节），无法访问「%@」。请缩短目录名后重试。",
                byteLength,
                path
            )
        case .sourceUnreadable(let path, let underlying):
            return Localization.format(
                "error.sourceUnreadable",
                default: "无法读取源文件「%@」（%@）。请确认文件未被删除且有读取权限。",
                path,
                underlying
            )
        case .sourceChangedDuringCopy(let path):
            return Localization.format(
                "error.sourceChangedDuringCopy",
                default: "复制过程中源文件「%@」发生了变化。为避免产生损坏的文件，本次复制已中止，请重新开始。",
                path
            )
        case .destinationUnwritable(let path):
            return Localization.format(
                "error.destinationUnwritable",
                default: "无法写入目标「%@」。请检查目标目录是否存在以及写入权限。",
                path
            )
        case .checksumMismatch(let file, let algorithm, let expected, let actual):
            return Localization.format(
                "error.checksumMismatch",
                default: "校验失败：「%@」的 %@ 摘要不一致（期望 %@，实际 %@）。数据在传输中可能已损坏，将自动重新传输一次。",
                file,
                algorithm.displayName,
                expected,
                actual
            )
        case .cloneFailed(let path, let underlying):
            return Localization.format(
                "error.cloneFailed",
                default: "无法使用 APFS 克隆方式复制「%@」（%@），已自动切换为常规复制方式，不影响结果。",
                path,
                underlying
            )
        case .volumeNotFound(let path):
            return Localization.format(
                "error.volumeNotFound",
                default: "找不到挂载卷「%@」。请确认磁盘已连接并已挂载。",
                path
            )
        case .cancelled:
            return Localization.string(
                "error.cancelled",
                default: "操作已取消。"
            )
        case .unknown(let underlying):
            return Localization.format(
                "error.unknown",
                default: "发生未知错误：%@。请重试；若持续出现，请查看 MacCopy 的日志。",
                underlying
            )
        }
    }

    /// 从 POSIX `errno` 分类构造错误（架构 §8.3：errno 必须在失败点立即读取）。
    ///
    /// - Parameters:
    ///   - code: 已捕获的 errno 值。
    ///   - path: 相关路径。
    ///   - underlying: 原始错误描述（`strerror`）。
    /// - Returns: 分类后的错误。
    public static func fromErrno(_ code: Int32, path: String, underlying: String = "") -> MacCopyError {
        switch code {
        case EACCES, EPERM:
            return .permissionDenied(path: path)
        case ENOSPC, EDQUOT:
            return .diskFull(path: path, needed: 0, available: 0)
        case EBUSY, ETXTBSY:
            return .fileBusy(path: path)
        case ENETDOWN, ENETUNREACH, EHOSTUNREACH, ETIMEDOUT:
            return .networkUnavailable(path: path, underlying: underlying)
        case ENAMETOOLONG:
            return .pathTooLong(path: path, byteLength: path.utf8.count)
        case ENOENT, EIO:
            return .sourceUnreadable(path: path, underlying: underlying)
        default:
            return .unknown(underlying: underlying.isEmpty ? "errno=\(code)" : underlying)
        }
    }
}

extension MacCopyError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .permissionDenied(let path): return "permissionDenied(\(path))"
        case .diskFull(let path, let needed, let available): return "diskFull(\(path), \(needed), \(available))"
        case .fileBusy(let path): return "fileBusy(\(path))"
        case .networkUnavailable(let path, let underlying): return "networkUnavailable(\(path), \(underlying))"
        case .pathTooLong(let path, let byteLength): return "pathTooLong(\(path), \(byteLength))"
        case .sourceUnreadable(let path, let underlying): return "sourceUnreadable(\(path), \(underlying))"
        case .sourceChangedDuringCopy(let path): return "sourceChangedDuringCopy(\(path))"
        case .destinationUnwritable(let path): return "destinationUnwritable(\(path))"
        case .checksumMismatch(let file, let algorithm, let expected, let actual):
            return "checksumMismatch(\(file), \(algorithm.rawValue), \(expected), \(actual))"
        case .cloneFailed(let path, let underlying): return "cloneFailed(\(path), \(underlying))"
        case .volumeNotFound(let path): return "volumeNotFound(\(path))"
        case .cancelled: return "cancelled"
        case .unknown(let underlying): return "unknown(\(underlying))"
        }
    }
}

// MARK: - Codable

extension MacCopyError {
    /// 编码用的判别字段名。
    private enum CodingKeys: String, CodingKey {
        case kind
        case path
        case needed
        case available
        case byteLength
        case underlying
        case file
        case algorithm
        case expected
        case actual
    }

    /// 编码为字典（`kind` 为判别字段）。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .permissionDenied(let path):
            try container.encode(path, forKey: .path)
        case .diskFull(let path, let needed, let available):
            try container.encode(path, forKey: .path)
            try container.encode(needed, forKey: .needed)
            try container.encode(available, forKey: .available)
        case .fileBusy(let path):
            try container.encode(path, forKey: .path)
        case .networkUnavailable(let path, let underlying):
            try container.encode(path, forKey: .path)
            try container.encode(underlying, forKey: .underlying)
        case .pathTooLong(let path, let byteLength):
            try container.encode(path, forKey: .path)
            try container.encode(byteLength, forKey: .byteLength)
        case .sourceUnreadable(let path, let underlying):
            try container.encode(path, forKey: .path)
            try container.encode(underlying, forKey: .underlying)
        case .sourceChangedDuringCopy(let path):
            try container.encode(path, forKey: .path)
        case .destinationUnwritable(let path):
            try container.encode(path, forKey: .path)
        case .checksumMismatch(let file, let algorithm, let expected, let actual):
            try container.encode(file, forKey: .file)
            try container.encode(algorithm, forKey: .algorithm)
            try container.encode(expected, forKey: .expected)
            try container.encode(actual, forKey: .actual)
        case .cloneFailed(let path, let underlying):
            try container.encode(path, forKey: .path)
            try container.encode(underlying, forKey: .underlying)
        case .volumeNotFound(let path):
            try container.encode(path, forKey: .path)
        case .cancelled:
            break
        case .unknown(let underlying):
            try container.encode(underlying, forKey: .underlying)
        }
    }

    /// 从字典解码（按 `kind` 分派）。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "permissionDenied":
            self = .permissionDenied(path: try container.decode(String.self, forKey: .path))
        case "diskFull":
            self = .diskFull(
                path: try container.decode(String.self, forKey: .path),
                needed: try container.decode(Int64.self, forKey: .needed),
                available: try container.decode(Int64.self, forKey: .available)
            )
        case "fileBusy":
            self = .fileBusy(path: try container.decode(String.self, forKey: .path))
        case "networkUnavailable":
            self = .networkUnavailable(
                path: try container.decode(String.self, forKey: .path),
                underlying: try container.decode(String.self, forKey: .underlying)
            )
        case "pathTooLong":
            self = .pathTooLong(
                path: try container.decode(String.self, forKey: .path),
                byteLength: try container.decode(Int.self, forKey: .byteLength)
            )
        case "sourceUnreadable":
            self = .sourceUnreadable(
                path: try container.decode(String.self, forKey: .path),
                underlying: try container.decode(String.self, forKey: .underlying)
            )
        case "sourceChangedDuringCopy":
            self = .sourceChangedDuringCopy(path: try container.decode(String.self, forKey: .path))
        case "destinationUnwritable":
            self = .destinationUnwritable(path: try container.decode(String.self, forKey: .path))
        case "checksumMismatch":
            self = .checksumMismatch(
                file: try container.decode(String.self, forKey: .file),
                algorithm: try container.decode(ChecksumAlgorithmID.self, forKey: .algorithm),
                expected: try container.decode(String.self, forKey: .expected),
                actual: try container.decode(String.self, forKey: .actual)
            )
        case "cloneFailed":
            self = .cloneFailed(
                path: try container.decode(String.self, forKey: .path),
                underlying: try container.decode(String.self, forKey: .underlying)
            )
        case "volumeNotFound":
            self = .volumeNotFound(path: try container.decode(String.self, forKey: .path))
        case "cancelled":
            self = .cancelled
        case "unknown":
            self = .unknown(underlying: try container.decode(String.self, forKey: .underlying))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "未知的错误类型：\(kind)"
            )
        }
    }
}
