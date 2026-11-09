import Foundation

/// 目标卷信息。
public struct VolumeInfo: Sendable, Codable, Equatable {
    /// 卷挂载点。
    public let mountPoint: String
    /// 文件系统类型（如 "apfs" / "exfat" / "msdos" / "smbfs" / "nfs"）。
    public let fileSystemType: String
    /// 是否支持稀疏文件。
    public let supportsSparse: Bool
    /// 可用空间（字节）。
    public let availableBytes: Int64
    /// 总空间（字节）。
    public let totalBytes: Int64
    /// 是否为本地卷（非网络）。
    public let isLocal: Bool

    /// 构造卷信息。
    public init(
        mountPoint: String,
        fileSystemType: String,
        supportsSparse: Bool,
        availableBytes: Int64,
        totalBytes: Int64,
        isLocal: Bool
    ) {
        self.mountPoint = mountPoint
        self.fileSystemType = fileSystemType
        self.supportsSparse = supportsSparse
        self.availableBytes = availableBytes
        self.totalBytes = totalBytes
        self.isLocal = isLocal
    }

    /// 是否为 APFS（可走克隆快路径）。
    public var isAPFS: Bool { fileSystemType == "apfs" }

    /// 是否为网络卷。
    public var isNetwork: Bool {
        let networkTypes: Set<String> = ["smbfs", "nfs", "afpfs", "webdav", "cifs"]
        return networkTypes.contains(fileSystemType)
    }

    /// 中文展示名。
    public var displayName: String {
        "\(mountPoint) (\(fileSystemType))"
    }
}
