import Foundation

/// schema 版本与迁移（架构 §3.2.5 / T02 施工步骤 4）。
public enum Migration {
    /// 当前 schema 版本。
    public static let currentVersion = 1

    /// 执行迁移，把数据库升级到 ``currentVersion``。
    ///
    /// - Parameter database: 数据库实例。
    public static func migrate(_ database: Database) throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL);
            """)

        let versions = try database.query(
            "SELECT version FROM schema_version;",
            bindings: []
        ) { statement -> Int64 in
            Database.integer(statement, 0)
        }

        let current = versions.max() ?? 0
        guard current < currentVersion else { return }

        if current < 1 {
            try applyVersion1(to: database)
        }

        // 记录新版本（先删后插，保证只有一行）。
        try database.execute("DELETE FROM schema_version;")
        try database.execute("INSERT INTO schema_version (version) VALUES (?);", bindings: [.integer(currentVersion)])
        Log.persistence.info("数据库迁移完成 version=\(currentVersion)")
    }

    /// v1：任务表 + 文件结果表。
    private static func applyVersion1(to database: Database) throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS tasks (
                id TEXT PRIMARY KEY NOT NULL,
                source_roots TEXT NOT NULL,
                destination_root TEXT NOT NULL,
                options TEXT NOT NULL,
                state TEXT NOT NULL,
                total_bytes INTEGER NOT NULL DEFAULT 0,
                file_count INTEGER NOT NULL DEFAULT 0,
                succeeded_count INTEGER NOT NULL DEFAULT 0,
                failed_count INTEGER NOT NULL DEFAULT 0,
                skipped_count INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL,
                finished_at REAL
            );
            """)

        try database.execute("""
            CREATE TABLE IF NOT EXISTS file_results (
                id TEXT PRIMARY KEY NOT NULL,
                task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
                source_path TEXT NOT NULL,
                destination_path TEXT NOT NULL,
                relative_path TEXT NOT NULL,
                size INTEGER NOT NULL,
                status TEXT NOT NULL,
                error_kind TEXT,
                error_message TEXT,
                attempt_count INTEGER NOT NULL DEFAULT 0,
                duration REAL,
                started_at REAL NOT NULL
            );
            """)

        try database.execute("CREATE INDEX IF NOT EXISTS idx_file_results_task ON file_results(task_id);")
        try database.execute("CREATE INDEX IF NOT EXISTS idx_file_results_status ON file_results(task_id, status);")
        try database.execute("CREATE INDEX IF NOT EXISTS idx_tasks_created_at ON tasks(created_at DESC);")
    }
}
