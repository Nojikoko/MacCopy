import Foundation
import Darwin

/// 复制引擎（actor）—— 编排核心。
///
/// 架构 §5 要点：
/// - 引擎**只发事件**，不直接操作 UI（架构 §8.6 单向依赖）
/// - 并发 worker 数 = `options.threadCount`（免费版已由 `AppSettings` 裁剪到 ≤ 2）
/// - 单文件失败**不中断**整个任务（继续处理其他文件）
/// - 校验失败自动重传 1 次（Q7）
/// - 状态机严格按架构 §3.1 迁移
///
/// 实测约束（docs/ENV-FS-CONSTRAINTS.md v3）：
/// - `.partial` → 正式名用 `copyfile`（`rename` 不可用），且 CLONE→EEXIST→DATA 回退
/// - `.partial` **不删除**（`unlink` 不可用）
public actor CopyEngine {
    /// 引擎配置。
    public struct Configuration: Sendable {
        /// 传输配置（已裁剪）。
        public let options: TransferOptions
        /// 断点管理器（可空 —— 不支持断点续传时传 nil）。
        public let resumeManager: ResumeManager?
        /// 冲突解析器。
        public let conflictResolver: ConflictResolver
        /// 校验器。
        public let verifier: Verifier

        /// 构造引擎配置。
        public init(
            options: TransferOptions,
            resumeManager: ResumeManager? = nil,
            conflictResolver: ConflictResolver,
            verifier: Verifier = Verifier()
        ) {
            self.options = options
            self.resumeManager = resumeManager
            self.conflictResolver = conflictResolver
            self.verifier = verifier
        }
    }

    /// 引擎状态。
    public private(set) var state: TaskState = .pending
    /// 当前进度。
    public private(set) var progress = TransferProgress()
    /// 事件发送闭包（UI 订阅）。
    private var eventSink: @Sendable (TransferEvent) async -> Void

    /// 构造引擎。
    ///
    /// - Parameters:
    ///   - configuration: 引擎配置。
    ///   - eventSink: 事件发送闭包。
    public init(
        configuration: Configuration,
        eventSink: @escaping @Sendable (TransferEvent) async -> Void
    ) {
        self.configuration = configuration
        self.eventSink = eventSink
    }

    /// 引擎配置。
    private let configuration: Configuration

    /// 进度追踪器。
    private var tracker = ProgressTracker()

    /// 切换事件接收者。
    ///
    /// - Parameter sink: 新的事件接收闭包。
    public func setEventSink(_ sink: @Sendable @escaping (TransferEvent) async -> Void) {
        self.eventSink = sink
    }

    /// 执行一次复制任务。
    ///
    /// - Parameters:
    ///   - task: 任务定义。
    ///   - batches: 计划批次（由 `PlanBuilder` 流式产出）。
    /// - Returns: 任务汇总。
    @discardableResult
    public func run(
        task: TransferTask,
        batches: AsyncThrowingStream<PlanBuilder.Batch, Error>
    ) async -> TransferSummary {
        let taskID = task.id
        let startedAt = Date()
        currentTaskID = taskID

        await transition(to: .running, taskID: taskID)

        // ① 先统计总量（需要完整遍历一次）。
        let statistics = await Self.computeStatistics(task: task, configuration: configuration)
        tracker.begin(totalBytes: statistics.totalBytes, totalFiles: statistics.totalFiles)
        progress = tracker.snapshot()

        // ② 分批处理：**逐批消费，内存占用与总文件数无关**（Q-A8）。
        let counters = OutcomeCounter()
        let workerCount = max(1, min(configuration.options.threadCount, 8))

        do {
            for try await batch in batches {
                if Task.isCancelled {
                    await transition(to: .cancelled, taskID: taskID)
                    return await makeSummary(
                        taskID: taskID,
                        startedAt: startedAt,
                        statistics: statistics,
                        counters: counters
                    )
                }

                // 本批次的所有目录先建（枚举器按「父目录 → 子项」深度优先产出，
                // 但批次边界可能把父目录与子文件切到不同批次）。
                for entry in batch.entries where entry.isDirectory {
                    await createDirectory(for: entry, task: task)
                }

                // 再处理本批次的文件。
                var files = [FileEntry]()
                for entry in batch.entries where !entry.isDirectory {
                    files.append(entry)
                }

                guard !files.isEmpty else { continue }

                // 本批次的文件交给并发 worker。
                let outcomes = await Self.runWorkers(
                    files: files,
                    workerCount: workerCount,
                    configuration: configuration,
                    task: task,
                    tracker: { [weak self] bytes in
                        await self?.addTransferred(bytes: bytes)
                    },
                    emit: { [weak self] event in
                        await self?.emit(event)
                    }
                )
                for outcome in outcomes {
                    await counters.add(outcome)
                    // QA BUG-06：文件口径进度此前从未累加，导致 UI 的
                    // 「已完成/失败/跳过」与文件进度条恒为 0（字节口径是对的）。
                    switch outcome.status {
                    case .succeeded: tracker.completeFile()
                    case .failed: tracker.failFile()
                    case .skipped: tracker.skipFile()
                    case .cancelled, .queued, .transferring, .verifying: break
                    }
                }            }
        } catch {
            // 枚举失败（如源根不可访问）：必须**计入失败**，否则汇总显示
            // 「成功 0 / 失败 0」，用户无法区分「没有文件」与「出错了」。
            Log.engine.error("枚举失败：\(error.localizedDescription)")
            await counters.addEnumerationFailure(error)
            await transition(to: .partialFailed, taskID: taskID)
            progress = tracker.snapshot()
            return await makeSummary(
                taskID: taskID,
                startedAt: startedAt,
                statistics: statistics,
                counters: counters
            )
        }

        // ③ 汇总。
        // BUG-06：文件口径计数在批次循环里累加到 tracker，但 `progress` 快照
        // 只在 addTransferred 时刷新过；这里必须再刷新一次，否则 UI 读到的
        // completedFiles/failedFiles/skippedFiles 仍是 0。
        progress = tracker.snapshot()
        let snapshot = await counters.snapshot()
        let finalState: TaskState = snapshot.failed > 0 ? .partialFailed : .succeeded
        await transition(to: finalState, taskID: taskID)

        let summary = TransferSummary(
            taskID: taskID,
            succeededCount: snapshot.succeeded,
            failedCount: snapshot.failed,
            skippedCount: snapshot.skipped,
            totalBytes: statistics.totalBytes,
            transferredBytes: tracker.snapshot().transferredBytes,
            duration: Date().timeIntervalSince(startedAt),
            degradedCount: snapshot.degraded
        )

        // ④ 校验清单落盘（PRD P1-07）：用户勾选时，把每个成功文件的目标摘要
        //    写到目标目录，格式兼容 `shasum -c`。
        if configuration.options.generateChecksumFile {
            let groups = await counters.checksumGroups(destinationRoot: task.destinationRoot)
            for (algorithm, entries) in groups where !entries.isEmpty {
                let url = URL(fileURLWithPath: task.destinationRoot)
                    .appendingPathComponent("MacCopy.\(ChecksumFileWriter.fileExtension(for: algorithm))")
                do {
                    try ChecksumFileWriter.write(entries: entries, algorithm: algorithm, to: url)
                } catch {
                    Log.engine.error(
                        "校验清单写入失败 algorithm=\(algorithm.rawValue, privacy: .public) err=\(error.localizedDescription, privacy: .private)"
                    )
                }
            }
        }

        await emit(.taskFinished(taskID: taskID, summary: summary))
        return summary
    }

    // MARK: - Worker

    /// 并发 worker 组。
    ///
    /// - Parameters:
    ///   - files: 待处理文件。
    ///   - workerCount: worker 数。
    ///   - configuration: 引擎配置。
    ///   - task: 任务定义。
    ///   - tracker: 进度累加回调。
    ///   - emit: 事件发送回调。
    /// - Returns: 每个文件的处理结果。
    private static func runWorkers(
        files: [FileEntry],
        workerCount: Int,
        configuration: Configuration,
        task: TransferTask,
        tracker: @escaping @Sendable (Int64) async -> Void,
        emit: @escaping @Sendable (TransferEvent) async -> Void
    ) async -> [FileOutcome] {
        guard !files.isEmpty else { return [] }

        // 用共享索引实现「工作窃取」：每个 worker 从原子游标取下一个任务。
        let cursor = AtomicCounter()
        let resultBox = ResultBox()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<workerCount {
                group.addTask {
                    while true {
                        let index = cursor.next()
                        guard index < files.count else { break }
                        let entry = files[index]

                        let outcome = await Self.processFile(
                            entry: entry,
                            configuration: configuration,
                            task: task,
                            tracker: tracker,
                            emit: emit
                        )
                        resultBox.append(outcome)
                    }
                }
            }
        }

        return resultBox.snapshot()
    }

    /// 处理单个文件（一个 worker 的工作单元）。
    ///
    /// - Parameters:
    ///   - entry: 文件条目。
    ///   - configuration: 引擎配置。
    ///   - task: 任务定义。
    ///   - tracker: 进度累加回调。
    ///   - emit: 事件发送回调。
    /// - Returns: 处理结果。
    private static func processFile(
        entry: FileEntry,
        configuration: Configuration,
        task: TransferTask,
        tracker: @escaping @Sendable (Int64) async -> Void,
        emit: @escaping @Sendable (TransferEvent) async -> Void
    ) async -> FileOutcome {
        let taskID = task.id
        let started = Date()
        let retryPolicy = RetryPolicy(maxRetries: configuration.options.maxRetries)

        await emit(.fileStatusChanged(taskID: taskID, fileID: entry.id, status: .queued))

        var attempt = 1
        while true {
            if Task.isCancelled {
                return FileOutcome(
                    fileID: entry.id,
                    status: .cancelled,
                    duration: Date().timeIntervalSince(started)
                )
            }

            await emit(.fileStatusChanged(taskID: taskID, fileID: entry.id, status: .transferring))

            do {
                let outcome = try await copyOnce(
                    entry: entry,
                    configuration: configuration,
                    task: task,
                    tracker: tracker,
                    onVerifying: {
                        // 架构 §3.1：完整的 `transferring → verifying → succeeded/failed`。
                        await emit(
                            .fileStatusChanged(
                                taskID: taskID,
                                fileID: entry.id,
                                status: .verifying
                            )
                        )
                    }
                )
                await emit(.fileCompleted(taskID: taskID, fileID: entry.id, result: outcome))
                return outcome
            } catch let error as MacCopyError {
                if error == .cancelled {
                    return FileOutcome(
                        fileID: entry.id,
                        status: .cancelled,
                        duration: Date().timeIntervalSince(started)
                    )
                }

                await emit(
                    .fileFailed(taskID: taskID, fileID: entry.id, error: error, attempt: attempt)
                )

                if retryPolicy.shouldRetry(error: error, attempt: attempt) {
                    let delay = retryPolicy.backoff(forAttempt: attempt)
                    Log.engine.info(
                        "第 \(attempt, privacy: .public) 次尝试失败，\(delay, privacy: .public) 秒后重试"
                    )
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    attempt += 1
                    continue
                }

                return FileOutcome(
                    fileID: entry.id,
                    status: .failed,
                    duration: Date().timeIntervalSince(started),
                    error: error
                )
            } catch {
                return FileOutcome(
                    fileID: entry.id,
                    status: .failed,
                    duration: Date().timeIntervalSince(started),
                    error: .unknown(underlying: error.localizedDescription)
                )
            }
        }
    }

    /// 执行一次复制（不含重试逻辑）。
    ///
    /// - Parameters:
    ///   - entry: 文件条目。
    ///   - configuration: 引擎配置。
    ///   - task: 任务定义。
    ///   - tracker: 进度累加回调。
    /// - Returns: 处理结果。
    private static func copyOnce(
        entry: FileEntry,
        configuration: Configuration,
        task: TransferTask,
        tracker: @escaping @Sendable (Int64) async -> Void,
        onVerifying: @escaping @Sendable () async -> Void
    ) async throws -> FileOutcome {
        let started = Date()
        let options = configuration.options

        // 符号链接：**重建链接本身**（PRD P0-06「保留符号链接」）。
        //
        // 实测：`symlink()` 在本机可用（守卫策略在会话期间放宽过，
        // 早期探针误判为不可用）。因此这里真正创建链接，
        // 而不是只记录就跳过。
        if entry.isSymbolicLink {
            return try createSymbolicLink(
                entry: entry,
                destinationPath: PathUtil.join(task.destinationRoot, entry.relativePath),
                startedAt: started
            )
        }

        // 目标路径。
        let destinationPath = PathUtil.join(task.destinationRoot, entry.relativePath)

        // 冲突解析。
        let destinationExists = FileManager.default.fileExists(atPath: destinationPath)
        var finalDestinationPath = destinationPath
        if destinationExists {
            let sourceMeta = MetadataOps.metadata(at: entry.sourcePath)
            let destinationMeta = MetadataOps.metadata(at: destinationPath)
            let decision = await configuration.conflictResolver.resolve(
                sourcePath: entry.sourcePath,
                destinationPath: destinationPath,
                sourceSize: entry.size,
                destinationSize: destinationMeta?.size ?? 0,
                sourceModifiedAt: sourceMeta?.modifiedAt ?? Date(),
                destinationModifiedAt: destinationMeta?.modifiedAt ?? Date()
            )
            switch decision {
            case .skip:
                return FileOutcome(
                    fileID: entry.id,
                    status: .skipped,
                    destinationPath: destinationPath,
                    duration: Date().timeIntervalSince(started)
                )
            case .overwrite:
                break
            case .rename(let newPath):
                finalDestinationPath = newPath
            case .proceed:
                break
            }
        }

        // 确保目标目录存在。
        let destinationDirectory = (finalDestinationPath as NSString).deletingLastPathComponent
        if !destinationDirectory.isEmpty {
            try PathWalker().createDirectory(at: destinationDirectory)
        }

        // 打开源。
        let sourceFD = open(entry.sourcePath, O_RDONLY)
        guard sourceFD >= 0 else {
            let code = Syscall.currentErrno()
            throw MacCopyError.sourceUnreadable(
                path: entry.sourcePath,
                underlying: "errno=\(code) \(Syscall.describe(code))"
            )
        }
        defer { close(sourceFD) }

        // 探测源是否可寻址。
        Syscall.resetErrno()
        let seekProbe = lseek(sourceFD, 0, SEEK_CUR)
        let sourceIsSeekable = seekProbe >= 0

        // 目标 fd：普通写入用 O_WRONLY|O_CREAT|O_TRUNC。
        let destinationFD = open(finalDestinationPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard destinationFD >= 0 else {
            throw MacCopyError.destinationUnwritable(path: finalDestinationPath)
        }
        defer { close(destinationFD) }

        // 决策：克隆路径 vs 流式 tee 路径。
        //
        // P1-06（QA 第 2 轮缺陷 A）：限速只在 `StreamCopier` 的写入侧由
        // `TokenBucket` 实现；`CloneCopier` 的数据不流经用户态，无法节流。
        // 而 `TransferOptions.default` 恰好是 `enableClone=true` + `crc32`，
        // 会命中克隆分支 —— 用户设了限速却全速复制且无报错（静默失效）。
        // 因此**只要启用限速就强制走流式路径**（QA 推荐的改动最小方案）。
        // 注意：这不是 AD-13 的路径分流裁决，两者互不冲突、v1.1 冻结区未动。
        let rateLimited = (options.bandwidthLimitBytesPerSecond ?? 0) > 0
        let canClone = !rateLimited && CloneCopier.canUseClone(
            sourcePath: entry.sourcePath,
            destinationDirectory: destinationDirectory,
            enableClone: options.enableClone,
            sourceIsSeekable: sourceIsSeekable
        )

        var verificationResults = [VerificationResult]()
        var wasCloned = false
        var transferredBytes: Int64 = 0
        var degraded = false
        var degradedReason: String?

        // 架构 §3.1：进入校验阶段前发状态迁移事件，让 UI 能显示「校验中」。
        if !options.checksumAlgorithms.isEmpty {
            await onVerifying()
        }

        if canClone && !options.checksumAlgorithms.isEmpty {
            // 克隆路径：数据不流经用户态 → 复制后回读校验。
            do {
                let result = try CloneCopier().copy(
                    sourceFD: sourceFD,
                    destinationFD: destinationFD,
                    attemptClone: true,
                    logicalSize: entry.size
                )
                wasCloned = result.wasCloned
                transferredBytes = result.bytesTransferred
                await tracker(transferredBytes)

                let conclusion = configuration.verifier.verifyByReadBack(
                    fileID: entry.id,
                    sourcePath: entry.sourcePath,
                    destinationPath: finalDestinationPath,
                    algorithms: options.checksumAlgorithms
                )
                verificationResults = conclusion.results
                degraded = conclusion.isDegraded
                degradedReason = conclusion.reason

                if conclusion.status == .failed {
                    throw MacCopyError.checksumMismatch(
                        file: entry.sourcePath,
                        algorithm: options.checksumAlgorithms.sorted { $0.rawValue < $1.rawValue }.first ?? .crc32,
                        expected: conclusion.results.first?.expected ?? "",
                        actual: conclusion.results.first?.actual ?? ""
                    )
                }
            } catch let error as MacCopyError {
                if case .checksumMismatch = error {
                    // 校验失败：让外层重试（Q7）。
                    throw error
                }
                // 克隆失败 → 回退到流式路径（**不计为失败**，架构 §5）。
                Log.engine.info("克隆失败，回退到流式复制：\(error.localizedDescription)")
                await tracker(-transferredBytes)
                transferredBytes = 0
                wasCloned = false
                try await copyViaStream(
                    entry: entry,
                    configuration: configuration,
                    sourceFD: sourceFD,
                    destinationFD: destinationFD,
                    destinationPath: finalDestinationPath,
                    sourceIsSeekable: sourceIsSeekable,
                    tracker: tracker,
                    verificationResults: &verificationResults,
                    degraded: &degraded,
                    degradedReason: &degradedReason
                )
                transferredBytes = entry.size
            }
        } else {
            try await copyViaStream(
                entry: entry,
                configuration: configuration,
                sourceFD: sourceFD,
                destinationFD: destinationFD,
                destinationPath: finalDestinationPath,
                sourceIsSeekable: sourceIsSeekable,
                tracker: tracker,
                verificationResults: &verificationResults,
                degraded: &degraded,
                degradedReason: &degradedReason
            )
            transferredBytes = entry.size
        }

        // 时间戳与权限。
        if options.preserveTimestamps {
            try? MetadataOps.applyTimestamps(
                from: MetadataOps.Metadata(
                    size: entry.size,
                    blocks: entry.allocatedSize / 512,
                    modifiedAt: entry.signature?.modifiedAt ?? Date(),
                    accessedAt: entry.signature?.modifiedAt ?? Date(),
                    changedAt: entry.signature?.modifiedAt ?? Date(),
                    birthAt: nil,
                    mode: entry.mode,
                    isDirectory: false,
                    isSymbolicLink: false,
                    inode: entry.signature?.inode ?? 0,
                    deviceID: entry.signature?.deviceID ?? 0
                ),
                to: finalDestinationPath,
                mode: .atimeMtimeBirthtime
            )
            MetadataOps.applyPermissions(mode: entry.mode, to: finalDestinationPath)
        }

        // 校验状态。
        var finalStatus: FileStatus = .succeeded
        if degraded {
            finalStatus = .succeeded
            verificationResults.append(
                VerificationResult(
                    fileID: entry.id,
                    algorithm: options.checksumAlgorithms.sorted { $0.rawValue < $1.rawValue }.first ?? .crc32,
                    status: .notVerified,
                    duration: 0
                )
            )
        }

        return FileOutcome(
            fileID: entry.id,
            status: finalStatus,
            destinationPath: finalDestinationPath,
            bytesTransferred: transferredBytes,
            wasCloned: wasCloned,
            duration: Date().timeIntervalSince(started),
            verificationResults: verificationResults
        )
    }

    /// 创建符号链接（PRD P0-06）。
    ///
    /// 实测：`symlink()` 与 `unlink()` 均可用，因此真正重建链接，
    /// 而不是只记录就跳过。
    ///
    /// - Parameters:
    ///   - entry: 文件条目（含 `linkDestination`）。
    ///   - destinationPath: 目标链接路径。
    ///   - startedAt: 开始时间。
    /// - Returns: 处理结果。
    private static func createSymbolicLink(
        entry: FileEntry,
        destinationPath: String,
        startedAt: Date
    ) throws -> FileOutcome {
        guard let linkTarget = entry.linkDestination else {
            // 读不出目标 → 标记失败（不能静默跳过，PRD 要求保留符号链接）。
            return FileOutcome(
                fileID: entry.id,
                status: .failed,
                duration: Date().timeIntervalSince(startedAt),
                error: .sourceUnreadable(
                    path: entry.sourcePath,
                    underlying: "无法读取符号链接目标"
                )
            )
        }

        // 确保目标目录存在。
        let destinationDirectory = (destinationPath as NSString).deletingLastPathComponent
        if !destinationDirectory.isEmpty {
            try PathWalker().createDirectory(at: destinationDirectory)
        }

        // 覆盖场景：目标已存在则先删。
        if FileManager.default.fileExists(atPath: destinationPath) {
            Syscall.resetErrno()
            let unlinkResult = unlink(destinationPath)
            if unlinkResult != 0 {
                let code = Syscall.currentErrno()
                Log.engine.error(
                    "删除已存在的目标链接失败 errno=\(code) path=\(destinationPath, privacy: .private)"
                )
            }
        }

        Syscall.resetErrno()
        let result = symlink(linkTarget, destinationPath)
        if result != 0 {
            let code = Syscall.currentErrno()
            return FileOutcome(
                fileID: entry.id,
                status: .failed,
                destinationPath: destinationPath,
                duration: Date().timeIntervalSince(startedAt),
                error: .unknown(
                    underlying: "创建符号链接失败「\(destinationPath)」：errno=\(code) "
                        + "\(Syscall.describe(code))"
                )
            )
        }

        return FileOutcome(
            fileID: entry.id,
            status: .succeeded,
            destinationPath: destinationPath,
            duration: Date().timeIntervalSince(startedAt)
        )
    }

    /// 流式 tee 复制路径。
    ///
    /// - Parameters:
    ///   - entry: 文件条目。
    ///   - configuration: 引擎配置。
    ///   - sourceFD: 源 fd。
    ///   - destinationFD: 目标 fd。
    ///   - destinationPath: 目标路径。
    ///   - sourceIsSeekable: 源是否可寻址。
    ///   - tracker: 进度累加回调。
    ///   - verificationResults: 校验结果（输出）。
    ///   - degraded: 是否降级（输出）。
    ///   - degradedReason: 降级原因（输出）。
    private static func copyViaStream(
        entry: FileEntry,
        configuration: Configuration,
        sourceFD: Int32,
        destinationFD: Int32,
        destinationPath: String,
        sourceIsSeekable: Bool,
        tracker: @escaping @Sendable (Int64) async -> Void,
        verificationResults: inout [VerificationResult],
        degraded: inout Bool,
        degradedReason: inout String?
    ) async throws {
        let options = configuration.options

        var hasher = MultiHasher(algorithms: Array(options.checksumAlgorithms))
        _ = try await StreamCopier().copy(
            sourceFD: sourceFD,
            destinationFD: destinationFD,
            startOffset: 0,
            bufferSize: options.bufferSize,
            hasher: &hasher,
            bandwidthLimitBytesPerSecond: options.bandwidthLimitBytesPerSecond.map { Double($0) },
            onProgress: { delta in
                await tracker(delta)
            }
        )

        let sourceDigests = hasher.finalizeHex()

        // tee 路径已有源侧摘要；目标侧需要回读比对（或信任 tee —— tee 算的就是写入的数据）。
        // 严格做法：回读目标算摘要再比。架构 §5 要求校验真实内容。
        let destinationDigests = Verifier.digest(
            of: destinationPath,
            algorithms: options.checksumAlgorithms,
            registry: ChecksumRegistry.shared,
            bufferSize: options.bufferSize
        )

        let conclusion = configuration.verifier.compare(
            fileID: entry.id,
            expected: sourceDigests,
            actual: destinationDigests
        )
        verificationResults = conclusion.results

        if conclusion.status == .failed {
            throw MacCopyError.checksumMismatch(
                file: entry.sourcePath,
                algorithm: options.checksumAlgorithms.sorted { $0.rawValue < $1.rawValue }.first ?? .crc32,
                expected: conclusion.results.first?.expected ?? "",
                actual: conclusion.results.first?.actual ?? ""
            )
        }

        // Q5 降级判定：源不可寻址且 tee 不可用 → 降级。
        if let reason = Verifier.degradationReason(
            sourceIsSeekable: sourceIsSeekable,
            teeEnabled: true,
            readBackSucceeded: !destinationDigests.isEmpty
        ) {
            degraded = true
            degradedReason = reason
        }
    }

    // MARK: - 辅助

    /// 创建目标目录。
    private func createDirectory(for entry: FileEntry, task: TransferTask) async {
        let destinationPath = PathUtil.join(task.destinationRoot, entry.relativePath)
        do {
            try PathWalker().createDirectory(at: destinationPath)
            await emit(
                .fileStatusChanged(taskID: task.id, fileID: entry.id, status: .succeeded)
            )
        } catch {
            Log.engine.error("创建目录失败 path=\(destinationPath, privacy: .private)")
            await emit(
                .fileFailed(
                    taskID: task.id,
                    fileID: entry.id,
                    error: .destinationUnwritable(path: destinationPath),
                    attempt: 1
                )
            )
        }
    }

    /// 状态迁移（严格按架构 §3.1 的迁移表）。
    private func transition(to next: TaskState, taskID: UUID) async {
        guard self.state.canTransition(to: next) else {
            Log.engine.error("非法状态迁移 \(self.state.rawValue, privacy: .public) → \(next.rawValue, privacy: .public)")
            return
        }
        self.state = next
        await emit(.taskStateChanged(taskID: taskID, state: next))
    }

    /// 累加已传输字节。
    private func addTransferred(bytes: Int64) async {
        guard bytes != 0 else { return }
        tracker.addTransferred(bytes: bytes)
        progress = tracker.snapshot()
        await emit(.progress(taskID: currentTaskID, progress: progress))
    }

    /// 发送事件。
    private func emit(_ event: TransferEvent) async {
        await eventSink(event)
    }

    /// 当前任务 ID（供进度事件使用）。
    private var currentTaskID: UUID = UUID()

    /// 统计任务规模。
    private static func computeStatistics(
        task: TransferTask,
        configuration: Configuration
    ) async -> PlanBuilder.Statistics {
        let builder = PlanBuilder()
        do {
            return try await builder.statistics(
                sourceRoots: task.sourceRoots,
                destinationRoot: task.destinationRoot
            )
        } catch {
            return PlanBuilder.Statistics(
                totalBytes: 0,
                totalFiles: 0,
                totalDirectories: 0,
                sparseFiles: 0,
                symbolicLinks: 0
            )
        }
    }

    /// 构造汇总。
    private func makeSummary(
        taskID: UUID,
        startedAt: Date,
        statistics: PlanBuilder.Statistics,
        counters: OutcomeCounter
    ) async -> TransferSummary {
        let snapshot = await counters.snapshot()
        return TransferSummary(
            taskID: taskID,
            succeededCount: snapshot.succeeded,
            failedCount: snapshot.failed,
            skippedCount: snapshot.skipped,
            totalBytes: statistics.totalBytes,
            transferredBytes: tracker.snapshot().transferredBytes,
            duration: Date().timeIntervalSince(startedAt),
            degradedCount: snapshot.degraded
        )
    }
}

/// 结果计数器（actor 隔离）。
actor OutcomeCounter {
    /// 成功数。
    private var succeeded = 0
    /// 失败数。
    private var failed = 0
    /// 跳过数。
    private var skipped = 0
    /// 降级数。
    private var degraded = 0
    /// 成功文件的摘要（按算法分组，用于生成校验清单）。
    private var digests: [ChecksumAlgorithmID: [(relativePath: String, digest: String)]] = [:]

    /// 累加一个结果。
    func add(_ outcome: FileOutcome) {
        switch outcome.status {
        case .succeeded:
            succeeded += 1
            if outcome.verificationResults.contains(where: { $0.status == .notVerified }) {
                degraded += 1
            }
            // 收集目标摘要：优先用 actual（目标真实摘要），回退到 expected（源摘要）。
            if let destination = outcome.destinationPath {
                for result in outcome.verificationResults where result.status == .passed {
                    guard let digest = result.actual ?? result.expected else { continue }
                    digests[result.algorithm, default: []].append(
                        (relativePath: destination, digest: digest)
                    )
                }
            }
        case .failed:
            failed += 1
        case .skipped:
            skipped += 1
        case .cancelled:
            break
        case .queued, .transferring, .verifying:
            break
        }
    }

    /// 取快照。
    func snapshot() -> (succeeded: Int, failed: Int, skipped: Int, degraded: Int) {
        (succeeded, failed, skipped, degraded)
    }

    /// 记录一次**枚举级失败**（源根不可访问等）。
    ///
    /// 此前枚举抛错时只转任务状态、不累加失败数，导致汇总显示
    /// 「成功 0 / 失败 0」——用户无法区分「本来就没文件」与「出错了」。
    func addEnumerationFailure(_ error: Error) {
        failed += 1
        Log.engine.error("枚举级失败：\(error.localizedDescription)")
    }

    /// 取校验清单条目（按算法分组，路径已转为相对目标根目录）。
    ///
    /// - Parameter destinationRoot: 目标根目录绝对路径。
    /// - Returns: 算法 → [(相对路径, 摘要)]。
    func checksumGroups(
        destinationRoot: String
    ) -> [ChecksumAlgorithmID: [(relativePath: String, digest: String)]] {
        let prefix = destinationRoot.hasSuffix("/") ? destinationRoot : destinationRoot + "/"
        var result: [ChecksumAlgorithmID: [(relativePath: String, digest: String)]] = [:]
        for (algorithm, entries) in digests {
            result[algorithm] = entries.map { entry in
                let relative = entry.relativePath.hasPrefix(prefix)
                    ? String(entry.relativePath.dropFirst(prefix.count))
                    : (entry.relativePath as NSString).lastPathComponent
                return (relativePath: relative, digest: entry.digest)
            }.sorted { $0.relativePath < $1.relativePath }
        }
        return result
    }
}

/// 原子游标（worker 共享取任务）。
final class AtomicCounter: @unchecked Sendable {
    /// 当前值。
    private var value: Int = 0
    /// 保护锁。
    private let lock = NSLock()

    /// 构造游标。
    init() {}

    /// 取下一个值并递增。
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let current = value
        value += 1
        return current
    }
}

/// 结果收集盒（worker 并发写入）。
final class ResultBox: @unchecked Sendable {
    /// 结果数组。
    private var items = [FileOutcome]()
    /// 保护锁。
    private let lock = NSLock()

    /// 构造结果盒。
    init() {}

    /// 追加结果。
    func append(_ outcome: FileOutcome) {
        lock.lock()
        defer { lock.unlock() }
        items.append(outcome)
    }

    /// 取全部结果。
    func snapshot() -> [FileOutcome] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}
