import Foundation

/// 队列状态重启恢复（PRD P0-09 ②）。
///
/// 职责：把 `TaskQueueStore` 里持久化的 pending / paused 任务接到 `CopyEngine`，
/// 每个任务用**独立的 engine 实例**执行（因为 `CopyEngine` 是 actor 且状态机是单任务的），
/// 单任务失败或取消**不影响**其他任务。
///
/// 与架构 §8.6 一致：引擎只发 `TransferEvent`，协调器不依赖任何 UI 类型。
///
/// 用 `actor` 而非 `NSLock`：Swift 6 严格并发禁止在 async 上下文里调用 `NSLock.lock()`。
public actor TaskQueueRecovery {
    /// 单个任务的恢复结果。
    public struct Outcome: Sendable, Equatable {
        /// 任务 ID。
        public let taskID: UUID
        /// 是否被取消。
        public let wasCancelled: Bool
        /// 成功文件数。
        public let succeededCount: Int
        /// 失败文件数。
        public let failedCount: Int
        /// 是否跳过（终态任务）。
        public let wasSkipped: Bool

        /// 构造结果。
        public init(
            taskID: UUID,
            wasCancelled: Bool,
            succeededCount: Int,
            failedCount: Int,
            wasSkipped: Bool
        ) {
            self.taskID = taskID
            self.wasCancelled = wasCancelled
            self.succeededCount = succeededCount
            self.failedCount = failedCount
            self.wasSkipped = wasSkipped
        }
    }

    /// 队列存储。
    private let store: TaskQueueStore
    /// engine 工厂（每个任务一个新实例）。
    private let makeEngine: @Sendable () -> CopyEngine
    /// 批次工厂（由 `PlanBuilder` 提供）。
    private let makeBatches: @Sendable (TransferTask) -> AsyncThrowingStream<PlanBuilder.Batch, Error>
    /// 每个任务的运行句柄（用于单任务取消）。
    private var handles: [UUID: Task<TransferSummary, Error>] = [:]

    /// 构造恢复协调器。
    ///
    /// - Parameters:
    ///   - store: 队列存储。
    ///   - makeEngine: engine 工厂。
    ///   - makeBatches: 批次工厂。
    public init(
        store: TaskQueueStore,
        makeEngine: @escaping @Sendable () -> CopyEngine,
        makeBatches: @escaping @Sendable (TransferTask) -> AsyncThrowingStream<PlanBuilder.Batch, Error>
    ) {
        self.store = store
        self.makeEngine = makeEngine
        self.makeBatches = makeBatches
    }

    /// 读取待恢复任务（按 `pendingTaskIDs()` 的创建顺序，过滤终态）。
    ///
    /// - Returns: 待恢复任务列表。
    /// - Throws: 存储读取失败。
    public func recoverableTasks() throws -> [TransferTask] {
        let ids = try store.pendingTaskIDs()
        guard !ids.isEmpty else { return [] }
        let all = try store.loadTasks()
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }.filter { !$0.state.isTerminal }
    }

    /// 启动所有待恢复任务，并等待全部结束。
    ///
    /// 每个任务独立 `Task`，失败/取消互不影响。
    ///
    /// - Returns: 每个任务的结果。
    /// - Throws: 读取队列失败。
    public func recoverAll() async throws -> [Outcome] {
        let tasks = try recoverableTasks()

        // 为每个任务创建独立 engine + 独立 Task。
        for task in tasks where handles[task.id] == nil {
            let engine = makeEngine()
            let batches = makeBatches(task)
            let handle = Task<TransferSummary, Error> {
                await engine.run(task: task, batches: batches)
            }
            handles[task.id] = handle
        }
        let snapshot = handles

        var outcomes = [Outcome]()
        outcomes.reserveCapacity(tasks.count)
        for task in tasks {
            guard let handle = snapshot[task.id] else {
                outcomes.append(
                    Outcome(
                        taskID: task.id,
                        wasCancelled: false,
                        succeededCount: 0,
                        failedCount: 0,
                        wasSkipped: true
                    )
                )
                continue
            }
            do {
                let summary = try await handle.value
                outcomes.append(
                    Outcome(
                        taskID: task.id,
                        wasCancelled: false,
                        succeededCount: summary.succeededCount,
                        failedCount: summary.failedCount,
                        wasSkipped: false
                    )
                )
                // 任务完成（非取消）→ 从队列移除，避免下次重启重复执行。
                try? store.delete(taskID: task.id)
            } catch is CancellationError {
                outcomes.append(
                    Outcome(
                        taskID: task.id,
                        wasCancelled: true,
                        succeededCount: 0,
                        failedCount: 0,
                        wasSkipped: false
                    )
                )
            } catch {
                outcomes.append(
                    Outcome(
                        taskID: task.id,
                        wasCancelled: false,
                        succeededCount: 0,
                        failedCount: 1,
                        wasSkipped: false
                    )
                )
            }
        }

        for task in tasks { handles.removeValue(forKey: task.id) }
        return outcomes
    }

    /// 只取消一个任务（不影响其他任务）。
    ///
    /// - Parameter taskID: 任务 ID。
    /// - Returns: 是否存在并已发出取消。
    @discardableResult
    public func cancel(taskID: UUID) -> Bool {
        guard let handle = handles[taskID] else { return false }
        handle.cancel()
        return true
    }

    /// 当前正在恢复的任务 ID 列表。
    public var runningTaskIDs: [UUID] {
        Array(handles.keys)
    }

    /// 只启动恢复（不等待），用于「取消单任务不影响其他」的场景。
    ///
    /// 调用 `cancel(taskID:)` 后再用 `awaitOutcomes()` 收结果。
    ///
    /// - Returns: 已启动的任务 ID 列表。
    @discardableResult
    public func startRecovery() async throws -> [UUID] {
        let tasks = try recoverableTasks()
        for task in tasks where handles[task.id] == nil {
            let engine = makeEngine()
            let batches = makeBatches(task)
            handles[task.id] = Task<TransferSummary, Error> {
                await engine.run(task: task, batches: batches)
            }
        }
        return tasks.map(\.id)
    }

    /// 等待所有已启动任务结束并收集结果。
    ///
    /// - Returns: 每个任务的结果。
    public func awaitOutcomes() async -> [Outcome] {
        let snapshot = handles
        var outcomes = [Outcome]()
        outcomes.reserveCapacity(snapshot.count)
        for (id, handle) in snapshot {
            do {
                let summary = try await handle.value
                outcomes.append(
                    Outcome(
                        taskID: id,
                        wasCancelled: false,
                        succeededCount: summary.succeededCount,
                        failedCount: summary.failedCount,
                        wasSkipped: false
                    )
                )
                try? store.delete(taskID: id)
            } catch is CancellationError {
                outcomes.append(
                    Outcome(
                        taskID: id,
                        wasCancelled: true,
                        succeededCount: 0,
                        failedCount: 0,
                        wasSkipped: false
                    )
                )
            } catch {
                outcomes.append(
                    Outcome(
                        taskID: id,
                        wasCancelled: false,
                        succeededCount: 0,
                        failedCount: 1,
                        wasSkipped: false
                    )
                )
            }
        }
        handles.removeAll()
        return outcomes
    }
}
