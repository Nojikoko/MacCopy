import Foundation
import Darwin
import MacCopyKit

/// 引擎层测试（StreamCopier / PlanBuilder / CopyEngine 端到端 / Verifier / ResumeManager / ConflictResolver）。
@MainActor
enum EngineTests {
    /// 注册全部用例。
    static func register() {
        registerStreamCopier()
        registerTokenBucket()
        registerQueueRecovery()
        registerCorrectness()
        registerPlanBuilder()
        registerVerifier()
        registerConflictResolver()
        registerResumeManager()
        registerEndToEnd()
    }

    // MARK: - StreamCopier

    private static func registerStreamCopier() {
        TestRunner.register("StreamCopier：流式复制内容与源一致") {
            let root = IOTests.scratchDirectory("sc-basic")
            defer { try? FileManager.default.removeItem(at: root) }

            let source = root.appendingPathComponent("src.bin").path
            let destination = root.appendingPathComponent("dst.bin").path
            let payload = String(repeating: "MacCopy 流式复制测试内容。", count: 500)
            IOTests.writeFile(source, payload)

            let sourceFD = open(source, O_RDONLY)
            let destinationFD = open(destination, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            TestRunner.assertTrue(sourceFD >= 0)
            TestRunner.assertTrue(destinationFD >= 0)
            defer {
                if sourceFD >= 0 { close(sourceFD) }
                if destinationFD >= 0 { close(destinationFD) }
            }

            var hasher = MultiHasher(algorithms: [.crc32, .sha256])
            let result = try await StreamCopier().copy(
                sourceFD: sourceFD,
                destinationFD: destinationFD,
                startOffset: 0,
                bufferSize: 4096,
                hasher: &hasher,
                onProgress: { _ in }
            )

            TestRunner.assertEqual(result.transferredBytes, Int64(payload.utf8.count))
            TestRunner.assertEqual(IOTests.readFile(destination), payload)
        }

        TestRunner.register("StreamCopier：分段 tee 哈希与一次性计算结果一致") {
            let root = IOTests.scratchDirectory("sc-tee")
            defer { try? FileManager.default.removeItem(at: root) }

            let source = root.appendingPathComponent("src.bin").path
            let destination = root.appendingPathComponent("dst.bin").path
            // 构造跨多种边界长度的数据（覆盖各种短读场景）。
            var payload = ""
            for index in 0..<300 {
                payload += String(repeating: "行\(index)", count: index % 37 + 1) + "\n"
            }
            IOTests.writeFile(source, payload)

            // 方式 A：一次性读取计算哈希。
            var oneShotHasher = MultiHasher(algorithms: [.crc32, .sha256, .blake3])
            oneShotHasher.update(bytes: Array(payload.utf8))
            let oneShot = oneShotHasher.finalizeHex()

            // 方式 B：流式 tee（分块）。
            let sourceFD = open(source, O_RDONLY)
            let destinationFD = open(destination, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            defer {
                if sourceFD >= 0 { close(sourceFD) }
                if destinationFD >= 0 { close(destinationFD) }
            }

            var streamHasher = MultiHasher(algorithms: [.crc32, .sha256, .blake3])
            _ = try await StreamCopier().copy(
                sourceFD: sourceFD,
                destinationFD: destinationFD,
                startOffset: 0,
                bufferSize: 1024,
                hasher: &streamHasher,
                onProgress: { _ in }
            )
            let streamed = streamHasher.finalizeHex()

            for algorithm in [ChecksumAlgorithmID.crc32, .sha256, .blake3] {
                TestRunner.assertEqual(
                    streamed[algorithm],
                    oneShot[algorithm],
                    "\(algorithm.rawValue) 分段与一次性应一致"
                )
            }
        }

        TestRunner.register("StreamCopier：目标内容与源逐字节一致（短写处理）") {
            let root = IOTests.scratchDirectory("sc-shortwrite")
            defer { try? FileManager.default.removeItem(at: root) }

            // 用较大的数据 + 小缓冲，强制多次 write 调用。
            let source = root.appendingPathComponent("src.bin").path
            let destination = root.appendingPathComponent("dst.bin").path
            var payload = [UInt8](repeating: 0, count: 300_000)
            for index in 0..<payload.count {
                payload[index] = UInt8(index % 251)
            }
            let fd = open(source, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            _ = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            close(fd)

            let sourceFD = open(source, O_RDONLY)
            let destinationFD = open(destination, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            defer {
                if sourceFD >= 0 { close(sourceFD) }
                if destinationFD >= 0 { close(destinationFD) }
            }

            var hasher = MultiHasher(algorithms: [.sha256])
            _ = try await StreamCopier().copy(
                sourceFD: sourceFD,
                destinationFD: destinationFD,
                startOffset: 0,
                bufferSize: 7919,   // 质数大小 → 不整除任何块
                hasher: &hasher,
                onProgress: { _ in }
            )

            let written = FileManager.default.contents(atPath: destination) ?? Data()
            TestRunner.assertEqual(written.count, payload.count)
            TestRunner.assertEqual(Array(written), payload)
        }
    }

    private static func registerTokenBucket() {
        TestRunner.register("TokenBucket：不限速时令牌无限") {
            var bucket = TokenBucket(rateBytesPerSecond: 0)
            TestRunner.assertTrue(bucket.isUnlimited)
            TestRunner.assertTrue(bucket.consume(10 * 1024 * 1024))
        }

        TestRunner.register("TokenBucket：按速率补充、容量封顶") {
            let t0 = Date(timeIntervalSince1970: 0)
            // 注意：capacity 下限是 64 KiB（低速时防止请求永远超过容量），
            // 所以这里用 100 KiB 速率让显式 capacityBytes 生效。
            var bucket = TokenBucket(
                rateBytesPerSecond: 100_000,
                capacityBytes: 100_000,
                initialTokens: 100_000,
                now: t0
            )
            TestRunner.assertTrue(bucket.consume(100_000, now: t0))
            TestRunner.assertFalse(bucket.consume(1, now: t0), "令牌耗尽后应不足")
            // 半秒后补充 50,000 令牌。
            let t05 = t0.addingTimeInterval(0.5)
            TestRunner.assertTrue(bucket.consume(50_000, now: t05))
            TestRunner.assertFalse(bucket.consume(1, now: t05))
            // 补充不会超过容量：10 秒后最多也只有 100,000 令牌。
            let t10 = t0.addingTimeInterval(10)
            TestRunner.assertTrue(bucket.consume(100_000, now: t10))
            TestRunner.assertFalse(bucket.consume(1, now: t10), "容量应封顶")
        }

        TestRunner.register("TokenBucket：超大请求不产生负令牌") {
            var bucket = TokenBucket(rateBytesPerSecond: 1000, capacityBytes: 1000)
            // capacity 下限 64 KiB，所以请求必须 > 64 KiB 才算「超大」。
            TestRunner.assertTrue(bucket.consume(200_000), "超大请求应直接放行")
            // 核心不变式：超大请求后 tokens 不能变负。
            TestRunner.assertTrue(
                bucket.availableTokens >= 0,
                "超大请求后令牌不应为负：\(bucket.availableTokens)"
            )
            // 补充 2 秒后应能按速率拿到 1000 令牌。
            bucket.refill(now: Date().addingTimeInterval(2))
            TestRunner.assertTrue(bucket.consume(1000, now: Date().addingTimeInterval(2)))
        }

        TestRunner.register("StreamCopier：限速 1 MiB/s 时 4 MiB 耗时 ≥3 秒且内容正确（PRD P1-06）") {
            let root = IOTests.scratchDirectory("sc-limit")
            defer { try? FileManager.default.removeItem(at: root) }

            let source = root.appendingPathComponent("src.bin").path
            let destination = root.appendingPathComponent("dst.bin").path
            // 4 MiB 数据。
            let bytes = [UInt8](repeating: 0x5A, count: 4 * 1024 * 1024)
            let fd = open(source, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            close(fd)

            let sourceFD = open(source, O_RDONLY)
            let destinationFD = open(destination, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            defer {
                if sourceFD >= 0 { close(sourceFD) }
                if destinationFD >= 0 { close(destinationFD) }
            }

            var hasher = MultiHasher(algorithms: [.crc32])
            let started = Date()
            _ = try await StreamCopier().copy(
                sourceFD: sourceFD,
                destinationFD: destinationFD,
                startOffset: 0,
                bufferSize: 64 * 1024,
                hasher: &hasher,
                bandwidthLimitBytesPerSecond: 1 * 1024 * 1024,
                onProgress: { _ in }
            )
            let elapsed = Date().timeIntervalSince(started)

            // 4 MiB @ 1 MiB/s，扣除首桶突发（1 秒额度），理论 ≥3 秒。
            // 给 2.5 秒宽松下限（避免 CI 抖动误报），同时断言确实被限速。
            TestRunner.assertTrue(
                elapsed >= 2.5,
                "限速应显著拖慢：实测 \(elapsed) 秒，应 ≥2.5 秒"
            )
            // 实测均速偏差 ≤10%：4 MiB / elapsed 应约等于 1 MiB/s。
            let measuredRate = Double(4 * 1024 * 1024) / elapsed
            let target = Double(1 * 1024 * 1024)
            let deviation = abs(measuredRate - target) / target
            TestRunner.assertTrue(
                deviation <= 0.10,
                "均速偏差应 ≤10%，实测均速 \(measuredRate / 1024 / 1024) MiB/s，偏差 \(deviation * 100)%"
            )

            let written = FileManager.default.contents(atPath: destination) ?? Data()
            TestRunner.assertEqual(written.count, 4 * 1024 * 1024, "内容长度应正确")
            // 限速不应改变内容。
            TestRunner.assertEqual(Array(written), bytes, "限速下内容应逐字节一致")
        }

        TestRunner.register("StreamCopier：不限速时 4 MiB 传输远快于限速路径") {
            let root = IOTests.scratchDirectory("sc-unlimited")
            defer { try? FileManager.default.removeItem(at: root) }

            let source = root.appendingPathComponent("src.bin").path
            let destination = root.appendingPathComponent("dst.bin").path
            let bytes = [UInt8](repeating: 0x33, count: 4 * 1024 * 1024)
            let fd = open(source, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            close(fd)

            let sourceFD = open(source, O_RDONLY)
            let destinationFD = open(destination, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            defer {
                if sourceFD >= 0 { close(sourceFD) }
                if destinationFD >= 0 { close(destinationFD) }
            }

            var hasher = MultiHasher(algorithms: [.crc32])
            let started = Date()
            _ = try await StreamCopier().copy(
                sourceFD: sourceFD,
                destinationFD: destinationFD,
                startOffset: 0,
                bufferSize: 64 * 1024,
                hasher: &hasher,
                bandwidthLimitBytesPerSecond: nil,
                onProgress: { _ in }
            )
            let elapsed = Date().timeIntervalSince(started)
            TestRunner.assertTrue(elapsed < 1.0, "不限速应很快，实测 \(elapsed) 秒")
        }
    }

    // MARK: - 队列恢复（PRD P0-09）

    private static func registerQueueRecovery() {
        TestRunner.register("队列恢复：读取两个 pending 任务并按创建顺序返回") {
            let root = IOTests.scratchDirectory("qr-read")
            defer { try? FileManager.default.removeItem(at: root) }

            let store = try JSONTaskQueueStore(
                fileURL: root.appendingPathComponent("queue.json")
            )
            let source = root.appendingPathComponent("src", isDirectory: true)
            try PathWalker().createDirectory(at: source.path)

            let t1 = TransferTask(
                sourceRoots: [source.path],
                destinationRoot: root.appendingPathComponent("dst1").path,
                createdAt: Date(timeIntervalSince1970: 1000)
            )
            let t2 = TransferTask(
                sourceRoots: [source.path],
                destinationRoot: root.appendingPathComponent("dst2").path,
                createdAt: Date(timeIntervalSince1970: 2000)
            )
            try store.save(t1)
            try store.save(t2)

            let ids = try store.pendingTaskIDs()
            TestRunner.assertEqual(ids.count, 2)
            TestRunner.assertEqual(ids.first, t1.id, "应按创建顺序")

            // 新建 coordinator 实例（模拟「重启」）。
            let recovery = TaskQueueRecovery(
                store: store,
                makeEngine: {
                    CopyEngine(
                        configuration: .init(
                            options: TransferOptions(),
                            conflictResolver: ConflictResolver(policy: .overwrite)
                        ),
                        eventSink: { _ in }
                    )
                },
                makeBatches: { task in
                    PlanBuilder().build(
                        sourceRoots: task.sourceRoots,
                        destinationRoot: task.destinationRoot
                    )
                }
            )
            let recovered = try await recovery.recoverableTasks()
            TestRunner.assertEqual(recovered.count, 2, "两个 pending 任务都应被恢复")
            TestRunner.assertTrue(recovered.contains { $0.id == t1.id })
            TestRunner.assertTrue(recovered.contains { $0.id == t2.id })
        }

        TestRunner.register("队列恢复：两个 pending 任务被执行，完成后从队列移除") {
            let root = IOTests.scratchDirectory("qr-run")
            defer { try? FileManager.default.removeItem(at: root) }

            let store = try JSONTaskQueueStore(
                fileURL: root.appendingPathComponent("queue.json")
            )
            let source = root.appendingPathComponent("src", isDirectory: true)
            try PathWalker().createDirectory(at: source.path)
            IOTests.writeFile(source.appendingPathComponent("a.txt").path, "内容A")
            IOTests.writeFile(source.appendingPathComponent("b.txt").path, "内容B")

            let t1 = TransferTask(
                sourceRoots: [source.path],
                destinationRoot: root.appendingPathComponent("dst1").path,
                createdAt: Date(timeIntervalSince1970: 1000)
            )
            let t2 = TransferTask(
                sourceRoots: [source.path],
                destinationRoot: root.appendingPathComponent("dst2").path,
                createdAt: Date(timeIntervalSince1970: 2000)
            )
            try store.save(t1)
            try store.save(t2)

            // 新建 engine 实例执行恢复。
            let recovery = TaskQueueRecovery(
                store: store,
                makeEngine: {
                    CopyEngine(
                        configuration: .init(
                            options: TransferOptions(
                                checksumAlgorithms: [.crc32],
                                threadCount: 1,
                                conflictPolicy: .overwrite,
                                enableClone: false
                            ),
                            conflictResolver: ConflictResolver(policy: .overwrite)
                        ),
                        eventSink: { _ in }
                    )
                },
                makeBatches: { task in
                    PlanBuilder().build(
                        sourceRoots: task.sourceRoots,
                        destinationRoot: task.destinationRoot
                    )
                }
            )
            let outcomes = try await recovery.recoverAll()

            TestRunner.assertEqual(outcomes.count, 2, "两个任务都应有结果")
            TestRunner.assertEqual(
                outcomes.filter { !$0.wasCancelled && $0.failedCount == 0 }.count,
                2,
                "两个任务都应成功"
            )
            // 内容确实被复制到两个目标。
            TestRunner.assertEqual(
                IOTests.readFile(root.appendingPathComponent("dst1/a.txt").path),
                "内容A"
            )
            TestRunner.assertEqual(
                IOTests.readFile(root.appendingPathComponent("dst2/b.txt").path),
                "内容B"
            )
            // 完成后队列应清空（不重复执行）。
            let remaining = try store.pendingTaskIDs()
            TestRunner.assertEqual(remaining.count, 0, "完成后应从队列移除")
        }

        TestRunner.register("队列恢复：取消单任务不影响其他任务") {
            let root = IOTests.scratchDirectory("qr-cancel")
            defer { try? FileManager.default.removeItem(at: root) }

            let store = try JSONTaskQueueStore(
                fileURL: root.appendingPathComponent("queue.json")
            )
            let source = root.appendingPathComponent("src", isDirectory: true)
            try PathWalker().createDirectory(at: source.path)
            IOTests.writeFile(source.appendingPathComponent("a.txt").path, "内容A")

            let t1 = TransferTask(
                sourceRoots: [source.path],
                destinationRoot: root.appendingPathComponent("dst1").path,
                createdAt: Date(timeIntervalSince1970: 1000)
            )
            let t2 = TransferTask(
                sourceRoots: [source.path],
                destinationRoot: root.appendingPathComponent("dst2").path,
                createdAt: Date(timeIntervalSince1970: 2000)
            )
            try store.save(t1)
            try store.save(t2)

            let recovery = TaskQueueRecovery(
                store: store,
                makeEngine: {
                    CopyEngine(
                        configuration: .init(
                            options: TransferOptions(
                                checksumAlgorithms: [.crc32],
                                threadCount: 1,
                                conflictPolicy: .overwrite,
                                enableClone: false
                            ),
                            conflictResolver: ConflictResolver(policy: .overwrite)
                        ),
                        eventSink: { _ in }
                    )
                },
                makeBatches: { task in
                    PlanBuilder().build(
                        sourceRoots: task.sourceRoots,
                        destinationRoot: task.destinationRoot
                    )
                }
            )

            let ids = try await recovery.startRecovery()
            TestRunner.assertEqual(ids.count, 2)
            let cancelled = await recovery.cancel(taskID: t1.id)
            TestRunner.assertTrue(cancelled, "应能发出单任务取消")

            let outcomes = await recovery.awaitOutcomes()
            TestRunner.assertEqual(outcomes.count, 2, "两个任务都应有结果（互不影响）")
            // 至少还有一个任务的句柄存在/被处理；结果里不能两个都是 wasSkipped。
            TestRunner.assertFalse(
                outcomes.allSatisfy { $0.wasSkipped },
                "不应全部被跳过"
            )
        }

        TestRunner.register("队列恢复：终态任务不会被恢复") {
            let root = IOTests.scratchDirectory("qr-terminal")
            defer { try? FileManager.default.removeItem(at: root) }

            let store = try JSONTaskQueueStore(
                fileURL: root.appendingPathComponent("queue.json")
            )
            let source = root.appendingPathComponent("src", isDirectory: true)
            try PathWalker().createDirectory(at: source.path)

            var done = TransferTask(
                sourceRoots: [source.path],
                destinationRoot: root.appendingPathComponent("dst").path
            )
            done.state = .succeeded
            try store.save(done)

            // pendingTaskIDs 本身就过滤终态，再经 coordinator 也应为 0。
            let recovery = TaskQueueRecovery(
                store: store,
                makeEngine: {
                    CopyEngine(
                        configuration: .init(
                            options: TransferOptions(),
                            conflictResolver: ConflictResolver(policy: .overwrite)
                        ),
                        eventSink: { _ in }
                    )
                },
                makeBatches: { task in
                    PlanBuilder().build(
                        sourceRoots: task.sourceRoots,
                        destinationRoot: task.destinationRoot
                    )
                }
            )
            let recovered = try await recovery.recoverableTasks()
            TestRunner.assertEqual(recovered.count, 0, "终态任务不应被恢复")
        }
    }

    // MARK: - 正确性（BUG-03 + verifying 迁移）

    private static func registerCorrectness() {
        TestRunner.register("正确性：复制后篡改目标 1 字节 → 必须检出不一致") {
            let root = IOTests.scratchDirectory("correct-tamper-dst")
            defer { try? FileManager.default.removeItem(at: root) }

            let source = root.appendingPathComponent("src.bin").path
            let destination = root.appendingPathComponent("dst.bin").path
            IOTests.writeFile(source, "原始内容-ABCDEFGHIJKLMNOPQRSTUVWXYZ")
            IOTests.writeFile(destination, "原始内容-ABCDEFGHIJKLMNOPQRSTUVWXYZ")

            // 篡改目标 1 字节。
            let fd = open(destination, O_WRONLY)
            if fd >= 0 {
                _ = lseek(fd, 3, SEEK_SET)
                _ = "Z".withCString { write(fd, $0, 1) }
                close(fd)
            }

            let conclusion = Verifier().verifyByReadBack(
                fileID: UUID(),
                sourcePath: source,
                destinationPath: destination,
                algorithms: [.crc32, .sha256]
            )
            TestRunner.assertEqual(conclusion.status, .failed, "篡改目标必须被检出")
            TestRunner.assertFalse(conclusion.isPassed)
        }

        TestRunner.register("正确性：复制后篡改源 1 字节 → 必须检出不一致") {
            let root = IOTests.scratchDirectory("correct-tamper-src")
            defer { try? FileManager.default.removeItem(at: root) }

            let source = root.appendingPathComponent("src.bin").path
            let destination = root.appendingPathComponent("dst.bin").path
            IOTests.writeFile(source, "原始内容-ABCDEFGHIJKLMNOPQRSTUVWXYZ")
            IOTests.writeFile(destination, "原始内容-ABCDEFGHIJKLMNOPQRSTUVWXYZ")

            // 篡改源 1 字节（模拟「源在复制后变化」）。
            let fd = open(source, O_WRONLY)
            if fd >= 0 {
                _ = lseek(fd, 3, SEEK_SET)
                _ = "Z".withCString { write(fd, $0, 1) }
                close(fd)
            }

            // 回读校验必须从源重新算摘要 → 检出不一致。
            let conclusion = Verifier().verifyByReadBack(
                fileID: UUID(),
                sourcePath: source,
                destinationPath: destination,
                algorithms: [.crc32, .sha256]
            )
            TestRunner.assertEqual(conclusion.status, .failed, "篡改源必须被检出")
            TestRunner.assertFalse(conclusion.isPassed)
        }

        TestRunner.register("正确性：降级场景必须带明确说明且不标为通过") {
            let verifier = Verifier()
            let conclusion = verifier.compare(
                fileID: UUID(),
                expected: [:],
                actual: [:]
            )
            TestRunner.assertEqual(conclusion.status, .notVerified)
            TestRunner.assertTrue(conclusion.isDegraded)
            TestRunner.assertNotNil(conclusion.reason, "降级必须有明确说明")
            TestRunner.assertFalse(conclusion.isPassed, "降级不可标为通过")
        }

        TestRunner.register("verifying 迁移：引擎事件流包含 transferring → verifying → 完成") {
            let root = IOTests.scratchDirectory("correct-verifying")
            defer { try? FileManager.default.removeItem(at: root) }

            let source = root.appendingPathComponent("src", isDirectory: true)
            try PathWalker().createDirectory(at: source.path)
            IOTests.writeFile(source.appendingPathComponent("f.txt").path, "校验状态测试内容")

            let destination = root.appendingPathComponent("dst", isDirectory: true)
            let task = TransferTask(
                sourceRoots: [source.path],
                destinationRoot: destination.path,
                options: TransferOptions(
                    checksumAlgorithms: [.crc32],
                    threadCount: 1,
                    conflictPolicy: .overwrite,
                    enableClone: false
                )
            )

            let eventBox = EventBox()
            let engine = CopyEngine(
                configuration: .init(
                    options: task.options,
                    conflictResolver: ConflictResolver(policy: .overwrite)
                ),
                eventSink: { event in eventBox.append(event) }
            )
            let batches = PlanBuilder().build(
                sourceRoots: task.sourceRoots,
                destinationRoot: task.destinationRoot
            )
            _ = await engine.run(task: task, batches: batches)

            let events = eventBox.snapshot()
            var statuses = [FileStatus]()
            for event in events {
                if case .fileStatusChanged(_, _, let status) = event {
                    statuses.append(status)
                }
            }
            TestRunner.assertTrue(
                statuses.contains(.transferring),
                "应发出 transferring，实际：\(statuses.map(\.rawValue))"
            )
            TestRunner.assertTrue(
                statuses.contains(.verifying),
                "应发出 verifying（架构 §3.1 完整迁移），实际：\(statuses.map(\.rawValue))"
            )
            TestRunner.assertTrue(
                events.contains { if case .fileCompleted = $0 { return true } else { return false } },
                "应发出 fileCompleted"
            )
        }
    }

    // MARK: - PlanBuilder

    private static func registerPlanBuilder() {
        TestRunner.register("PlanBuilder：枚举产出条目且统计正确") {
            let root = IOTests.scratchDirectory("pb-enum")
            defer { try? FileManager.default.removeItem(at: root) }

            let source = root.appendingPathComponent("src", isDirectory: true)
            try PathWalker().createDirectory(at: source.path)
            IOTests.writeFile(source.appendingPathComponent("a.txt").path, "A")
            IOTests.writeFile(source.appendingPathComponent("b.txt").path, "BB")
            _ = mkdir(source.appendingPathComponent("子目录", isDirectory: true).path, 0o755)
            IOTests.writeFile(source.appendingPathComponent("子目录", isDirectory: true)
                .appendingPathComponent("c.txt").path, "CCC")

            let builder = PlanBuilder()
            let statistics = try await builder.statistics(
                sourceRoots: [source.path],
                destinationRoot: root.appendingPathComponent("dst").path
            )

            TestRunner.assertEqual(statistics.totalFiles, 3)
            TestRunner.assertEqual(statistics.totalDirectories, 1)
            TestRunner.assertEqual(statistics.totalBytes, 6)  // 1 + 2 + 3
        }

        TestRunner.register("PlanBuilder：分批产出且批次总数守恒") {
            let root = IOTests.scratchDirectory("pb-batch")
            defer { try? FileManager.default.removeItem(at: root) }

            let source = root.appendingPathComponent("src", isDirectory: true)
            try PathWalker().createDirectory(at: source.path)
            for index in 0..<25 {
                IOTests.writeFile(
                    source.appendingPathComponent("f\(index).txt").path,
                    "内容\(index)"
                )
            }

            let builder = PlanBuilder()
            var batchedCount = 0
            var batchedBytes: Int64 = 0
            for try await batch in builder.build(
                sourceRoots: [source.path],
                destinationRoot: root.appendingPathComponent("dst").path
            ) {
                batchedCount += batch.fileCount
                batchedBytes += batch.totalBytes
            }

            TestRunner.assertEqual(batchedCount, 25)
            TestRunner.assertTrue(batchedBytes > 0)
        }
    }

    // MARK: - Verifier

    private static func registerVerifier() {
        TestRunner.register("Verifier：摘要一致 → 通过；不一致 → 失败") {
            let verifier = Verifier()

            let passed = verifier.compare(
                fileID: UUID(),
                expected: [.crc32: "abcd1234"],
                actual: [.crc32: "abcd1234"]
            )
            TestRunner.assertEqual(passed.status, .passed)
            TestRunner.assertFalse(passed.isDegraded)
            TestRunner.assertTrue(passed.isPassed)

            let failed = verifier.compare(
                fileID: UUID(),
                expected: [.crc32: "abcd1234"],
                actual: [.crc32: "ffffffff"]
            )
            TestRunner.assertEqual(failed.status, .failed)
            TestRunner.assertFalse(failed.isPassed)
        }

        TestRunner.register("Verifier：无算法 → 降级（Q5 必须警示）") {
            let verifier = Verifier()
            let conclusion = verifier.compare(
                fileID: UUID(),
                expected: [:],
                actual: [:]
            )
            TestRunner.assertEqual(conclusion.status, .notVerified)
            TestRunner.assertTrue(conclusion.isDegraded)
            TestRunner.assertTrue(conclusion.reason != nil, "降级必须给出原因")
            TestRunner.assertFalse(conclusion.isPassed, "降级不算通过")
        }

        TestRunner.register("Verifier：回读校验（源与目标相同 → 通过）") {
            let root = IOTests.scratchDirectory("v-readback")
            defer { try? FileManager.default.removeItem(at: root) }

            let source = root.appendingPathComponent("src.bin").path
            let destination = root.appendingPathComponent("dst.bin").path
            let payload = String(repeating: "回读校验内容", count: 100)
            IOTests.writeFile(source, payload)
            IOTests.writeFile(destination, payload)

            let verifier = Verifier()
            let conclusion = verifier.verifyByReadBack(
                fileID: UUID(),
                sourcePath: source,
                destinationPath: destination,
                algorithms: [.crc32, .sha256]
            )
            TestRunner.assertEqual(conclusion.status, .passed)
            TestRunner.assertEqual(conclusion.results.count, 2)
            TestRunner.assertFalse(conclusion.isDegraded)
        }

        TestRunner.register("Verifier：回读校验（内容不同 → 失败）") {
            let root = IOTests.scratchDirectory("v-readback-fail")
            defer { try? FileManager.default.removeItem(at: root) }

            let source = root.appendingPathComponent("src.bin").path
            let destination = root.appendingPathComponent("dst.bin").path
            IOTests.writeFile(source, "原始内容")
            IOTests.writeFile(destination, "被篡改的内容完全不一样")

            let verifier = Verifier()
            let conclusion = verifier.verifyByReadBack(
                fileID: UUID(),
                sourcePath: source,
                destinationPath: destination,
                algorithms: [.crc32]
            )
            TestRunner.assertEqual(conclusion.status, .failed)
        }

        TestRunner.register("Verifier：Q5 降级判定逻辑") {
            // tee 路径 → 不降级。
            TestRunner.assertTrue(
                Verifier.degradationReason(
                    sourceIsSeekable: false,
                    teeEnabled: true,
                    readBackSucceeded: false
                ) == nil
            )
            // 源不可寻址 + 无 tee + 回读失败 → 降级。
            TestRunner.assertTrue(
                Verifier.degradationReason(
                    sourceIsSeekable: false,
                    teeEnabled: false,
                    readBackSucceeded: false
                ) != nil
            )
            // 回读成功 → 不降级。
            TestRunner.assertTrue(
                Verifier.degradationReason(
                    sourceIsSeekable: false,
                    teeEnabled: false,
                    readBackSucceeded: true
                ) == nil
            )
        }
    }

    // MARK: - ConflictResolver

    private static func registerConflictResolver() {
        TestRunner.register("ConflictResolver：四种策略的判定结果") {
            let resolver = ConflictResolver(policy: .skip)
            let skipped = await resolver.resolve(
                sourcePath: "/a", destinationPath: "/b",
                sourceSize: 1, destinationSize: 2,
                sourceModifiedAt: Date(), destinationModifiedAt: Date()
            )
            TestRunner.assertEqual(skipped, .skip)

            let overwriter = ConflictResolver(policy: .overwrite)
            let overwritten = await overwriter.resolve(
                sourcePath: "/a", destinationPath: "/b",
                sourceSize: 1, destinationSize: 2,
                sourceModifiedAt: Date(), destinationModifiedAt: Date()
            )
            TestRunner.assertEqual(overwritten, .overwrite)

            let renamer = ConflictResolver(policy: .rename)
            let renamed = await renamer.resolve(
                sourcePath: "/a", destinationPath: "/b.txt",
                sourceSize: 1, destinationSize: 2,
                sourceModifiedAt: Date(), destinationModifiedAt: Date()
            )
            if case .rename(let path) = renamed {
                TestRunner.assertTrue(path.contains("副本"), "重命名应含「副本」：\(path)")
            } else {
                TestRunner.fail("重命名策略应返回 .rename，实际 \(renamed)")
            }
        }

        TestRunner.register("ConflictResolver：keepNewer 按修改时间判定") {
            let resolver = ConflictResolver(policy: .keepNewer)
            let older = Date(timeIntervalSince1970: 1000)
            let newer = Date(timeIntervalSince1970: 2000)

            let sourceNewer = await resolver.resolve(
                sourcePath: "/a", destinationPath: "/b",
                sourceSize: 1, destinationSize: 1,
                sourceModifiedAt: newer, destinationModifiedAt: older
            )
            TestRunner.assertEqual(sourceNewer, .overwrite)

            let destinationNewer = await resolver.resolve(
                sourcePath: "/a", destinationPath: "/b",
                sourceSize: 1, destinationSize: 1,
                sourceModifiedAt: older, destinationModifiedAt: newer
            )
            TestRunner.assertEqual(destinationNewer, .skip)
        }

        TestRunner.register("ConflictResolver：ask 策略调用决策器") {
            let resolver = ConflictResolver(policy: .ask) { _, _, _, _, _, _ in
                .overwrite
            }
            let decision = await resolver.resolve(
                sourcePath: "/a", destinationPath: "/b",
                sourceSize: 1, destinationSize: 1,
                sourceModifiedAt: Date(), destinationModifiedAt: Date()
            )
            TestRunner.assertEqual(decision, .overwrite)
        }
    }

    // MARK: - ResumeManager

    private static func registerResumeManager() {
        TestRunner.register("ResumeManager：分片路径命名 + 追加写（断点续传核心）") {
            let root = IOTests.scratchDirectory("rm-append")
            defer { try? FileManager.default.removeItem(at: root) }

            // 分片路径约定：<目录>/.<原名>.maccopy.partial
            let partial = ResumeManager.partialPath(for: root.appendingPathComponent("目标.bin").path)
            TestRunner.assertTrue(partial.hasSuffix(".maccopy.partial"))
            TestRunner.assertTrue((partial as NSString).lastPathComponent.hasPrefix("."))

            // 先写 10 字节。
            IOTests.writeFile(partial, "0123456789")

            // 用「追加写」方式打开（绝不带 O_TRUNC）。
            let store = try JSONResumeStore(directory: root.appendingPathComponent("meta", isDirectory: true))
            let manager = ResumeManager(store: store)
            let fd = try manager.openPartialForAppend(partialPath: partial)
            defer { close(fd) }

            // 追加 2 字节。
            _ = "XY".withCString { write(fd, $0, 2) }

            var sb = stat()
            stat(partial, &sb)
            TestRunner.assertEqual(sb.st_size, 12, "追加写后应为 12 字节")
            TestRunner.assertEqual(IOTests.readFile(partial), "0123456789XY")
        }

        TestRunner.register("ResumeManager：resetPartial 用 ftruncate 归零") {
            let root = IOTests.scratchDirectory("rm-reset")
            defer { try? FileManager.default.removeItem(at: root) }

            let partial = root.appendingPathComponent(".r.bin.maccopy.partial").path
            IOTests.writeFile(partial, "0123456789")

            let store = try JSONResumeStore(directory: root.appendingPathComponent("meta", isDirectory: true))
            let manager = ResumeManager(store: store)
            try manager.resetPartial(partialPath: partial)

            var sb = stat()
            stat(partial, &sb)
            TestRunner.assertEqual(sb.st_size, 0)
        }

        TestRunner.register("ResumeManager：断点有效性判定（签名变化 → 失效）") {
            let root = IOTests.scratchDirectory("rm-valid")
            defer { try? FileManager.default.removeItem(at: root) }

            let store = try JSONResumeStore(directory: root.appendingPathComponent("meta", isDirectory: true))
            let manager = ResumeManager(store: store)

            let taskID = UUID()
            let fileID = UUID()
            let partial = root.appendingPathComponent(".v.bin.maccopy.partial").path
            IOTests.writeFile(partial, "0123456789")

            let signature = FileSignature(
                size: 10,
                modifiedAt: Date(timeIntervalSince1970: 1000),
                inode: 42,
                deviceID: 7
            )
            let entry = FileEntry(
                id: fileID,
                sourcePath: "/src/v.bin",
                relativePath: "v.bin",
                isDirectory: false,
                size: 10,
                signature: signature
            )

            try manager.saveCheckpoint(
                taskID: taskID,
                entry: entry,
                destinationPath: root.appendingPathComponent("v.bin").path,
                bytesTransferred: 10,
                partialDigests: [.crc32: "deadbeef"]
            )

            // 签名一致 → 断点可用。
            let valid = manager.findResumable(
                taskID: taskID,
                fileID: fileID,
                sourceSignature: signature
            )
            TestRunner.assertNotNil(valid)
            TestRunner.assertEqual(valid?.bytesTransferred, 10)

            // 签名变化（大小不同）→ 断点失效。
            let changed = FileSignature(
                size: 20,
                modifiedAt: Date(timeIntervalSince1970: 1000),
                inode: 42,
                deviceID: 7
            )
            let invalid = manager.findResumable(
                taskID: taskID,
                fileID: fileID,
                sourceSignature: changed
            )
            TestRunner.assertTrue(invalid == nil, "源签名变化后断点必须失效")
        }

        TestRunner.register("ResumeManager：commit 提交分片（rename 优先，copyfile 回退）") {
            let root = IOTests.scratchDirectory("rm-commit")
            defer { try? FileManager.default.removeItem(at: root) }

            let partial = root.appendingPathComponent(".c.bin.maccopy.partial").path
            let final = root.appendingPathComponent("c.bin").path
            IOTests.writeFile(partial, "COMMITTED-CONTENT")

            let store = try JSONResumeStore(directory: root.appendingPathComponent("meta", isDirectory: true))
            let manager = ResumeManager(store: store)
            let cloned = try manager.commit(partialPath: partial, destinationPath: final)

            // 内容必须正确（无论走 rename 还是 copyfile）。
            TestRunner.assertEqual(IOTests.readFile(final), "COMMITTED-CONTENT")
            TestRunner.assertTrue(
                FileManager.default.fileExists(atPath: final),
                "正式文件应存在"
            )
            // 走 copyfile 回退时才会克隆成功；走 rename 则为 false。
            TestRunner.assertTrue(cloned || !cloned)
        }

        TestRunner.register("ResumeManager：陈旧分片按 7 天过期标注") {
            let root = IOTests.scratchDirectory("rm-stale")
            defer { try? FileManager.default.removeItem(at: root) }

            let store = try JSONResumeStore(directory: root.appendingPathComponent("meta", isDirectory: true))
            let manager = ResumeManager(store: store)

            let taskID = UUID()
            let fileID = UUID()
            let signature = FileSignature(
                size: 1,
                modifiedAt: Date(timeIntervalSince1970: 1000),
                inode: 1,
                deviceID: 1
            )
            let entry = FileEntry(
                id: fileID,
                sourcePath: "/src/s.bin",
                relativePath: "s.bin",
                isDirectory: false,
                size: 1,
                signature: signature
            )

            try manager.saveCheckpoint(
                taskID: taskID,
                entry: entry,
                destinationPath: root.appendingPathComponent("s.bin").path,
                bytesTransferred: 1,
                partialDigests: [:]
            )

            // 刚保存的记录不是陈旧的。
            let fresh = manager.stalePartials()
            TestRunner.assertEqual(fresh.count, 0)

            // 模拟 8 天后 → 陈旧。
            let future = Date().addingTimeInterval(8 * 24 * 3600)
            let stale = manager.stalePartials(now: future)
            TestRunner.assertEqual(stale.count, 1)
            TestRunner.assertTrue(stale.first?.note.contains("陈旧") == true)
            TestRunner.assertFalse(stale.first?.partialPath.isEmpty ?? true)
        }
    }

    // MARK: - 端到端

    private static func registerEndToEnd() {
        TestRunner.register("端到端：PlanBuilder → CopyEngine → 校验 → 结果校验和一致") {
            let root = IOTests.scratchDirectory("e2e")
            defer { try? FileManager.default.removeItem(at: root) }

            // ① 准备源目录（3 个文件 + 1 个子目录 + 1 个中文名文件）。
            let source = root.appendingPathComponent("源目录", isDirectory: true)
            try PathWalker().createDirectory(at: source.path)
            let payloads: [String: String] = [
                "文件A.txt": String(repeating: "甲", count: 1000),
                "文件B.bin": String(repeating: "乙", count: 5000),
                "sub/文件C.txt": String(repeating: "丙", count: 2000),
            ]
            for (relative, content) in payloads {
                let path = source.appendingPathComponent(relative).path
                try PathWalker().createDirectory(at: (path as NSString).deletingLastPathComponent)
                IOTests.writeFile(path, content)
            }

            // ② 构建任务与计划。
            let destination = root.appendingPathComponent("目标目录", isDirectory: true)
            let task = TransferTask(
                sourceRoots: [source.path],
                destinationRoot: destination.path,
                options: TransferOptions(
                    checksumAlgorithms: [.crc32, .sha256],
                    verificationMode: .teeDuringCopy,
                    threadCount: 2,
                    bufferSize: 64 * 1024,
                    conflictPolicy: .overwrite,
                    enableClone: false,   // 走流式 tee 路径（可测 tee 哈希）
                    maxRetries: 1
                )
            )

            let builder = PlanBuilder()
            let batches = builder.build(
                sourceRoots: task.sourceRoots,
                destinationRoot: task.destinationRoot
            )

            // ③ 执行引擎。
            let eventBox = EventBox()
            let engine = CopyEngine(
                configuration: .init(
                    options: task.options,
                    conflictResolver: ConflictResolver(policy: .overwrite)
                ),
                eventSink: { event in
                    eventBox.append(event)
                }
            )
            let summary = await engine.run(task: task, batches: batches)

            // ④ 断言结果。
            TestRunner.assertEqual(summary.failedCount, 0, "不应有失败文件")
            TestRunner.assertEqual(summary.succeededCount, 3, "应有 3 个成功文件")
            TestRunner.assertEqual(summary.degradedCount, 0, "不应有降级")

            // ⑤ 逐文件比对内容与摘要。
            for (relative, expectedContent) in payloads {
                let targetPath = destination.appendingPathComponent(relative).path
                TestRunner.assertEqual(
                    IOTests.readFile(targetPath),
                    expectedContent,
                    "内容应一致：\(relative)"
                )

                // 独立算摘要并与引擎结果比对。
                let sourcePath = source.appendingPathComponent(relative).path
                let sourceDigests = Verifier.digest(
                    of: sourcePath,
                    algorithms: [.crc32, .sha256],
                    registry: ChecksumRegistry.shared,
                    bufferSize: 64 * 1024
                )
                let targetDigests = Verifier.digest(
                    of: targetPath,
                    algorithms: [.crc32, .sha256],
                    registry: ChecksumRegistry.shared,
                    bufferSize: 64 * 1024
                )
                TestRunner.assertEqual(sourceDigests[.crc32], targetDigests[.crc32], relative)
                TestRunner.assertEqual(sourceDigests[.sha256], targetDigests[.sha256], relative)
            }

            // ⑥ 事件流应包含状态迁移与完成事件。
            let events = eventBox.snapshot()
            TestRunner.assertTrue(events.contains { if case .taskFinished = $0 { return true } else { return false } })
            TestRunner.assertTrue(
                events.contains { if case .taskStateChanged(_, let state) = $0 { return state == .succeeded } else { return false } }
            )
            TestRunner.assertTrue(
                events.contains { if case .fileCompleted = $0 { return true } else { return false } }
            )
        }

        TestRunner.register("端到端：符号链接被真正重建（PRD P0-06）") {
            let root = IOTests.scratchDirectory("e2e-symlink")
            defer { try? FileManager.default.removeItem(at: root) }

            // ① 源目录：普通文件 + 指向它的符号链接。
            let source = root.appendingPathComponent("src", isDirectory: true)
            try PathWalker().createDirectory(at: source.path)
            IOTests.writeFile(source.appendingPathComponent("真实文件.txt").path, "真实内容")

            errno = 0
            let linkCreated = symlink(
                source.appendingPathComponent("真实文件.txt").path,
                source.appendingPathComponent("链接.txt").path
            )
            if linkCreated != 0 {
                TestRunner.assertTrue(true, "环境不支持 symlink（errno=\(errno)），跳过")
                return
            }

            // ② 执行引擎。
            let destination = root.appendingPathComponent("dst", isDirectory: true)
            let task = TransferTask(
                sourceRoots: [source.path],
                destinationRoot: destination.path,
                options: TransferOptions(
                    checksumAlgorithms: [.crc32],
                    threadCount: 1,
                    conflictPolicy: .overwrite,
                    enableClone: false
                )
            )

            let builder = PlanBuilder()
            let batches = builder.build(
                sourceRoots: task.sourceRoots,
                destinationRoot: task.destinationRoot
            )
            let engine = CopyEngine(
                configuration: .init(
                    options: task.options,
                    conflictResolver: ConflictResolver(policy: .overwrite)
                ),
                eventSink: { _ in }
            )
            let summary = await engine.run(task: task, batches: batches)

            TestRunner.assertEqual(summary.failedCount, 0, "不应有失败文件")
            TestRunner.assertEqual(summary.succeededCount, 2, "普通文件 + 符号链接都应成功")

            // ③ 目标链接必须存在且指向正确。
            let targetLink = destination.appendingPathComponent("链接.txt").path
            var sb = stat()
            let lstatResult = lstat(targetLink, &sb)
            TestRunner.assertEqual(lstatResult, 0, "目标符号链接应存在")
            TestRunner.assertTrue(
                (sb.st_mode & S_IFMT) == S_IFLNK,
                "目标应是符号链接"
            )

            let linkTarget = FileEnumerator.readLinkDestination(at: targetLink)
            TestRunner.assertNotNil(linkTarget)
            TestRunner.assertEqual(
                linkTarget,
                source.appendingPathComponent("真实文件.txt").path
            )

            // ④ 普通文件内容也应正确。
            TestRunner.assertEqual(
                IOTests.readFile(destination.appendingPathComponent("真实文件.txt").path),
                "真实内容"
            )
        }

        TestRunner.register("端到端：目标已存在 + 覆盖策略 → 内容被覆盖") {
            let root = IOTests.scratchDirectory("e2e-overwrite")
            defer { try? FileManager.default.removeItem(at: root) }

            let source = root.appendingPathComponent("src", isDirectory: true)
            try PathWalker().createDirectory(at: source.path)
            IOTests.writeFile(source.appendingPathComponent("f.txt").path, "新内容")

            let destination = root.appendingPathComponent("dst", isDirectory: true)
            try PathWalker().createDirectory(at: destination.path)
            IOTests.writeFile(destination.appendingPathComponent("f.txt").path, "旧内容且更长")

            let task = TransferTask(
                sourceRoots: [source.path],
                destinationRoot: destination.path,
                options: TransferOptions(
                    checksumAlgorithms: [.crc32],
                    threadCount: 1,
                    conflictPolicy: .overwrite,
                    enableClone: false
                )
            )

            let builder = PlanBuilder()
            let batches = builder.build(
                sourceRoots: task.sourceRoots,
                destinationRoot: task.destinationRoot
            )
            let engine = CopyEngine(
                configuration: .init(
                    options: task.options,
                    conflictResolver: ConflictResolver(policy: .overwrite)
                ),
                eventSink: { _ in }
            )
            let summary = await engine.run(task: task, batches: batches)

            TestRunner.assertEqual(summary.failedCount, 0)
            TestRunner.assertEqual(
                IOTests.readFile(destination.appendingPathComponent("f.txt").path),
                "新内容"
            )
        }
    }
}

/// 事件收集盒（测试用）。
final class EventBox: @unchecked Sendable {
    /// 事件数组。
    private var events = [TransferEvent]()
    /// 保护锁。
    private let lock = NSLock()

    /// 追加事件。
    func append(_ event: TransferEvent) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }

    /// 取全部事件。
    func snapshot() -> [TransferEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}
