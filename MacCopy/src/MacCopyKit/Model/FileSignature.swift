import Foundation

/// 源文件签名。断点续传时用于判定「源是否还是同一个文件」（PRD P0-07）。
public struct FileSignature: Sendable, Codable, Equatable {
    /// 文件逻辑大小（字节）。
    public let size: Int64
    /// 最后修改时间。
    public let modifiedAt: Date
    /// inode 号。
    public let inode: UInt64
    /// 设备号（跨设备 inode 可重复，需配对使用）。
    public let deviceID: UInt64

    /// 构造签名。
    public init(size: Int64, modifiedAt: Date, inode: UInt64, deviceID: UInt64) {
        self.size = size
        self.modifiedAt = modifiedAt
        self.inode = inode
        self.deviceID = deviceID
    }

    /// 签名一致性：size 必须精确相等，mtime 容差 1 秒（部分 FS 精度不足），inode 必须相等。
    ///
    /// - Parameter other: 另一个签名。
    /// - Returns: 是否判定为同一个文件。
    public func matches(_ other: FileSignature) -> Bool {
        size == other.size
            && inode == other.inode
            && deviceID == other.deviceID
            && abs(modifiedAt.timeIntervalSince(other.modifiedAt)) <= 1.0
    }
}
