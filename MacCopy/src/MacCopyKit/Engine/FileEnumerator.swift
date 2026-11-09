import Foundation
import Darwin

/// 目录递归枚举器。
///
/// 架构 §5 / Q-A8：枚举**流式产出**（不把全量条目塞进内存），
/// 配合 `PlanBuilder` 分批处理，10 万文件内存占用 ≤ 300 MB。
///
/// 符号链接策略：默认**不跟随**符号链接（避免循环引用），
/// 但会把符号链接本身作为一个条目产出（PRD P0-06 要求保留符号链接）。
public struct FileEnumerator: Sendable {
    /// 枚举选项。
    public struct Options: Sendable {
        /// 是否包含隐藏文件。
        public var includeHidden: Bool
        /// 是否跟随符号链接指向的目录（默认 false，防循环）。
        public var followSymbolicLinks: Bool
        /// 是否探测稀疏信息。
        public var probeSparse: Bool
        /// 最大递归深度（0 = 不限）。
        public var maxDepth: Int

        /// 构造枚举选项。
        public init(
            includeHidden: Bool = true,
            followSymbolicLinks: Bool = false,
            probeSparse: Bool = true,
            maxDepth: Int = 0
        ) {
            self.includeHidden = includeHidden
            self.followSymbolicLinks = followSymbolicLinks
            self.probeSparse = probeSparse
            self.maxDepth = maxDepth
        }

        /// 默认选项。
        public static let `default` = Options()
    }

    /// 构造枚举器。
    public init() {}

    /// 枚举单个源根，产出条目。
    ///
    /// 源根可以是**目录**（递归枚举）或**单个文件**（产出单条）——
    /// 用户拖入一个文件是核心场景（PRD P0-01「拖放文件或文件夹」）。
    ///
    /// 条目是 **struct 紧凑布局**（Q-A8），流式产出，不累积全量。
    ///
    /// - Parameters:
    ///   - sourceRoot: 源根路径（文件或目录）。
    ///   - destinationRoot: 目标根路径（用于算相对路径）。
    ///   - options: 枚举选项。
    /// - Returns: 条目异步序列。
    /// - Throws: 源根不可访问时抛 `MacCopyError.sourceUnreadable`（**不静默产出 0 条**）。
    public func enumerate(
        sourceRoot: String,
        destinationRoot: String,
        options: Options = .default
    ) -> AsyncThrowingStream<FileEntry, Error> {
        AsyncThrowingStream { continuation in
            let walker = PathWalker()
            let task = Task {
                do {
                    // ① 源根级别：不可访问 → **抛错**（不能像递归子目录那样
                    //    「记日志后继续」，否则用户看到的是「任务成功但 0 文件」）。
                    guard let rootMetadata = MetadataOps.metadata(at: sourceRoot) else {
                        let code = errno
                        throw MacCopyError.sourceUnreadable(
                            path: sourceRoot,
                            underlying: "errno=\(code) \(Syscall.describe(code))"
                        )
                    }

                    if rootMetadata.isSymbolicLink {
                        // 源根本身是符号链接：跟随它判定真实类型。
                        let resolved = Self.resolveLink(at: sourceRoot)
                        guard let target = resolved,
                              let targetMetadata = MetadataOps.metadata(at: target)
                        else {
                            let code = errno
                            throw MacCopyError.sourceUnreadable(
                                path: sourceRoot,
                                underlying: "符号链接目标不可访问 errno=\(code)"
                            )
                        }
                        if targetMetadata.isDirectory {
                            try await Self.walk(
                                walker: walker,
                                directory: sourceRoot,
                                relativePrefix: "",
                                destinationRoot: destinationRoot,
                                depth: 0,
                                options: options,
                                continuation: continuation
                            )
                        } else {
                            continuation.yield(
                                Self.singleFileEntry(
                                    at: sourceRoot,
                                    relativePath: (sourceRoot as NSString).lastPathComponent,
                                    metadata: targetMetadata,
                                    options: options
                                )
                            )
                        }
                    } else if rootMetadata.isDirectory {
                        // ② 源根是目录：原有递归逻辑。
                        try await Self.walk(
                            walker: walker,
                            directory: sourceRoot,
                            relativePrefix: "",
                            destinationRoot: destinationRoot,
                            depth: 0,
                            options: options,
                            continuation: continuation
                        )
                    } else {
                        // ③ 源根是单个文件：产出一条，relativePath = 文件名本身。
                        continuation.yield(
                            Self.singleFileEntry(
                                at: sourceRoot,
                                relativePath: (sourceRoot as NSString).lastPathComponent,
                                metadata: rootMetadata,
                                options: options
                            )
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 构造「源根为单个文件」时的条目。
    private static func singleFileEntry(
        at path: String,
        relativePath: String,
        metadata: MetadataOps.Metadata,
        options: Options
    ) -> FileEntry {
        FileEntry(
            sourcePath: path,
            relativePath: relativePath,
            isDirectory: false,
            size: metadata.size,
            allocatedSize: metadata.allocatedSize,
            isSymbolicLink: false,
            linkDestination: nil,
            isHidden: (relativePath as NSString).lastPathComponent.hasPrefix("."),
            isSparse: options.probeSparse ? metadata.isSparse : false,
            signature: FileEnumerator.signature(at: path),
            mode: metadata.mode
        )
    }

    /// 解析符号链接指向的**绝对路径**（相对链接基于其所在目录解析）。
    private static func resolveLink(at path: String) -> String? {
        guard let target = readLinkDestination(at: path) else { return nil }
        if target.hasPrefix("/") { return target }
        let parent = (path as NSString).deletingLastPathComponent
        return PathUtil.join(parent, target)
    }

    /// 递归遍历实现。
    ///
    /// - Parameters:
    ///   - walker: 路径访问器。
    ///   - directory: 当前目录。
    ///   - relativePrefix: 相对目标根的路径前缀。
    ///   - destinationRoot: 目标根。
    ///   - depth: 当前深度。
    ///   - options: 枚举选项。
    ///   - continuation: 流续体。
    /// - Throws: `MacCopyError`。
    private static func walk(
        walker: PathWalker,
        directory: String,
        relativePrefix: String,
        destinationRoot: String,
        depth: Int,
        options: Options,
        continuation: AsyncThrowingStream<FileEntry, Error>.Continuation
    ) async throws {
        if Task.isCancelled { return }
        if options.maxDepth > 0, depth > options.maxDepth { return }

        let entries: [DirectoryEntry]
        do {
            entries = try walker.withDirectoryHandle(at: directory) { dirFD in
                try walker.enumerateChildren(of: dirFD)
            }
        } catch {
            // 单个目录读不出来不应中断整个任务（记日志，继续）。
            Log.engine.error("枚举目录失败 path=\(directory, privacy: .private)")
            return
        }

        // 排序保证确定性（复制顺序可复现）。
        for entry in entries.sorted(by: { $0.name < $1.name }) {
            if Task.isCancelled { return }
            if !options.includeHidden, entry.name.hasPrefix(".") { continue }

            let sourcePath = PathUtil.join(directory, entry.name)
            let relativePath = relativePrefix.isEmpty
                ? entry.name
                : PathUtil.join(relativePrefix, entry.name)

            // 符号链接：产出条目本身，不递归进入（除非显式允许）。
            if entry.isSymbolicLink {
                let linkDestination = Self.readLinkDestination(at: sourcePath)
                let fileEntry = FileEntry(
                    sourcePath: sourcePath,
                    relativePath: relativePath,
                    isDirectory: false,
                    size: 0,
                    allocatedSize: 0,
                    isSymbolicLink: true,
                    linkDestination: linkDestination,
                    isHidden: entry.name.hasPrefix("."),
                    isSparse: false,
                    signature: Self.signature(at: sourcePath),
                    mode: Self.mode(at: sourcePath)
                )
                continuation.yield(fileEntry)
                continue
            }

            if entry.isDirectory {
                // 目录条目本身也要产出（用于创建目标目录结构）。
                let fileEntry = FileEntry(
                    sourcePath: sourcePath,
                    relativePath: relativePath,
                    isDirectory: true,
                    size: 0,
                    allocatedSize: 0,
                    isHidden: entry.name.hasPrefix("."),
                    isSparse: false,
                    signature: Self.signature(at: sourcePath),
                    mode: Self.mode(at: sourcePath)
                )
                continuation.yield(fileEntry)

                try await walk(
                    walker: walker,
                    directory: sourcePath,
                    relativePrefix: relativePath,
                    destinationRoot: destinationRoot,
                    depth: depth + 1,
                    options: options,
                    continuation: continuation
                )
                continue
            }

            // 普通文件。
            let metadata = MetadataOps.metadata(at: sourcePath)
            let size = metadata?.size ?? 0
            let allocated = metadata?.allocatedSize ?? 0
            let isSparse = options.probeSparse ? (metadata?.isSparse ?? false) : false

            let fileEntry = FileEntry(
                sourcePath: sourcePath,
                relativePath: relativePath,
                isDirectory: false,
                size: size,
                allocatedSize: allocated,
                isHidden: entry.name.hasPrefix("."),
                isSparse: isSparse,
                signature: Self.signature(at: sourcePath),
                mode: metadata?.mode ?? 0o644
            )
            continuation.yield(fileEntry)
        }
    }

    /// 读取符号链接目标。
    ///
    /// - Parameter path: 链接路径。
    /// - Returns: 目标路径（读取失败返回 nil）。
    public static func readLinkDestination(at path: String) -> String? {
        // 实测：某些受限环境下 `readlink` 在符号链接**刚创建后立即**调用会返回
        // 长度 0（读不出内容），稍后重试则能正常读出 —— 是时序相关的不稳定行为。
        // 因此这里做有限次重试（每次间隔极短），而不是一次失败就放弃。
        for attempt in 0..<Self.readLinkRetryCount {
            if attempt > 0 {
                // 让出极短时间，给文件系统完成链接落地。
                usleep(1000)
            }
            if let value = Self.readLinkDestinationOnce(at: path) {
                return value
            }
        }
        return nil
    }

    /// `readlink` 重试次数（首次 + 重试）。
    private static let readLinkRetryCount = 5

    /// 单次读取符号链接目标。
    private static func readLinkDestinationOnce(at path: String) -> String? {
        // 坑位：必须用 `withUnsafeMutableBytes` 拿到**元素指针**。
        // 直接传 `&buffer` 传的是**数组对象**，写入位置不对，内容会错乱。
        let capacity = 1024
        var buffer = [CChar](repeating: 0, count: capacity)
        let count = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return readlink(path, base.assumingMemoryBound(to: CChar.self), capacity - 1)
        }
        guard count > 0 else { return nil }
        // readlink 返回的长度就是有效长度（不含结尾 NUL）。
        let bytes = buffer.prefix(count).map { UInt8(bitPattern: $0) }

        // 有效性校验：某些受限环境下 `readlink` 会返回无意义的二进制垃圾
        // （实测长度 5、内容为随机字节）。若直接拿去重建链接，
        // 会在目标处创建出指向乱码路径的坏链接 —— 比不重建更糟。
        // 判据：必须是合法 UTF-8，且不含控制字符（链接目标不应含 C0 控制符）。
        guard let text = String(data: Data(bytes), encoding: .utf8) else { return nil }
        guard !text.isEmpty else { return nil }
        let hasControl = text.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F
        }
        guard !hasControl else { return nil }
        return text
    }

    /// 读取文件签名（大小 / 修改时间 / inode / 设备号）。
    ///
    /// - Parameter path: 路径。
    /// - Returns: 签名（读取失败返回 nil）。
    static func signature(at path: String) -> FileSignature? {
        guard let metadata = MetadataOps.metadata(at: path) else { return nil }
        return FileSignature(
            size: metadata.size,
            modifiedAt: metadata.modifiedAt,
            inode: metadata.inode,
            deviceID: metadata.deviceID
        )
    }

    /// 读取权限位。
    ///
    /// - Parameter path: 路径。
    /// - Returns: 权限位（读取失败返回默认值）。
    static func mode(at path: String) -> UInt16 {
        MetadataOps.metadata(at: path)?.mode ?? 0o644
    }
}
