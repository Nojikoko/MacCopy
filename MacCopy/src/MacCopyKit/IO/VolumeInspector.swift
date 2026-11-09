import Foundation
import Darwin

/// 卷信息查询（卷类型 / 稀疏支持 / 同卷判定 / 可用空间）。
public struct VolumeInspector: Sendable {
    /// 构造卷信息查询器。
    public init() {}

    /// 判断两个路径是否在同一卷（决定能否走克隆）。
    ///
    /// 架构 §8.4 坑位：Swift 侧 `stat` 结构体**不暴露 `st_fsid`**，
    /// 无法用它判断同卷 → 改用 `st_dev`（同一设备 = 同一卷）。
    ///
    /// - Parameters:
    ///   - a: 路径 A。
    ///   - b: 路径 B。
    /// - Returns: 是否同卷。
    public static func sameVolume(_ a: String, _ b: String) -> Bool {
        var sa = stat()
        var sb = stat()
        let (rcA, _) = Syscall.call { lstat(a, &sa) }
        let (rcB, _) = Syscall.call { lstat(b, &sb) }
        guard rcA == 0, rcB == 0 else { return false }
        return sa.st_dev == sb.st_dev
    }

    /// 目标卷文件系统类型（"apfs" / "exfat" / "msdos" / "smbfs" / "nfs" ...）。
    ///
    /// 坑位：`statfs.f_fstypename` 是 **16 元组 C 数组**，不是指针。
    ///
    /// - Parameter path: 路径。
    /// - Returns: 文件系统类型字符串。
    public static func fileSystemType(at path: String) -> String {
        var st = statfs()
        let (rc, _) = Syscall.call { statfs(path, &st) }
        guard rc == 0 else { return "unknown" }
        return fsTypeName(st.f_fstypename)
    }

    /// 从 `statfs.f_fstypename` 提取文件系统类型名。
    ///
    /// - Parameter tuple: 16 元组 C 数组。
    /// - Returns: 类型名。
    static func fsTypeName(_ tuple: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                                    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar)) -> String {
        withUnsafeBytes(of: tuple) { raw -> String in
            let bytes = raw.bindMemory(to: CChar.self)
            let length = bytes.prefix(while: { $0 != 0 }).count
            return String(decoding: bytes.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }

    /// 是否支持稀疏文件（APFS/HFS+ 支持；exfat/msdos/smbfs 不支持）。
    ///
    /// - Parameter path: 路径。
    /// - Returns: 是否支持稀疏。
    public static func supportsSparse(at path: String) -> Bool {
        let fs = fileSystemType(at: path)
        return fs == "apfs" || fs == "hfs" || fs == "hfs+"
    }

    /// 是否为网络卷。
    ///
    /// - Parameter path: 路径。
    /// - Returns: 是否网络卷。
    public static func isNetworkVolume(at path: String) -> Bool {
        let networkTypes: Set<String> = ["smbfs", "nfs", "afpfs", "webdav", "cifs"]
        return networkTypes.contains(fileSystemType(at: path))
    }

    /// 可用空间（字节）。
    ///
    /// 架构 §8.4 坑位：用 `f_bavail`（已扣除保留块）而不是 `f_bfree`。
    ///
    /// - Parameter path: 路径。
    /// - Returns: 可用字节数。
    public static func availableBytes(at path: String) -> Int64 {
        var st = statfs()
        let (rc, _) = Syscall.call { statfs(path, &st) }
        guard rc == 0 else { return 0 }
        return Int64(st.f_bavail) * Int64(st.f_bsize)
    }

    /// 总空间（字节）。
    ///
    /// - Parameter path: 路径。
    /// - Returns: 总字节数。
    public static func totalBytes(at path: String) -> Int64 {
        var st = statfs()
        let (rc, _) = Syscall.call { statfs(path, &st) }
        guard rc == 0 else { return 0 }
        // f_blocks 是总块数，f_bfree 是可用块数，f_bavail 是对用户可用的块数。
        return Int64(st.f_blocks) * Int64(st.f_bsize)
    }

    /// 查询目标卷的完整信息。
    ///
    /// - Parameter path: 路径。
    /// - Returns: 卷信息（查询失败返回 nil）。
    public static func volumeInfo(at path: String) -> VolumeInfo? {
        var st = statfs()
        let (rc, _) = Syscall.call { statfs(path, &st) }
        guard rc == 0 else { return nil }
        let fsType = fsTypeName(st.f_fstypename)
        return VolumeInfo(
            mountPoint: path,
            fileSystemType: fsType,
            supportsSparse: fsType == "apfs" || fsType == "hfs" || fsType == "hfs+",
            availableBytes: Int64(st.f_bavail) * Int64(st.f_bsize),
            totalBytes: Int64(st.f_blocks) * Int64(st.f_bsize),
            isLocal: !isNetworkVolume(at: path)
        )
    }
}
