import Foundation
import Darwin

/// 长路径访问封装。
///
/// macOS 无 `\\?\` 前缀，PATH_MAX = 1024 字节。解法：**逐级 openat()**，
/// 每层只处理一个路径分量（≤255 字节），内核负责拼接，
/// 因此总路径长度不受 PATH_MAX 限制（PRD P0-11 / Q4）。
///
/// 典型用法：
/// ```swift
/// try walker.withDirectoryHandle(at: "/Users/x/极长的目录名") { dirFD in
///     let fileFD = try walker.openChild(named: "文件.bin", in: dirFD)
/// }
/// ```
///
/// 实测约束（docs/ENV-FS-CONSTRAINTS-CORRECTED.md）：
/// - `mkdir` 可用，但**父目录必须存在**（否则 ENOENT），所以建目录必须**逐级**创建
/// - `openat` 可用
public struct PathWalker: Sendable {
    /// 快路径阈值：路径 ≤ 1000 字节时用普通 `open`（更快，代码简单）。
    public static let fastPathThreshold = 1000

    /// 构造路径访问器。
    public init() {}

    // MARK: - 目录打开

    /// 逐级打开目录，返回 fd。调用方负责 close（或交给 `withDirectoryHandle`）。
    ///
    /// - Parameter path: 目录绝对路径。
    /// - Returns: 目录 fd。
    public func openDirectory(at path: String) throws -> Int32 {
        // 快路径：路径够短，直接 open。
        if path.utf8.count <= Self.fastPathThreshold {
            let (rc, code) = Syscall.call { open(path, O_RDONLY | O_DIRECTORY) }
            guard rc >= 0 else {
                throw Self.error(from: code, path: path)
            }
            return rc
        }

        // 慢路径：逐级 openat。
        let components = PathUtil.components(of: path)
        guard !components.isEmpty else {
            let (rc, code) = Syscall.call { open("/", O_RDONLY | O_DIRECTORY) }
            guard rc >= 0 else { throw Self.error(from: code, path: path) }
            return rc
        }

        var currentFD: Int32 = -1
        let (rootRC, rootCode) = Syscall.call { open("/", O_RDONLY | O_DIRECTORY) }
        guard rootRC >= 0 else { throw Self.error(from: rootCode, path: path) }
        currentFD = rootRC

        for component in components {
            let nextFD = openat(currentFD, component, O_RDONLY | O_DIRECTORY)
            if nextFD < 0 {
                let code = Syscall.currentErrno()
                if currentFD >= 0 { close(currentFD) }
                throw Self.error(from: code, path: path)
            }
            if currentFD >= 0 { close(currentFD) }
            currentFD = nextFD
        }
        return currentFD
    }

    /// 在已打开的目录 fd 下打开子路径（支持多级分量）。
    ///
    /// - Parameters:
    ///   - relative: 相对路径（可含多级，用 `/` 分隔）。
    ///   - dirFD: 父目录 fd。
    /// - Returns: 文件 fd。
    public func openChild(named relative: String, in dirFD: Int32) throws -> Int32 {
        let components = PathUtil.components(of: relative)
        var currentFD: Int32 = dirFD
        var ownsCurrent = false

        for (index, component) in components.enumerated() {
            let isLast = (index == components.count - 1)
            let flags = isLast ? O_RDONLY : (O_RDONLY | O_DIRECTORY)
            let nextFD = openat(currentFD, component, flags)
            if nextFD < 0 {
                let code = Syscall.currentErrno()
                if ownsCurrent && currentFD >= 0 { close(currentFD) }
                throw Self.error(from: code, path: relative)
            }
            if ownsCurrent && currentFD >= 0 { close(currentFD) }
            currentFD = nextFD
            ownsCurrent = true
        }

        if ownsCurrent && currentFD >= 0 {
            // 只返回最终 fd，交给调用方管理；但中途打开的父 fd 已逐级关闭。
            return currentFD
        }
        return currentFD
    }

    /// 打开文件（读/写/创建），自动建父目录。
    ///
    /// 长路径关键：路径超过 PATH_MAX 时走**逐级 openat** 通道，
    /// 避免 `open(绝对路径)` 返回 ENAMETOOLONG。
    ///
    /// - Parameters:
    ///   - path: 文件绝对路径。
    ///   - flags: `open` 标志位。
    ///   - mode: 创建权限（仅 O_CREAT 时有效）。
    /// - Returns: 文件 fd。
    public func openFile(at path: String, flags: Int32, mode: mode_t = 0o644) throws -> Int32 {
        // 快路径：路径够短，直接 open。
        if path.utf8.count <= Self.fastPathThreshold {
            let directory = (path as NSString).deletingLastPathComponent
            if !directory.isEmpty && directory != "/" {
                try createDirectory(at: directory)
            }
            let (rc, code) = Syscall.call { open(path, flags, mode) }
            guard rc >= 0 else { throw Self.error(from: code, path: path) }
            return rc
        }

        // 慢路径：逐级 openat 到父目录，再用 openat 打开文件。
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        if directory.isEmpty || directory == "/" {
            let (rc, code) = Syscall.call { open(path, flags, mode) }
            guard rc >= 0 else { throw Self.error(from: code, path: path) }
            return rc
        }

        let dirFD = try openDirectory(at: directory)
        defer { close(dirFD) }

        let (rc, code) = Syscall.call { openat(dirFD, name, flags, mode) }
        guard rc >= 0 else { throw Self.error(from: code, path: path) }
        return rc
    }

    /// 创建目录（含所有父目录）。
    ///
    /// 实测约束：`mkdir` 要求父目录已存在，所以必须**逐级**创建。
    ///
    /// 长路径关键：**用 `openat` + `mkdirat`（相对父目录 fd）**，
    /// 而不是 `mkdir(绝对路径)` —— 后者受 PATH_MAX(1024) 限制会返回 ENAMETOOLONG。
    /// `mkdirat` 只传**单级分量**（≤255 字节），彻底绕开路径长度限制。
    ///
    /// - Parameter path: 目录绝对路径。
    public func createDirectory(at path: String) throws {
        let components = PathUtil.components(of: path)
        guard !components.isEmpty else { return }

        let (rootRC, rootCode) = Syscall.call { open("/", O_RDONLY | O_DIRECTORY) }
        guard rootRC >= 0 else { throw Self.error(from: rootCode, path: path) }
        var currentFD: Int32 = rootRC

        for component in components {
            // 先尝试打开已存在的目录。
            var nextFD = openat(currentFD, component, O_RDONLY | O_DIRECTORY)
            if nextFD < 0 {
                let code = Syscall.currentErrno()
                guard code == ENOENT else {
                    close(currentFD)
                    throw Self.error(from: code, path: path)
                }
                // 不存在 → 用 mkdirat 逐级创建（只传单级分量，不受 PATH_MAX 限制）。
                let (mkRC, mkCode) = Syscall.call { mkdirat(currentFD, component, 0o755) }
                if mkRC != 0 && mkCode != EEXIST {
                    close(currentFD)
                    throw Self.error(from: mkCode, path: path)
                }
                nextFD = openat(currentFD, component, O_RDONLY | O_DIRECTORY)
                if nextFD < 0 {
                    let code2 = Syscall.currentErrno()
                    close(currentFD)
                    throw Self.error(from: code2, path: path)
                }
            }
            close(currentFD)
            currentFD = nextFD
        }
        close(currentFD)
    }

    /// 遍历目录项（不跟随符号链接）。
    ///
    /// - Parameter dirFD: 目录 fd。
    /// - Returns: 目录项列表。
    public func enumerateChildren(of dirFD: Int32) throws -> [DirectoryEntry] {
        var entries = [DirectoryEntry]()
        let duplicateFD = dup(dirFD)
        guard duplicateFD >= 0 else {
            throw MacCopyError.unknown(underlying: "dup 失败")
        }
        defer { close(duplicateFD) }

        // fdopendir 会接管 fd 的所有权，dup 一份避免影响调用方。
        guard let dir = fdopendir(duplicateFD) else {
            let code = Syscall.currentErrno()
            close(duplicateFD)
            throw Self.error(from: code, path: "<dirfd>")
        }
        defer { closedir(dir) }

        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw -> String in
                let bytes = raw.bindMemory(to: CChar.self)
                let length = bytes.prefix(while: { $0 != 0 }).count
                return String(decoding: bytes.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            guard name != ".", name != ".." else { continue }

            // 用 d_type 判断类型（若为未知则回退到 lstat）。
            var type = entry.pointee.d_type
            if type == DirectoryEntryType.unknown {
                type = Self.fileType(of: name, in: dirFD)
            }

            let isDirectory = (type == DirectoryEntryType.directory)
            let isSymbolicLink = (type == DirectoryEntryType.symbolicLink)
            let fileType: FileType = switch type {
            case DirectoryEntryType.directory: .directory
            case DirectoryEntryType.symbolicLink: .symbolicLink
            case DirectoryEntryType.regular: .regular
            case DirectoryEntryType.fifo: .fifo
            case DirectoryEntryType.socket: .socket
            case DirectoryEntryType.characterDevice: .characterDevice
            case DirectoryEntryType.blockDevice: .blockDevice
            default: .unknown
            }

            entries.append(
                DirectoryEntry(
                    name: name,
                    isDirectory: isDirectory,
                    isSymbolicLink: isSymbolicLink,
                    fileType: fileType
                )
            )
        }
        return entries
    }

    /// 作用域式打开目录，自动关闭。
    ///
    /// - Parameters:
    ///   - path: 目录路径。
    ///   - body: 使用 fd 的闭包。
    /// - Returns: 闭包返回值。
    public func withDirectoryHandle<T>(
        at path: String,
        _ body: (Int32) throws -> T
    ) throws -> T {
        let fd = try openDirectory(at: path)
        defer { close(fd) }
        return try body(fd)
    }

    /// 作用域式打开文件，自动关闭。
    ///
    /// - Parameters:
    ///   - path: 文件路径。
    ///   - flags: `open` 标志位。
    ///   - mode: 创建权限。
    ///   - body: 使用 fd 的闭包。
    /// - Returns: 闭包返回值。
    public func withFileHandle<T>(
        at path: String,
        flags: Int32,
        mode: mode_t = 0o644,
        _ body: (Int32) throws -> T
    ) throws -> T {
        let fd = try openFile(at: path, flags: flags, mode: mode)
        defer { close(fd) }
        return try body(fd)
    }

    // MARK: - 内部实现

    /// `d_type` 未知时用 lstat 兜底判断类型。
    private static func fileType(of name: String, in dirFD: Int32) -> UInt8 {
        var sb = stat()
        let (rc, _) = Syscall.call { fstatat(dirFD, name, &sb, AT_SYMLINK_NOFOLLOW) }
        guard rc == 0 else { return DirectoryEntryType.unknown }
        switch sb.st_mode & S_IFMT {
        case S_IFDIR: return DirectoryEntryType.directory
        case S_IFLNK: return DirectoryEntryType.symbolicLink
        case S_IFREG: return DirectoryEntryType.regular
        case S_IFIFO: return DirectoryEntryType.fifo
        case S_IFSOCK: return DirectoryEntryType.socket
        case S_IFCHR: return DirectoryEntryType.characterDevice
        case S_IFBLK: return DirectoryEntryType.blockDevice
        default: return DirectoryEntryType.unknown
        }
    }

    /// 把 errno 转成 `MacCopyError`（架构 §8.3：唯一分类入口）。
    ///
    /// - Parameters:
    ///   - code: errno 值。
    ///   - path: 相关路径。
    /// - Returns: 分类后的错误。
    static func error(from code: Int32, path: String) -> MacCopyError {
        var error = MacCopyError.fromErrno(code, path: path, underlying: Syscall.describe(code))
        // 路径过长需要真实的字节长度，而不是 errno 推断值。
        if case .pathTooLong = error {
            error = .pathTooLong(path: path, byteLength: path.utf8.count)
        }
        return error
    }
}

/// 目录项类型常量。
///
/// **必须与 Darwin 的 `DT_*` 完全一致** —— `dirent.d_type` 返回的就是这些值。
/// （我曾误用 1…7 的自造值，导致 `DT_DIR`(4) 被误判为普通文件，
///   目录的 `st_size`（APFS 上是 99）被当成文件大小计入总量。）
///
/// 实测值：`DT_UNKNOWN=0 DT_FIFO=1 DT_CHR=2 DT_DIR=4 DT_BLK=6
/// DT_REG=8 DT_LNK=10 DT_SOCK=12 DT_WHT=14`
enum DirectoryEntryType {
    /// 未知（需 lstat 兜底）。
    static let unknown: UInt8 = 0
    /// 命名管道。
    static let fifo: UInt8 = 1
    /// 字符设备。
    static let characterDevice: UInt8 = 2
    /// 目录。
    static let directory: UInt8 = 4
    /// 块设备。
    static let blockDevice: UInt8 = 6
    /// 普通文件。
    static let regular: UInt8 = 8
    /// 符号链接。
    static let symbolicLink: UInt8 = 10
    /// 套接字。
    static let socket: UInt8 = 12
}

/// 目录项。
public struct DirectoryEntry: Sendable, Equatable {
    /// 单级名称（≤255 字节）。
    public let name: String
    /// 是否为目录。
    public let isDirectory: Bool
    /// 是否为符号链接。
    public let isSymbolicLink: Bool
    /// 文件类型。
    public let fileType: FileType

    /// 构造目录项。
    public init(name: String, isDirectory: Bool, isSymbolicLink: Bool, fileType: FileType) {
        self.name = name
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.fileType = fileType
    }
}

/// 文件类型。
public enum FileType: String, Sendable, Equatable {
    /// 普通文件。
    case regular
    /// 目录。
    case directory
    /// 符号链接。
    case symbolicLink
    /// 命名管道。
    case fifo
    /// 套接字。
    case socket
    /// 字符设备。
    case characterDevice
    /// 块设备。
    case blockDevice
    /// 未知。
    case unknown
}
