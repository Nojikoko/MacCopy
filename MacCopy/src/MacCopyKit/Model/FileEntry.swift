import Foundation

/// 一个待复制条目。文件与目录统一建模，目录通过 `isDirectory` 区分。
///
/// 设计说明（Q-A8）：使用 **struct 紧凑布局**而非 class。
/// 10 万文件场景下每个 class 实例都需要独立堆分配 + 引用计数，
/// struct 则可以内联在数组的连续内存中，显著降低内存占用与分配开销。
public struct FileEntry: Sendable, Codable, Identifiable, Equatable {
    /// 唯一标识。
    public let id: UUID
    /// 源绝对路径。
    public let sourcePath: String
    /// 相对目标根的路径（用于长路径与报告）。
    public let relativePath: String
    /// 是否为目录。
    public let isDirectory: Bool
    /// 逻辑大小（目录为 0）。
    public let size: Int64
    /// 实际占用大小（`st_blocks * 512`）。
    public let allocatedSize: Int64
    /// 是否为符号链接。
    public let isSymbolicLink: Bool
    /// 符号链接目标。
    public let linkDestination: String?
    /// 是否为隐藏文件（以 `.` 开头）。
    public let isHidden: Bool
    /// 是否为稀疏文件（占用 < 逻辑大小）。
    public let isSparse: Bool
    /// 源文件签名（目录为 nil）。
    public let signature: FileSignature?
    /// 权限位（`st_mode & 0o7777`）。
    public let mode: UInt16

    /// 构造条目。
    ///
    /// - Parameters:
    ///   - id: 唯一标识，nil 时自动生成。
    ///   - sourcePath: 源绝对路径。
    ///   - relativePath: 相对目标根的路径。
    ///   - isDirectory: 是否为目录。
    ///   - size: 逻辑大小。
    ///   - allocatedSize: 实际占用大小。
    ///   - isSymbolicLink: 是否为符号链接。
    ///   - linkDestination: 符号链接目标。
    ///   - isHidden: 是否为隐藏文件。
    ///   - isSparse: 是否为稀疏文件。
    ///   - signature: 源文件签名。
    ///   - mode: 权限位。
    public init(
        id: UUID = UUID(),
        sourcePath: String,
        relativePath: String,
        isDirectory: Bool,
        size: Int64 = 0,
        allocatedSize: Int64 = 0,
        isSymbolicLink: Bool = false,
        linkDestination: String? = nil,
        isHidden: Bool = false,
        isSparse: Bool = false,
        signature: FileSignature? = nil,
        mode: UInt16 = 0o644
    ) {
        self.id = id
        self.sourcePath = sourcePath
        self.relativePath = relativePath
        self.isDirectory = isDirectory
        self.size = size
        self.allocatedSize = allocatedSize
        self.isSymbolicLink = isSymbolicLink
        self.linkDestination = linkDestination
        self.isHidden = isHidden
        self.isSparse = isSparse
        self.signature = signature
        self.mode = mode
    }

    /// 展示用文件名（相对路径的末段）。
    public var displayName: String {
        let lastComponent = (relativePath as NSString).lastPathComponent
        return lastComponent.isEmpty ? sourcePath : lastComponent
    }
}
