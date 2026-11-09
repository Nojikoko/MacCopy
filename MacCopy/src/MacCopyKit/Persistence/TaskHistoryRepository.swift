import Foundation
import SQLite3

/// 任务历史仓库。协议便于测试时用内存实现替换（架构 §3.2.5）。
public protocol TaskHistoryRepository: Sendable {
    /// 插入任务。
    func createTask(_ record: TaskRecord) async throws
    /// 更新任务。
    func updateTask(_ record: TaskRecord) async throws
    /// 按 ID 查询任务。
    func task(id: UUID) async throws -> TaskRecord?
    /// 分页查询任务列表（按创建时间倒序）。
    func listTasks(limit: Int, offset: Int) async throws -> [TaskRecord]
    /// 追加文件结果。
    func appendFileResult(_ result: FileResultRecord) async throws
    /// 查询任务的文件结果。
    func fileResults(taskID: UUID, onlyFailed: Bool) async throws -> [FileResultRecord]
    /// 清理早于指定日期的任务。
    func purge(olderThan: Date) async throws
}

/// 任务历史记录（持久化形态）。
///
/// 可变字段用 `var`，便于在任务生命周期中更新状态与计数后写回。
public struct TaskRecord: Sendable, Codable, Equatable {
    /// 任务 ID。
    public let id: UUID
    /// 源根路径列表（JSON 数组）。
    public let sourceRoots: [String]
    /// 目标根路径。
    public let destinationRoot: String
    /// 传输配置（JSON）。
    public let options: TransferOptions
    /// 任务状态。
    public var state: TaskState
    /// 总字节数。
    public var totalBytes: Int64
    /// 文件总数。
    public var fileCount: Int
    /// 成功数。
    public var succeededCount: Int
    /// 失败数。
    public var failedCount: Int
    /// 跳过数。
    public var skippedCount: Int
    /// 创建时间。
    public let createdAt: Date
    /// 结束时间（未结束为 nil）。
    public var finishedAt: Date?

    /// 构造记录。
    public init(
        id: UUID,
        sourceRoots: [String],
        destinationRoot: String,
        options: TransferOptions = .default,
        state: TaskState,
        totalBytes: Int64 = 0,
        fileCount: Int = 0,
        succeededCount: Int = 0,
        failedCount: Int = 0,
        skippedCount: Int = 0,
        createdAt: Date = Date(),
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.sourceRoots = sourceRoots
        self.destinationRoot = destinationRoot
        self.options = options
        self.state = state
        self.totalBytes = totalBytes
        self.fileCount = fileCount
        self.succeededCount = succeededCount
        self.failedCount = failedCount
        self.skippedCount = skippedCount
        self.createdAt = createdAt
        self.finishedAt = finishedAt
    }
}

/// 单文件结果记录（持久化形态）。
public struct FileResultRecord: Sendable, Codable, Equatable {
    /// 结果 ID。
    public let id: UUID
    /// 所属任务 ID。
    public let taskID: UUID
    /// 源路径。
    public let sourcePath: String
    /// 目标路径。
    public let destinationPath: String
    /// 相对路径。
    public let relativePath: String
    /// 文件大小。
    public let size: Int64
    /// 最终状态。
    public let status: FileStatus
    /// 错误分类标识。
    public let errorKind: String?
    /// 错误中文文案。
    public let errorMessage: String?
    /// 尝试次数。
    public let attemptCount: Int
    /// 耗时（秒）。
    public let duration: TimeInterval?
    /// 开始时间。
    public let startedAt: Date

    /// 构造记录。
    public init(
        id: UUID,
        taskID: UUID,
        sourcePath: String,
        destinationPath: String,
        relativePath: String,
        size: Int64,
        status: FileStatus,
        errorKind: String? = nil,
        errorMessage: String? = nil,
        attemptCount: Int = 0,
        duration: TimeInterval? = nil,
        startedAt: Date = Date()
    ) {
        self.id = id
        self.taskID = taskID
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.relativePath = relativePath
        self.size = size
        self.status = status
        self.errorKind = errorKind
        self.errorMessage = errorMessage
        self.attemptCount = attemptCount
        self.duration = duration
        self.startedAt = startedAt
    }
}

/// 基于 SQLite 的任务历史仓库实现。
public final class SQLiteTaskHistoryRepository: TaskHistoryRepository, @unchecked Sendable {
    /// 数据库实例。
    private let database: Database
    /// JSON 编解码器。
    private let encoder = JSONEncoder()
    /// JSON 解码器。
    private let decoder = JSONDecoder()

    /// 构造仓库。
    ///
    /// - Parameter database: 已迁移的数据库实例。
    public init(database: Database) {
        self.database = database
    }

    /// 插入任务。
    public func createTask(_ record: TaskRecord) async throws {
        try database.execute(
            """
            INSERT INTO tasks (
                id, source_roots, destination_root, options, state,
                total_bytes, file_count, succeeded_count, failed_count, skipped_count,
                created_at, finished_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .text(record.id.uuidString),
                .text(try encodeArray(record.sourceRoots)),
                .text(record.destinationRoot),
                .text(try encodeOptions(record.options)),
                .text(record.state.rawValue),
                .integer(record.totalBytes),
                .integer(record.fileCount),
                .integer(record.succeededCount),
                .integer(record.failedCount),
                .integer(record.skippedCount),
                .date(record.createdAt),
                .date(record.finishedAt),
            ]
        )
    }

    /// 更新任务。
    public func updateTask(_ record: TaskRecord) async throws {
        try database.execute(
            """
            UPDATE tasks SET
                source_roots = ?, destination_root = ?, options = ?, state = ?,
                total_bytes = ?, file_count = ?, succeeded_count = ?, failed_count = ?,
                skipped_count = ?, finished_at = ?
            WHERE id = ?;
            """,
            bindings: [
                .text(try encodeArray(record.sourceRoots)),
                .text(record.destinationRoot),
                .text(try encodeOptions(record.options)),
                .text(record.state.rawValue),
                .integer(record.totalBytes),
                .integer(record.fileCount),
                .integer(record.succeededCount),
                .integer(record.failedCount),
                .integer(record.skippedCount),
                .date(record.finishedAt),
                .text(record.id.uuidString),
            ]
        )
    }

    /// 按 ID 查询任务。
    public func task(id: UUID) async throws -> TaskRecord? {
        let rows = try database.query(
            """
            SELECT id, source_roots, destination_root, options, state,
                   total_bytes, file_count, succeeded_count, failed_count, skipped_count,
                   created_at, finished_at
            FROM tasks WHERE id = ?;
            """,
            bindings: [.text(id.uuidString)]
        ) { statement -> TaskRecord in
            try decodeTask(statement)
        }
        return rows.first
    }

    /// 分页查询任务列表（按创建时间倒序）。
    public func listTasks(limit: Int, offset: Int) async throws -> [TaskRecord] {
        try database.query(
            """
            SELECT id, source_roots, destination_root, options, state,
                   total_bytes, file_count, succeeded_count, failed_count, skipped_count,
                   created_at, finished_at
            FROM tasks
            ORDER BY created_at DESC
            LIMIT ? OFFSET ?;
            """,
            bindings: [.integer(max(0, limit)), .integer(max(0, offset))]
        ) { statement -> TaskRecord in
            try decodeTask(statement)
        }
    }

    /// 追加文件结果。
    public func appendFileResult(_ result: FileResultRecord) async throws {
        try database.execute(
            """
            INSERT OR REPLACE INTO file_results (
                id, task_id, source_path, destination_path, relative_path, size,
                status, error_kind, error_message, attempt_count, duration, started_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .text(result.id.uuidString),
                .text(result.taskID.uuidString),
                .text(result.sourcePath),
                .text(result.destinationPath),
                .text(result.relativePath),
                .integer(result.size),
                .text(result.status.rawValue),
                .text(result.errorKind),
                .text(result.errorMessage),
                .integer(result.attemptCount),
                result.duration.map { SQLiteValue.real($0) } ?? .null,
                .date(result.startedAt),
            ]
        )
    }

    /// 查询任务的文件结果。
    public func fileResults(taskID: UUID, onlyFailed: Bool) async throws -> [FileResultRecord] {
        let sql: String
        let bindings: [SQLiteValue]
        if onlyFailed {
            sql = """
                SELECT id, task_id, source_path, destination_path, relative_path, size,
                       status, error_kind, error_message, attempt_count, duration, started_at
                FROM file_results WHERE task_id = ? AND status = ? ORDER BY started_at ASC;
                """
            bindings = [.text(taskID.uuidString), .text(FileStatus.failed.rawValue)]
        } else {
            sql = """
                SELECT id, task_id, source_path, destination_path, relative_path, size,
                       status, error_kind, error_message, attempt_count, duration, started_at
                FROM file_results WHERE task_id = ? ORDER BY started_at ASC;
                """
            bindings = [.text(taskID.uuidString)]
        }
        return try database.query(sql, bindings: bindings) { statement -> FileResultRecord in
            FileResultRecord(
                id: UUID(uuidString: Database.text(statement, 0) ?? "") ?? UUID(),
                taskID: UUID(uuidString: Database.text(statement, 1) ?? "") ?? UUID(),
                sourcePath: Database.text(statement, 2) ?? "",
                destinationPath: Database.text(statement, 3) ?? "",
                relativePath: Database.text(statement, 4) ?? "",
                size: Database.integer(statement, 5),
                status: FileStatus(rawValue: Database.text(statement, 6) ?? "") ?? .failed,
                errorKind: Database.text(statement, 7),
                errorMessage: Database.text(statement, 8),
                attemptCount: Int(Database.integer(statement, 9)),
                duration: Database.isNull(statement, 10) ? nil : Database.real(statement, 10),
                startedAt: Date(timeIntervalSince1970: Database.real(statement, 11))
            )
        }
    }

    /// 清理早于指定日期的任务（文件结果由外键级联删除）。
    public func purge(olderThan: Date) async throws {
        try database.execute(
            "DELETE FROM tasks WHERE created_at < ?;",
            bindings: [.date(olderThan)]
        )
    }

    // MARK: - 编解码

    /// 编码字符串数组为 JSON。
    private func encodeArray(_ values: [String]) throws -> String {
        let data = try encoder.encode(values)
        return String(decoding: data, as: UTF8.self)
    }

    /// 编码配置为 JSON。
    private func encodeOptions(_ options: TransferOptions) throws -> String {
        let data = try encoder.encode(options)
        return String(decoding: data, as: UTF8.self)
    }

    /// 从结果行解码任务记录。
    private func decodeTask(_ statement: OpaquePointer) throws -> TaskRecord {
        let sourceRootsJSON = Database.text(statement, 1) ?? "[]"
        let optionsJSON = Database.text(statement, 3) ?? "{}"
        let sourceRoots = (try? decoder.decode([String].self, from: Data(sourceRootsJSON.utf8))) ?? []
        let options = (try? decoder.decode(TransferOptions.self, from: Data(optionsJSON.utf8))) ?? .default
        let finishedRaw = Database.real(statement, 11)
        return TaskRecord(
            id: UUID(uuidString: Database.text(statement, 0) ?? "") ?? UUID(),
            sourceRoots: sourceRoots,
            destinationRoot: Database.text(statement, 2) ?? "",
            options: options,
            state: TaskState(rawValue: Database.text(statement, 4) ?? "") ?? .pending,
            totalBytes: Database.integer(statement, 5),
            fileCount: Int(Database.integer(statement, 6)),
            succeededCount: Int(Database.integer(statement, 7)),
            failedCount: Int(Database.integer(statement, 8)),
            skippedCount: Int(Database.integer(statement, 9)),
            createdAt: Date(timeIntervalSince1970: Database.real(statement, 10)),
            finishedAt: Database.isNull(statement, 11)
                ? nil : Date(timeIntervalSince1970: finishedRaw)
        )
    }
}
