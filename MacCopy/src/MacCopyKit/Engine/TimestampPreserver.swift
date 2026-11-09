import Foundation
import Darwin

/// 时间戳保留（atime / mtime / birthtime）与精度降级声明。
///
/// 架构 Q-A5：目标文件系统为 exFAT/FAT 时精度降到 2 秒，报告中标注。
public struct TimestampPreserver: Sendable {
    /// 时间戳写入模式。
    public enum Mode: Sendable {
        /// 仅 atime / mtime。
        case atimeMtime
        /// atime / mtime / birthtime。
        case atimeMtimeBirthtime
    }

    /// 精度声明。
    public enum Precision: String, Sendable {
        /// 精确（秒级）。
        case exact
        /// 降级到 2 秒（exFAT / FAT）。
        case degradedTwoSeconds

        /// 中文展示名。
        public var displayName: String {
            switch self {
            case .exact:
                return Localization.string(
                    "timestamp.precision.exact",
                    default: "时间戳已精确保留"
                )
            case .degradedTwoSeconds:
                return Localization.string(
                    "timestamp.precision.degraded",
                    default: "时间戳精度已降级为 2 秒（目标文件系统限制）"
                )
            }
        }
    }

    /// 构造时间戳保留器。
    public init() {}

    /// 应用时间戳到目标文件。
    ///
    /// - Parameters:
    ///   - entry: 源文件条目（含签名）。
    ///   - path: 目标路径。
    ///   - mode: 写入模式。
    /// - Throws: `MacCopyError`。
    public static func apply(
        from entry: FileEntry,
        to path: String,
        mode: Mode
    ) throws {
        guard let signature = entry.signature else { return }
        let metadata = MetadataOps.Metadata(
            size: entry.size,
            blocks: entry.allocatedSize / 512,
            modifiedAt: signature.modifiedAt,
            accessedAt: signature.modifiedAt,
            changedAt: signature.modifiedAt,
            birthAt: nil,
            mode: entry.mode,
            isDirectory: entry.isDirectory,
            isSymbolicLink: entry.isSymbolicLink,
            inode: signature.inode,
            deviceID: signature.deviceID
        )
        try MetadataOps.applyTimestamps(
            from: metadata,
            to: path,
            mode: mode == .atimeMtimeBirthtime ? .atimeMtimeBirthtime : .atimeMtime
        )
    }

    /// 判断目标卷的时间戳精度。
    ///
    /// - Parameter destinationDirectory: 目标目录。
    /// - Returns: 精度声明。
    public static func precision(for destinationDirectory: String) -> Precision {
        let fs = VolumeInspector.fileSystemType(at: destinationDirectory)
        // exFAT / FAT / MS-DOS 的时间戳只有 2 秒精度。
        let twoSecondFilesystems: Set<String> = ["exfat", "msdos", "fat", "fat32"]
        return twoSecondFilesystems.contains(fs) ? .degradedTwoSeconds : .exact
    }
}
