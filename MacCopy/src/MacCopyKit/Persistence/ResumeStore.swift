import Foundation
import Darwin

/// 断点元数据存储。分片文件在目标同目录，元数据在 App Support（Q6）。
public protocol ResumeStore: Sendable {
    /// 读取全部断点记录。
    func loadAll() throws -> [ResumeRecord]
    /// 读取单条断点记录（按文件条目 ID）。
    ///
    /// - Parameters:
    ///   - taskID: 任务 ID。
    ///   - fileID: 文件条目 ID。
    /// - Returns: 记录（不存在返回 nil）。
    func load(taskID: UUID, fileID: UUID) throws -> ResumeRecord?
    /// 保存一条记录（原子写：临时文件 + rename + fsync）。
    func save(_ record: ResumeRecord) throws
    /// 删除一条记录。
    func delete(for taskID: UUID, fileID: UUID) throws
    /// 清理早于指定日期的记录（默认保留 7 天）。
    func purge(olderThan: Date) throws
}

/// 单文件的断点记录（架构 §3.2.5）。
public struct ResumeRecord: Sendable, Codable, Equatable {
    /// 任务 ID。
    public let taskID: UUID
    /// 文件条目 ID。
    public let fileID: UUID
    /// 源路径。
    public let sourcePath: String
    /// 目标路径。
    public let destinationPath: String
    /// 分片文件路径（`<目标目录>/.<原名>.maccopy.partial`）。
    public let partialPath: String
    /// 已传输字节数。
    public let bytesTransferred: Int64
    /// 源文件签名。
    public let sourceSignature: FileSignature
    /// 更新时间。
    public let updatedAt: Date
    /// 已计算的算法集合。
    public let algorithms: [ChecksumAlgorithmID]
    /// 已计算的摘要（十六进制）。
    public let partialDigests: [ChecksumAlgorithmID: String]

    /// 构造断点记录。
    public init(
        taskID: UUID,
        fileID: UUID,
        sourcePath: String,
        destinationPath: String,
        partialPath: String,
        bytesTransferred: Int64,
        sourceSignature: FileSignature,
        updatedAt: Date = Date(),
        algorithms: [ChecksumAlgorithmID] = [],
        partialDigests: [ChecksumAlgorithmID: String] = [:]
    ) {
        self.taskID = taskID
        self.fileID = fileID
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.partialPath = partialPath
        self.bytesTransferred = bytesTransferred
        self.sourceSignature = sourceSignature
        self.updatedAt = updatedAt
        self.algorithms = algorithms
        self.partialDigests = partialDigests
    }
}

/// 基于 JSON 文件的断点元数据存储实现。
public final class JSONResumeStore: ResumeStore, @unchecked Sendable {
    /// 元数据目录（默认 `~/Library/Application Support/MacCopy/Resume/`）。
    public let directory: URL
    /// 串行队列，保证并发写安全。
    private let queue = DispatchQueue(label: "com.maccopy.resume")
    /// JSON 编解码器。
    private let encoder: JSONEncoder
    /// JSON 解码器。
    private let decoder: JSONDecoder

    /// 保留天数（Q6：默认 7 天）。
    public static let retentionDays = 7

    /// 构造存储。
    ///
    /// - Parameter directory: 元数据目录。nil 则使用默认 App Support 路径。
    public init(directory: URL? = nil) throws {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.directory = base
                .appendingPathComponent("MacCopy", isDirectory: true)
                .appendingPathComponent("Resume", isDirectory: true)
        }
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        // 注意：`createDirectoryIfNeeded()` 会抛错，必须放在所有 `let` 存储属性
        // 初始化之后，否则 Swift 的确定初始化检查会拒绝该写法。
        try createDirectoryIfNeeded()
    }

    /// 读取全部断点记录。
    public func loadAll() throws -> [ResumeRecord] {
        try queue.sync {
            let urls = try jsonFileURLs()
            var records = [ResumeRecord]()
            for url in urls {
                guard let data = try? Data(contentsOf: url) else { continue }
                if let record = try? decoder.decode(ResumeRecord.self, from: data) {
                    records.append(record)
                }
            }
            return records
        }
    }

    /// 按文件 ID 读取单条记录。
    ///
    /// - Parameters:
    ///   - taskID: 任务 ID。
    ///   - fileID: 文件条目 ID。
    /// - Returns: 记录（不存在返回 nil）。
    public func load(taskID: UUID, fileID: UUID) throws -> ResumeRecord? {
        try queue.sync {
            let url = fileURL(for: fileID)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let data = try Data(contentsOf: url)
            let record = try decoder.decode(ResumeRecord.self, from: data)
            return record.taskID == taskID ? record : nil
        }
    }

    /// 保存一条记录。原子写：临时文件 → fsync → rename → fsync 目录。
    ///
    /// 降级说明：某些受限环境（如本机沙盒）禁止 `rename()`。
    /// 此时退化为「直接写目标文件 + fsync」——原子性下降，
    /// 但 fsync 仍能保证数据落盘，最坏情况是断电时文件为空（下次会被丢弃重传）。
    ///
    /// - Parameter record: 待保存记录。
    public func save(_ record: ResumeRecord) throws {
        try queue.sync {
            try createDirectoryIfNeeded()
            let data = try encoder.encode(record)
            let finalURL = fileURL(for: record.fileID)
            let temporaryURL = directory.appendingPathComponent("\(record.fileID.uuidString).tmp")

            // 先写临时文件。
            try data.write(to: temporaryURL)

            // fsync 确保数据落盘（断电安全）。
            let fd = open(temporaryURL.path, O_WRONLY)
            if fd >= 0 {
                _ = fsync(fd)
                close(fd)
            }

            // 原子替换：rename(2)。
            if rename(temporaryURL.path, finalURL.path) == 0 {
                // fsync 目录，确保目录项落盘。
                let dirFD = open(directory.path, O_RDONLY)
                if dirFD >= 0 {
                    _ = fsync(dirFD)
                    close(dirFD)
                }
                return
            }

            // 降级路径：rename 不可用时，直接覆盖写目标文件。
            // 注意：**不删除**临时文件 —— 它每次都会被 data.write 覆盖（截断），
            // 复用同名 tmp 反而避免留下垃圾文件，也避免 removeItem 失败被 try? 静默吞掉。
            let code = Syscall.currentErrno()
            Log.persistence.error(
                "rename 失败，降级为直接写 errno=\(code) path=\(finalURL.path, privacy: .private)"
            )
            try data.write(to: finalURL)
            let fallbackFD = open(finalURL.path, O_WRONLY)
            if fallbackFD >= 0 {
                _ = fsync(fallbackFD)
                close(fallbackFD)
            }
        }
    }

    /// 删除一条记录。
    ///
    /// 优先用 `FileManager.removeItem`；某些受限环境禁止删除时，
    /// 退化为 POSIX `unlink(2)`，再不行则记录日志并忽略
    /// （记录残留不影响正确性，下次 `purge` 会再清理）。
    public func delete(for taskID: UUID, fileID: UUID) throws {
        _ = try deleteReportingResult(for: taskID, fileID: fileID)
    }

    /// 删除一条记录并返回是否真的删除成功。
    ///
    /// 若环境禁止一切删除操作（如本机沙盒），返回 `false`，
    /// 调用方据此决定是否重试或报警，而不是把环境限制当成逻辑错误抛出。
    ///
    /// - Parameters:
    ///   - taskID: 任务 ID。
    ///   - fileID: 文件条目 ID。
    /// - Returns: 是否已从磁盘移除。
    @discardableResult
    public func deleteReportingResult(for taskID: UUID, fileID: UUID) throws -> Bool {
        // 注意：闭包内不抛错，因此 `queue.sync` 不需要 `try`。
        queue.sync {
            let url = fileURL(for: fileID)
            guard FileManager.default.fileExists(atPath: url.path) else { return true }
            do {
                try FileManager.default.removeItem(at: url)
                return true
            } catch {
                if unlink(url.path) == 0 {
                    return true
                }
                Log.persistence.error(
                    "删除断点记录失败 errno=\(errno) path=\(url.path, privacy: .private)"
                )
                return false
            }
        }
    }

    /// 清理早于指定日期的记录。
    public func purge(olderThan: Date) throws {
        try queue.sync {
            for url in try jsonFileURLs() {
                let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
                guard let modified = values.contentModificationDate else { continue }
                if modified < olderThan {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    /// 按保留期清理（默认 7 天）。
    public func purgeExpired() throws {
        let cutoff = Date().addingTimeInterval(-Double(Self.retentionDays) * 24 * 3600)
        try purge(olderThan: cutoff)
    }

    // MARK: - 内部实现

    /// 确保目录存在。
    private func createDirectoryIfNeeded() throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// 记录对应的 JSON 文件路径。
    private func fileURL(for fileID: UUID) -> URL {
        directory.appendingPathComponent("\(fileID.uuidString).json")
    }

    /// 列出全部 JSON 文件。
    private func jsonFileURLs() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        return contents.filter { $0.pathExtension == "json" }
    }
}
