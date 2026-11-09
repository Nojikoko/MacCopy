import Foundation
import SQLite3

/// SQLite 封装（架构 §3.2.5 / T02 施工步骤 3）。
///
/// 线程模型：`sqlite3` 连接非线程安全，所有操作统一走内部串行 `DispatchQueue`。
public final class Database: @unchecked Sendable {
    /// 数据库连接句柄。
    private var handle: OpaquePointer?
    /// 串行队列，保证连接只被一个线程访问。
    private let queue = DispatchQueue(label: "com.maccopy.db", qos: .utility)
    /// 数据库文件路径。
    public let path: String

    /// 打开数据库（不存在则创建），并设置 WAL 与外键。
    ///
    /// - Parameter path: 数据库文件路径。传 `:memory:` 创建内存库。
    public init(path: String) throws {
        self.path = path
        if path != ":memory:" {
            let directory = (path as NSString).deletingLastPathComponent
            if !directory.isEmpty {
                try FileManager.default.createDirectory(
                    atPath: directory,
                    withIntermediateDirectories: true
                )
            }
        }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "errno=\(rc)"
            if let db { sqlite3_close(db) }
            Log.persistence.error("打开数据库失败 path=\(path, privacy: .private) rc=\(rc)")
            throw MacCopyError.unknown(underlying: "打开数据库失败：\(message)")
        }
        self.handle = db

        // WAL 模式提升并发读写表现；外键约束用于级联删除。
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA foreign_keys=ON;")
        try execute("PRAGMA busy_timeout=5000;")
    }

    deinit {
        if let handle {
            sqlite3_close(handle)
        }
    }

    /// 最后一个错误信息。
    public var lastErrorMessage: String {
        guard let handle else { return "Database is not open" }
        return String(cString: sqlite3_errmsg(handle))
    }

    /// 执行无返回值语句（建表等）。
    ///
    /// - Parameter sql: SQL 语句。
    public func execute(_ sql: String) throws {
        try queue.sync {
            guard self.handle != nil else { throw MacCopyError.unknown(underlying: "数据库未打开") }
            var errorMessage: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
            guard rc == SQLITE_OK else {
                let message = errorMessage.map { String(cString: $0) } ?? "errno=\(rc)"
                if let errorMessage { sqlite3_free(errorMessage) }
                Log.persistence.error("SQL 执行失败 rc=\(rc) sql=\(sql, privacy: .private)")
                throw MacCopyError.unknown(underlying: "SQL 执行失败：\(message)")
            }
            if let errorMessage { sqlite3_free(errorMessage) }
        }
    }

    /// 执行带参数绑定的无返回值语句。
    ///
    /// - Parameters:
    ///   - sql: SQL 语句（用 `?` 占位）。
    ///   - bindings: 参数值（`nil` 表示 NULL）。
    public func execute(_ sql: String, bindings: [SQLiteValue]) throws {
        try queue.sync {
            guard self.handle != nil else { throw MacCopyError.unknown(underlying: "数据库未打开") }
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            try bind(bindings, to: statement)
            let rc = sqlite3_step(statement)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
                Log.persistence.error("SQL 执行失败 rc=\(rc) sql=\(sql, privacy: .private)")
                throw MacCopyError.unknown(underlying: "SQL 执行失败：\(lastErrorMessage)")
            }
        }
    }

    /// 查询多行。用闭包消费每一行。
    ///
    /// - Parameters:
    ///   - sql: SQL 语句（用 `?` 占位）。
    ///   - bindings: 参数值。
    ///   - consume: 行消费闭包。
    /// - Returns: 消费结果数组。
    public func query<T>(
        _ sql: String,
        bindings: [SQLiteValue] = [],
        _ consume: (OpaquePointer) throws -> T
    ) throws -> [T] {
        try queue.sync {
            guard self.handle != nil else { throw MacCopyError.unknown(underlying: "数据库未打开") }
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            try bind(bindings, to: statement)
            var results = [T]()
            while true {
                let rc = sqlite3_step(statement)
                if rc == SQLITE_ROW {
                    results.append(try consume(statement))
                } else if rc == SQLITE_DONE {
                    break
                } else {
                    Log.persistence.error("SQL 查询失败 rc=\(rc) sql=\(sql, privacy: .private)")
                    throw MacCopyError.unknown(underlying: "SQL 查询失败：\(lastErrorMessage)")
                }
            }
            return results
        }
    }

    /// 事务。闭包抛错则回滚。
    ///
    /// - Parameter body: 事务体。
    /// - Returns: 事务体返回值。
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try queue.sync {
            try executeUnlocked("BEGIN IMMEDIATE TRANSACTION;")
            do {
                let result = try body()
                try executeUnlocked("COMMIT;")
                return result
            } catch {
                try? executeUnlocked("ROLLBACK;")
                throw error
            }
        }
    }

    // MARK: - 内部实现

    /// 编译语句（要求已在队列内）。
    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let handle else { throw MacCopyError.unknown(underlying: "数据库未打开") }
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else {
            throw MacCopyError.unknown(underlying: "SQL 预处理失败：\(lastErrorMessage)")
        }
        return statement
    }

    /// 绑定参数（要求已在队列内）。
    ///
    /// `SQLITE_TRANSIENT` 至关重要：告诉 SQLite 复制字符串内容，
    /// 否则 Swift 侧临时缓冲区释放后会导致崩溃或乱码。
    private func bind(_ bindings: [SQLiteValue], to statement: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bindings.enumerated() {
            let position = Int32(index + 1)
            let rc: Int32
            switch value {
            case .null:
                rc = sqlite3_bind_null(statement, position)
            case .integer(let number):
                rc = sqlite3_bind_int64(statement, position, number)
            case .real(let number):
                rc = sqlite3_bind_double(statement, position, number)
            case .text(let string):
                rc = sqlite3_bind_text(statement, position, string, -1, transient)
            case .blob(let data):
                if data.isEmpty {
                    rc = sqlite3_bind_zeroblob(statement, position, 0)
                } else {
                    rc = data.withUnsafeBytes { buffer in
                        sqlite3_bind_blob(statement, position, buffer.baseAddress, Int32(buffer.count), transient)
                    }
                }
            }
            guard rc == SQLITE_OK else {
                throw MacCopyError.unknown(underlying: "参数绑定失败：\(lastErrorMessage)")
            }
        }
    }

    /// 执行语句（要求已在队列内）。
    private func executeUnlocked(_ sql: String) throws {
        guard let handle else { throw MacCopyError.unknown(underlying: "数据库未打开") }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard rc == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "errno=\(rc)"
            if let errorMessage { sqlite3_free(errorMessage) }
            throw MacCopyError.unknown(underlying: "SQL 执行失败：\(message)")
        }
        if let errorMessage { sqlite3_free(errorMessage) }
    }

    /// 从结果行读取文本列。
    public static func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    /// 从结果行读取整数列。
    public static func integer(_ statement: OpaquePointer, _ index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    /// 从结果行读取浮点列。
    public static func real(_ statement: OpaquePointer, _ index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }

    /// 判断指定列是否为 NULL。
    public static func isNull(_ statement: OpaquePointer, _ index: Int32) -> Bool {
        sqlite3_column_type(statement, index) == SQLITE_NULL
    }
}

/// SQLite 参数值。
public enum SQLiteValue: Sendable, Equatable {
    /// NULL。
    case null
    /// 整数。
    case integer(Int64)
    /// 浮点数。
    case real(Double)
    /// 文本。
    case text(String)
    /// 二进制数据。
    case blob(Data)

    /// 便捷构造：字符串。
    public static func text(_ value: String?) -> SQLiteValue {
        guard let value else { return .null }
        return .text(value)
    }

    /// 便捷构造：整数。
    public static func integer(_ value: Int) -> SQLiteValue {
        .integer(Int64(value))
    }

    /// 便捷构造：日期（存 Unix 时间戳）。
    public static func date(_ value: Date?) -> SQLiteValue {
        guard let value else { return .null }
        return .real(value.timeIntervalSince1970)
    }
}
