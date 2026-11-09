import Foundation
import Darwin

/// 队列状态持久化（任务恢复，PRD P0-09 ②）。
public protocol TaskQueueStore: Sendable {
    /// 读取全部持久化任务。
    func loadTasks() throws -> [TransferTask]
    /// 保存（或更新）一个任务。
    func save(_ task: TransferTask) throws
    /// 删除一个任务。
    func delete(taskID: UUID) throws
    /// 按创建顺序返回待恢复的任务 ID。
    func pendingTaskIDs() throws -> [UUID]
}

/// 基于 JSON 文件的队列状态存储实现。
public final class JSONTaskQueueStore: TaskQueueStore, @unchecked Sendable {
    /// 队列文件路径。
    public let fileURL: URL
    /// 串行队列。
    private let queue = DispatchQueue(label: "com.maccopy.queue")
    /// JSON 编解码器。
    private let encoder: JSONEncoder
    /// JSON 解码器。
    private let decoder: JSONDecoder

    /// 构造队列存储。
    ///
    /// - Parameter fileURL: 队列文件路径。nil 则使用默认 App Support 路径。
    public init(fileURL: URL? = nil) throws {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.fileURL = base
                .appendingPathComponent("MacCopy", isDirectory: true)
                .appendingPathComponent("queue.json")
        }
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        // 注意：`ensureDirectory()` 会抛错，必须放在所有 `let` 存储属性初始化之后，
        // 否则 Swift 的确定初始化检查会拒绝「先抛错再赋值 let 属性」的写法。
        try ensureDirectory()
    }

    /// 读取全部持久化任务。
    public func loadTasks() throws -> [TransferTask] {
        try queue.sync {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
            let data = try Data(contentsOf: fileURL)
            return (try? decoder.decode([TransferTask].self, from: data)) ?? []
        }
    }

    /// 保存（或更新）一个任务。
    public func save(_ task: TransferTask) throws {
        try queue.sync {
            var tasks = loadTasksUnlockedSafely()
            if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[index] = task
            } else {
                tasks.append(task)
            }
            try writeUnlocked(tasks)
        }
    }

    /// 删除一个任务。
    public func delete(taskID: UUID) throws {
        try queue.sync {
            let tasks = loadTasksUnlockedSafely()
            try writeUnlocked(tasks.filter { $0.id != taskID })
        }
    }

    /// 按创建顺序返回待恢复的任务 ID。
    public func pendingTaskIDs() throws -> [UUID] {
        // 注意：闭包内只用 `try?`，不会向外抛错，因此 `queue.sync` 不需要 `try`。
        queue.sync {
            let tasks = loadTasksUnlockedSafely()
            return tasks
                .filter { $0.state == .pending || $0.state == .paused }
                .sorted { $0.createdAt < $1.createdAt }
                .map(\.id)
        }
    }

    // MARK: - 内部实现

    /// 确保父目录存在。
    private func ensureDirectory() throws {
        let directory = fileURL.deletingLastPathComponent()
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// 读取任务（要求已在队列内）。
    private func loadTasksUnlocked() throws -> [TransferTask] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode([TransferTask].self, from: data)
    }

    /// 读取任务，失败时返回空数组（要求已在队列内）。
    private func loadTasksUnlockedSafely() -> [TransferTask] {
        (try? loadTasksUnlocked()) ?? []
    }
    /// 写入任务（要求已在队列内）。
    ///
    /// 使用「临时文件 + rename」的原子写；`rename` 不可用时降级为直接覆盖写。
    /// 注意：**不删除**临时文件 —— 它每次都会被 `data.write` 覆盖（截断），
    /// 复用同名 tmp 反而避免留下垃圾文件，也避免 `removeItem` 失败被 `try?` 静默吞掉。
    private func writeUnlocked(_ tasks: [TransferTask]) throws {
        try ensureDirectory()
        let data = try encoder.encode(tasks)
        let temporaryURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("queue.json.tmp")
        try data.write(to: temporaryURL)
        if rename(temporaryURL.path, fileURL.path) == 0 {
            return
        }
        let code = Syscall.currentErrno()
        Log.persistence.error("rename 失败，降级为直接写 errno=\(code)")
        try data.write(to: fileURL)
    }
}
