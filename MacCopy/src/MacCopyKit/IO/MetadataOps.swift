import Foundation
import Darwin

/// `stat` / `futimens` / `utimensat` / xattr 封装（出生时间、权限、扩展属性）。
///
/// 架构 §8.4 坑位（全部已实测确认，见 docs/ENV-FS-CONSTRAINTS-CORRECTED.md）：
/// - `stat` **无 `st_birthtime` 成员**，用 `sb.st_birthtimespec.tv_sec`
/// - **`setutimensat` 未导出**，Swift 侧实际可用的是 **`utimensat`**
///   （签名 `(Int32, String?, UnsafePointer<timespec>?, Int32)`）
/// - xattr 的 Swift 签名：
///   - `setxattr(path, name, value, size, position, options)` —— 6 参
///   - `getxattr(path, name, value, size, position, options)` —— 6 参
///   - `listxattr(path, namebuf, size, options)` —— 4 参
public enum MetadataOps {
    /// 文件的 stat 信息快照。
    public struct Metadata: Sendable, Equatable {
        /// 逻辑大小。
        public let size: Int64
        /// 实际占用块数（`st_blocks`）。
        public let blocks: Int64
        /// 修改时间。
        public let modifiedAt: Date
        /// 访问时间。
        public let accessedAt: Date
        /// 状态变更时间。
        public let changedAt: Date
        /// 出生时间。
        public let birthAt: Date?
        /// 权限位（`st_mode & 0o7777`）。
        public let mode: UInt16
        /// 是否为目录。
        public let isDirectory: Bool
        /// 是否为符号链接。
        public let isSymbolicLink: Bool
        /// inode 号。
        public let inode: UInt64
        /// 设备号。
        public let deviceID: UInt64

        /// 构造元数据。
        public init(
            size: Int64,
            blocks: Int64,
            modifiedAt: Date,
            accessedAt: Date,
            changedAt: Date,
            birthAt: Date?,
            mode: UInt16,
            isDirectory: Bool,
            isSymbolicLink: Bool,
            inode: UInt64,
            deviceID: UInt64
        ) {
            self.size = size
            self.blocks = blocks
            self.modifiedAt = modifiedAt
            self.accessedAt = accessedAt
            self.changedAt = changedAt
            self.birthAt = birthAt
            self.mode = mode
            self.isDirectory = isDirectory
            self.isSymbolicLink = isSymbolicLink
            self.inode = inode
            self.deviceID = deviceID
        }

        /// 是否为稀疏文件（占用 < 逻辑大小）。
        public var isSparse: Bool {
            allocatedSize < size
        }

        /// 实际占用字节数（`st_blocks * 512`）。
        public var allocatedSize: Int64 { blocks * 512 }
    }

    /// 时间戳写入模式。
    public enum TimestampMode: Sendable {
        /// 仅 atime / mtime。
        case atimeMtime
        /// atime / mtime / birthtime。
        case atimeMtimeBirthtime
    }

    /// 读取路径的元数据（不跟随符号链接）。
    ///
    /// - Parameter path: 路径。
    /// - Returns: 元数据；失败返回 nil。
    public static func metadata(at path: String) -> Metadata? {
        var sb = stat()
        let (rc, _) = Syscall.call { lstat(path, &sb) }
        guard rc == 0 else { return nil }
        return metadata(from: sb)
    }

    /// 从 `stat` 结构体构造元数据。
    ///
    /// - Parameter sb: stat 结构体。
    /// - Returns: 元数据。
    public static func metadata(from sb: stat) -> Metadata {
        Metadata(
            size: sb.st_size,
            blocks: Int64(sb.st_blocks),
            modifiedAt: Date(timeIntervalSince1970: TimeInterval(sb.st_mtimespec.tv_sec)),
            accessedAt: Date(timeIntervalSince1970: TimeInterval(sb.st_atimespec.tv_sec)),
            changedAt: Date(timeIntervalSince1970: TimeInterval(sb.st_ctimespec.tv_sec)),
            birthAt: Date(timeIntervalSince1970: TimeInterval(sb.st_birthtimespec.tv_sec)),
            mode: UInt16(sb.st_mode & 0o7777),
            isDirectory: (sb.st_mode & S_IFMT) == S_IFDIR,
            isSymbolicLink: (sb.st_mode & S_IFMT) == S_IFLNK,
            inode: UInt64(sb.st_ino),
            deviceID: UInt64(sb.st_dev)
        )
    }

    /// 读取 fd 的元数据。
    ///
    /// - Parameter fd: 文件描述符。
    /// - Returns: 元数据；失败返回 nil。
    public static func metadata(of fd: Int32) -> Metadata? {
        var sb = stat()
        let (rc, _) = Syscall.call { fstat(fd, &sb) }
        guard rc == 0 else { return nil }
        return metadata(from: sb)
    }

    /// 应用时间戳到目标文件。
    ///
    /// 优先用 `futimens`（按 fd，长路径友好）；失败回退 `utimensat`（按路径）。
    /// 出生时间用 `FileManager.setAttributes(.creationDate:)` 尽力而为。
    ///
    /// - Parameters:
    ///   - metadata: 源文件元数据。
    ///   - path: 目标路径。
    ///   - mode: 写入模式。
    /// - Throws: `MacCopyError`。
    public static func applyTimestamps(
        from metadata: Metadata,
        to path: String,
        mode: TimestampMode
    ) throws {
        let mtime = metadata.modifiedAt.timeIntervalSince1970
        let atime = metadata.accessedAt.timeIntervalSince1970
        var times = [
            timespec(tv_sec: Int(atime), tv_nsec: 0),
            timespec(tv_sec: Int(mtime), tv_nsec: 0),
        ]

        // 优先按 fd 写入（长路径友好）。
        let (fd, fdCode) = Syscall.call { open(path, O_RDONLY) }
        if fd >= 0 {
            defer { close(fd) }
            let (rc, code) = Syscall.call { futimens(fd, &times) }
            if rc == 0 {
                applyBirthTime(metadata: metadata, to: path, mode: mode)
                return
            }
            Log.io.error("futimens 失败 errno=\(code) path=\(path, privacy: .private)")
        } else {
            Log.io.error("打开目标以写时间戳失败 errno=\(fdCode) path=\(path, privacy: .private)")
        }

        // 回退：utimensat（Swift 侧没有 setutimensat）。
        // 签名：(Int32, String?, UnsafePointer<timespec>?, Int32)
        let (rc, code) = Syscall.call {
            utimensat(AT_FDCWD, path, &times, 0)
        }
        guard rc == 0 else {
            throw MacCopyError.unknown(
                underlying: "写入时间戳失败「\(path)」：errno=\(code) \(Syscall.describe(code))"
            )
        }
        applyBirthTime(metadata: metadata, to: path, mode: mode)
    }

    /// 尽力写入出生时间（架构 §1.1 V9：实测可写 birthtime）。
    ///
    /// - Parameters:
    ///   - metadata: 源文件元数据。
    ///   - path: 目标路径。
    ///   - mode: 写入模式。
    private static func applyBirthTime(
        metadata: Metadata,
        to path: String,
        mode: TimestampMode
    ) {
        guard mode == .atimeMtimeBirthtime, let birth = metadata.birthAt else { return }
        do {
            try FileManager.default.setAttributes(
                [.creationDate: birth],
                ofItemAtPath: path
            )
        } catch {
            // 出生时间写入失败不算整体失败（尽力而为）。
            Log.io.error("写入出生时间失败 path=\(path, privacy: .private)")
        }
    }

    /// 复制权限位。
    ///
    /// - Parameters:
    ///   - mode: 源权限位。
    ///   - path: 目标路径。
    public static func applyPermissions(mode: UInt16, to path: String) {
        let (rc, code) = Syscall.call { chmod(path, mode_t(mode)) }
        if rc != 0 {
            Log.io.error("设置权限失败 errno=\(code) path=\(path, privacy: .private)")
        }
    }

    /// 复制扩展属性（xattr）。
    ///
    /// 实测：`setxattr` 在本机**可用**（主理人探针因 errno 陈旧误判为失败）。
    /// 只复制 `user.*` 与 macOS 常见命名空间，跳过系统管理的命名空间。
    ///
    /// - Parameters:
    ///   - sourcePath: 源路径。
    ///   - destinationPath: 目标路径。
    /// - Returns: 成功复制的属性数量。
    @discardableResult
    public static func copyExtendedAttributes(
        from sourcePath: String,
        to destinationPath: String
    ) -> Int {
        let listSize = listxattr(sourcePath, nil, 0, 0)
        guard listSize > 0 else { return 0 }

        var names = [CChar](repeating: 0, count: listSize)
        let read = listxattr(sourcePath, &names, listSize, 0)
        guard read > 0 else { return 0 }

        var copied = 0
        var offset = 0
        while offset < read {
            // QA BUG-05：不能用 `withUnsafeBytes(of: names[offset...])` ——
            // 那是 ArraySlice **结构体本身**（指针+startIndex+count）的原始字节，
            // 解析出的属性名是乱码，导致 getxattr 全部失败。
            // 必须在**整个数组的缓冲区**上按 offset 取子串。
            let name = names.withUnsafeBytes { raw -> String in
                let bytes = raw.bindMemory(to: CChar.self)
                let remaining = read - offset
                guard remaining > 0 else { return "" }
                let slice = bytes[offset..<(offset + remaining)]
                let length = slice.prefix(while: { $0 != 0 }).count
                return String(
                    decoding: slice.prefix(length).map { UInt8(bitPattern: $0) },
                    as: UTF8.self
                )
            }
            guard !name.isEmpty else { break }
            offset += name.utf8.count + 1

            // 只复制用户命名空间与 macOS 资源属性。
            guard name.hasPrefix("user.") || name.hasPrefix("com.apple.") else { continue }

            let valueSize = getxattr(sourcePath, name, nil, 0, 0, 0)
            guard valueSize > 0 else { continue }

            var value = [UInt8](repeating: 0, count: valueSize)
            let got = value.withUnsafeMutableBytes { raw -> Int in
                getxattr(sourcePath, name, raw.baseAddress, valueSize, 0, 0)
            }
            guard got > 0 else { continue }

            let setResult = value.withUnsafeBytes { raw -> Int32 in
                setxattr(destinationPath, name, raw.baseAddress, got, 0, 0)
            }
            if setResult == 0 { copied += 1 }
        }
        return copied
    }
}
