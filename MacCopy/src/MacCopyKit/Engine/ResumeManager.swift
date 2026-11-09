import Foundation
import Darwin

/// 断点续传管理器。
///
/// 架构 §3.2.5 / PRD P0-07：`.partial` 分片 + JSON 元数据配对。
///
/// 实测约束（docs/ENV-FS-CONSTRAINTS.md v3）：
/// - `rename` **不可用** → 提交（`.partial` → 正式名）用 `copyfile`，
///   且必须**先试 CLONE、失败回退 DATA**（dst 已存在时 CLONE 会 EEXIST）
/// - `unlink` **不可用** → `.partial` **不删除**，改为「7 天过期标注」
/// - 追加写可用：`open(O_WRONLY|O_CREAT)`（**绝不带 O_TRUNC**）+ `lseek(SEEK_END)`
public struct ResumeManager: Sendable {
    /// 分片文件后缀。
    public static let partialSuffix = ".maccopy.partial"
    /// 断点元数据保留天数（架构 Q6）。
    public static let retentionDays = 7

    /// 断点存储。
    private let store: ResumeStore
    /// 路径访问器。
    private let walker: PathWalker

    /// 构造断点管理器。
    ///
    /// - Parameters:
    ///   - store: 断点元数据存储。
    ///   - walker: 路径访问器。
    public init(store: ResumeStore, walker: PathWalker = PathWalker()) {
        self.store = store
        self.walker = walker
    }

    /// 计算分片文件路径。
    ///
    /// 约定：`<目标所在目录>/.<原文件名>.maccopy.partial`
    ///
    /// - Parameter destinationPath: 正式目标路径。
    /// - Returns: 分片路径。
    public static func partialPath(for destinationPath: String) -> String {
        let directory = (destinationPath as NSString).deletingLastPathComponent
        let name = (destinationPath as NSString).lastPathComponent
        return PathUtil.join(directory, ".\(name)\(partialSuffix)")
    }

    /// 查询某文件是否有可用的断点。
    ///
    /// 判定条件（架构 P0-07）：
    /// 1. 存在元数据记录
    /// 2. 源签名未变（大小 + inode + mtime 容差 1 秒）
    /// 3. 分片文件存在且大小 == 元数据记录的已传输字节数
    ///
    /// - Parameters:
    ///   - taskID: 任务 ID。
    ///   - fileID: 文件条目 ID。
    ///   - sourceSignature: 当前源签名。
    /// - Returns: 可用的断点记录（不可用返回 nil）。
    public func findResumable(
        taskID: UUID,
        fileID: UUID,
        sourceSignature: FileSignature?
    ) -> ResumeRecord? {
        guard let signature = sourceSignature else { return nil }
        guard let record = try? store.load(taskID: taskID, fileID: fileID) else { return nil }

        // 源已变化 → 断点失效（架构：不能基于旧内容续传）。
        guard record.sourceSignature.matches(signature) else {
            Log.engine.info("断点失效：源签名已变化 fileID=\(fileID, privacy: .public)")
            return nil
        }

        // 分片文件必须存在且大小匹配。
        var sb = stat()
        let (rc, _) = Syscall.call { lstat(record.partialPath, &sb) }
        guard rc == 0 else { return nil }
        guard sb.st_size == record.bytesTransferred else {
            Log.engine.info(
                "断点失效：分片大小不匹配 期望=\(record.bytesTransferred, privacy: .public) 实际=\(sb.st_size, privacy: .public)"
            )
            return nil
        }

        return record
    }

    /// 打开分片文件用于**追加写**（断点续传）。
    ///
    /// 铁律：**绝不带 `O_TRUNC`**（会截断已有内容，续传就废了）。
    ///
    /// - Parameters:
    ///   - partialPath: 分片路径。
    ///   - createIfMissing: 分片不存在时是否创建。
    /// - Returns: fd（已定位到已有字节末尾）。
    /// - Throws: `MacCopyError`。
    public func openPartialForAppend(partialPath: String, createIfMissing: Bool = true) throws -> Int32 {
        var flags = O_WRONLY
        if createIfMissing {
            flags |= O_CREAT
        }
        let (fd, code) = Syscall.call { open(partialPath, flags, 0o644) }
        guard fd >= 0 else {
            throw MacCopyError.destinationUnwritable(path: partialPath)
                .withDetail("errno=\(code) \(Syscall.describe(code))")
        }

        // 定位到已有字节末尾（追加写）。
        Syscall.resetErrno()
        let end = lseek(fd, 0, SEEK_END)
        if end < 0 {
            let seekCode = Syscall.currentErrno()
            close(fd)
            throw MacCopyError.destinationUnwritable(path: partialPath)
                .withDetail("lseek 失败 errno=\(seekCode)")
        }
        return fd
    }

    /// 重置分片（从头重传）。
    ///
    /// 用 `ftruncate(fd, 0)` 实现（实测可用，rc=0）。
    ///
    /// - Parameter partialPath: 分片路径。
    /// - Throws: `MacCopyError`。
    public func resetPartial(partialPath: String) throws {
        let (fd, _) = Syscall.call { open(partialPath, O_WRONLY | O_CREAT, 0o644) }
        guard fd >= 0 else {
            throw MacCopyError.destinationUnwritable(path: partialPath)
                .withDetail("打开分片失败")
        }
        defer { close(fd) }

        Syscall.resetErrno()
        let result = ftruncate(fd, 0)
        guard result == 0 else {
            let truncateCode = Syscall.currentErrno()
            throw MacCopyError.destinationUnwritable(path: partialPath)
                .withDetail("ftruncate 失败 errno=\(truncateCode)")
        }
    }

    /// 保存断点元数据。
    ///
    /// - Parameters:
    ///   - taskID: 任务 ID。
    ///   - entry: 文件条目。
    ///   - destinationPath: 正式目标路径。
    ///   - bytesTransferred: 已传输字节数。
    ///   - partialDigests: 已计算的摘要。
    /// - Throws: `MacCopyError`。
    public func saveCheckpoint(
        taskID: UUID,
        entry: FileEntry,
        destinationPath: String,
        bytesTransferred: Int64,
        partialDigests: [ChecksumAlgorithmID: String]
    ) throws {
        guard let signature = entry.signature else { return }
        let record = ResumeRecord(
            taskID: taskID,
            fileID: entry.id,
            sourcePath: entry.sourcePath,
            destinationPath: destinationPath,
            partialPath: Self.partialPath(for: destinationPath),
            bytesTransferred: bytesTransferred,
            sourceSignature: signature,
            algorithms: Array(partialDigests.keys),
            partialDigests: partialDigests
        )
        do {
            try store.save(record)
        } catch {
            throw MacCopyError.unknown(underlying: "保存断点元数据失败：\(error)")
        }
    }

    /// 提交分片（`.partial` → 正式文件名）。
    ///
    /// 实测约束（docs/ENV-FS-CONSTRAINTS.md v4）：
    /// - `rename` **现在可用**（守卫策略在会话期间放宽过），且是**真正的原子操作**
    /// - 但守卫可能再次收紧 → **保留 `copyfile` 作为不依赖 rename 的保险**
    ///
    /// `copyfile` 路径：先试 CLONE，失败自动回退 DATA（dst 已存在时 CLONE 会 EEXIST）。
    /// 注意：**回退必须用全新的 state**（CLONE 失败后 state 被污染，复用会 EINVAL）。
    ///
    /// - Parameters:
    ///   - partialPath: 分片路径。
    ///   - destinationPath: 正式目标路径。
    /// - Returns: 是否发生了克隆。
    /// - Throws: `MacCopyError`。
    @discardableResult
    public func commit(partialPath: String, destinationPath: String) throws -> Bool {
        // 首选 rename：原子、零拷贝。
        Syscall.resetErrno()
        let renameResult = rename(partialPath, destinationPath)
        if renameResult == 0 {
            // rename 成功 → 分片已消失，无需清理。
            return false
        }
        let renameErrno = Syscall.currentErrno()
        Log.io.info("rename 失败，回退 copyfile errno=\(renameErrno)")

        // 回退 copyfile（CLONE → EEXIST → DATA）。
        let cloned = try CopyfileBridge.commit(
            from: partialPath,
            to: destinationPath,
            attemptClone: true
        )

        // copyfile 成功后清理分片。
        // `unlink` 现在可用；若失败（守卫收紧），由 `stalePartials()` 过期标注兜底。
        Syscall.resetErrno()
        if unlink(partialPath) != 0 {
            let unlinkErrno = Syscall.currentErrno()
            Log.io.info(
                "删除分片失败，将由过期标注兜底 errno=\(unlinkErrno) path=\(partialPath, privacy: .private)"
            )
        }

        return cloned
    }

    /// 列出陈旧分片（超过保留期）。
    ///
    /// 架构 Q6 + v3 §3.3：因 `unlink` 不可用，陈旧分片**不自动删除**，
    /// 而是在 UI/报告中标注「陈旧分片（无法自动删除，请手动清理）」+ 给出路径。
    ///
    /// - Returns: 陈旧分片列表。
    public func stalePartials(now: Date = Date()) -> [StalePartial] {
        guard let records = try? store.loadAll() else { return [] }
        let cutoff = now.addingTimeInterval(-Double(Self.retentionDays) * 24 * 3600)

        return records
            .filter { $0.updatedAt < cutoff }
            .map { record in
                StalePartial(
                    taskID: record.taskID,
                    fileID: record.fileID,
                    partialPath: record.partialPath,
                    destinationPath: record.destinationPath,
                    bytesTransferred: record.bytesTransferred,
                    ageDays: Int(now.timeIntervalSince(record.updatedAt) / 86_400),
                    note: Localization.string(
                        "partial.stale.note",
                        default: "陈旧分片（无法自动删除，请手动清理）"
                    )
                )
            }
            .sorted { $0.ageDays > $1.ageDays }
    }

    /// 清理超过保留期的**元数据**（分片文件本身不动）。
    ///
    /// - Parameter now: 当前时刻。
    public func purgeExpiredMetadata(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Double(Self.retentionDays) * 24 * 3600)
        try? store.purge(olderThan: cutoff)
    }
}

/// 陈旧分片信息。
public struct StalePartial: Sendable, Equatable {
    /// 所属任务 ID。
    public let taskID: UUID
    /// 文件条目 ID。
    public let fileID: UUID
    /// 分片文件完整路径。
    public let partialPath: String
    /// 正式目标路径。
    public let destinationPath: String
    /// 已传输字节数。
    public let bytesTransferred: Int64
    /// 存在天数。
    public let ageDays: Int
    /// 提示文案。
    public let note: String

    /// 构造陈旧分片信息。
    public init(
        taskID: UUID,
        fileID: UUID,
        partialPath: String,
        destinationPath: String,
        bytesTransferred: Int64,
        ageDays: Int,
        note: String
    ) {
        self.taskID = taskID
        self.fileID = fileID
        self.partialPath = partialPath
        self.destinationPath = destinationPath
        self.bytesTransferred = bytesTransferred
        self.ageDays = ageDays
        self.note = note
    }
}

extension MacCopyError {
    /// 附加底层细节（不改变主 case，便于持久化与断言）。
    ///
    /// - Parameter detail: 细节描述。
    /// - Returns: 带细节的错误。
    func withDetail(_ detail: String) -> MacCopyError {
        switch self {
        case .destinationUnwritable(let path):
            return .unknown(underlying: "写入目标「\(path)」失败：\(detail)")
        case .unknown:
            return self
        default:
            return self
        }
    }
}
