import Foundation
import Darwin
import MacCopyKit

/// QA 第二轮 4 个缺陷的回归（BUG-03 数据损坏 / BUG-04 速度恒 0 /
/// BUG-05 xattr 复制不到 / BUG-06 文件口径进度恒 0）。
@MainActor
enum QABugRegressionTests {
    static func register() {
        registerSparseProbe()
        registerSpeedSampler()
        registerXattr()
        registerProgressTracker()
        registerRound2Defects()
    }

    // MARK: - QA 第 2 轮：缺陷 A（限速被克隆路径绕过）/ B（字节口径重复累加）

    private static func registerRound2Defects() {
        TestRunner.register("缺陷 B：8 MiB 文件 transferredBytes 应恰好 8 MiB，不重复累加") {
            let root = IOTests.scratchDirectory("qa-progress-8m")
            defer { try? FileManager.default.removeItem(at: root) }

            let source = root.appendingPathComponent("src", isDirectory: true)
            try PathWalker().createDirectory(at: source.path)
            let payload = [UInt8](repeating: 0x5C, count: 8 * 1024 * 1024)
            let fileURL = source.appendingPathComponent("big.bin")
            let fd = open(fileURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            _ = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            close(fd)

            let destination = root.appendingPathComponent("dst", isDirectory: true)
            let task = TransferTask(
                sourceRoots: [source.path],
                destinationRoot: destination.path,
                options: TransferOptions(
                    checksumAlgorithms: [.crc32],
                    threadCount: 1,
                    conflictPolicy: .overwrite,
                    enableClone: false       // 强制走 stream，暴露 ≥4 MiB 的重复计数
                )
            )
            let engine = CopyEngine(
                configuration: .init(
                    options: task.options,
                    conflictResolver: ConflictResolver(policy: .overwrite)
                ),
                eventSink: { _ in }
            )
            let batches = PlanBuilder().build(
                sourceRoots: task.sourceRoots,
                destinationRoot: task.destinationRoot
            )
            let summary = await engine.run(task: task, batches: batches)
            TestRunner.assertEqual(summary.succeededCount, 1)

            let progress = await engine.progress
            TestRunner.assertEqual(
                progress.transferredBytes,
                Int64(8 * 1024 * 1024),
                "8 MiB 文件不应被报成 20 MiB（4M + 8M + 8M 的旧行为）"
            )
            TestRunner.assertEqual(
                summary.transferredBytes,
                Int64(8 * 1024 * 1024),
                "汇总里的字节数也必须正确"
            )
        }

        TestRunner.register("缺陷 B：StreamCopier 回调增量之和等于传输总量") {
            let root = IOTests.scratchDirectory("qa-delta")
            defer { try? FileManager.default.removeItem(at: root) }

            let source = root.appendingPathComponent("src.bin").path
            let destination = root.appendingPathComponent("dst.bin").path
            let size = 10 * 1024 * 1024
            let payload = [UInt8](repeating: 0x77, count: size)
            let fd = open(source, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            _ = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            close(fd)

            let sourceFD = open(source, O_RDONLY)
            let destinationFD = open(destination, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            defer {
                if sourceFD >= 0 { close(sourceFD) }
                if destinationFD >= 0 { close(destinationFD) }
            }

            let collector = DeltaCollector()
            var hasher = MultiHasher(algorithms: [.crc32])
            let result = try await StreamCopier().copy(
                sourceFD: sourceFD,
                destinationFD: destinationFD,
                startOffset: 0,
                bufferSize: 64 * 1024,
                hasher: &hasher,
                onProgress: { delta in await collector.add(delta) }
            )
            TestRunner.assertEqual(result.transferredBytes, Int64(size))
            let sum = await collector.sum
            TestRunner.assertEqual(sum, result.transferredBytes, "回调增量之和必须等于总量")
        }

        TestRunner.register("缺陷 A：默认克隆配置下限速仍生效（不被静默绕过）") {
            let root = IOTests.scratchDirectory("qa-throttle-clone")
            defer { try? FileManager.default.removeItem(at: root) }

            let source = root.appendingPathComponent("src", isDirectory: true)
            try PathWalker().createDirectory(at: source.path)
            let payload = [UInt8](repeating: 0x2E, count: 4 * 1024 * 1024)
            let fd = open(source.appendingPathComponent("f.bin").path,
                          O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            _ = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            close(fd)

            let destination = root.appendingPathComponent("dst", isDirectory: true)
            // 默认配置恰好命中 clone 分支：enableClone=true + crc32。
            // 限速 1 MiB/s 时必须强制走 stream，4 MiB 应耗时 ≥3 秒。
            let options = TransferOptions(
                checksumAlgorithms: [.crc32],
                threadCount: 1,
                conflictPolicy: .overwrite,
                enableClone: true,
                bandwidthLimitBytesPerSecond: 1 * 1024 * 1024
            )
            let task = TransferTask(
                sourceRoots: [source.path],
                destinationRoot: destination.path,
                options: options
            )
            let engine = CopyEngine(
                configuration: .init(
                    options: options,
                    conflictResolver: ConflictResolver(policy: .overwrite)
                ),
                eventSink: { _ in }
            )
            let batches = PlanBuilder().build(
                sourceRoots: task.sourceRoots,
                destinationRoot: task.destinationRoot
            )
            let started = Date()
            let summary = await engine.run(task: task, batches: batches)
            let elapsed = Date().timeIntervalSince(started)

            TestRunner.assertEqual(summary.succeededCount, 1)
            TestRunner.assertTrue(
                elapsed >= 2.5,
                "限速应显著拖慢复制（实测 \(elapsed) 秒），克隆路径不得绕过 TokenBucket"
            )
            // 内容逐字节一致（二进制，不能用 String 解码）。
            let written = FileManager.default.contents(
                atPath: destination.appendingPathComponent("f.bin").path
            ) ?? Data()
            TestRunner.assertEqual(written.count, payload.count)
            TestRunner.assertEqual(Array(written), payload)
        }
    }
    // MARK: - BUG-03：SparseProbe 把数据段误报成空洞

    private static func registerSparseProbe() {
        TestRunner.register("BUG-03：两段数据的稀疏文件，空洞区间必须指向真正的空洞") {
            let root = IOTests.scratchDirectory("qa-sparse")
            defer { try? FileManager.default.removeItem(at: root) }

            let path = root.appendingPathComponent("sparse.bin").path
            let size: Int64 = 64 * 1024 * 1024
            let chunk: Int64 = 16 * 1024

            let fd = open(path, O_CREAT | O_RDWR, 0o644)
            TestRunner.assertTrue(fd >= 0)
            defer { close(fd) }

            let (tr, code) = Syscall.call { ftruncate(fd, size) }
            TestRunner.assertEqual(tr, 0, "ftruncate 应成功 errno=\(code)")

            // 写两段数据：[0,16KiB) 与 [32MiB, 32MiB+16KiB)。
            let bytes = [UInt8](repeating: 0xAB, count: Int(chunk))
            _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            _ = lseek(fd, 32 * 1024 * 1024, SEEK_SET)
            _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }

            let holes = SparseProbe().holes(in: fd, size: size)
            let total = SparseProbe.totalHoleBytes(holes)

            // 真实空洞应为：[16KiB, 32MiB) 与 [32MiB+16KiB, 64MiB)
            // 总长 = 64MiB - 2*16KiB。
            let expected = size - 2 * chunk
            TestRunner.assertEqual(total, expected, "空洞总长应为 64MiB 减去两段数据")

            // 关键：空洞不能落在数据段起点上（BUG-03 的症状）。
            for hole in holes {
                TestRunner.assertFalse(
                    hole.offset == 0 || hole.offset == 32 * 1024 * 1024,
                    "空洞起点不能是数据段起点，实际 offset=\(hole.offset)"
                )
            }
            // 每个空洞区间内的字节都应为 0，数据段内都应为 0xAB。
            var probe = [UInt8](repeating: 0xFF, count: 1)
            for hole in holes.prefix(2) {
                _ = lseek(fd, hole.offset, SEEK_SET)
                _ = probe.withUnsafeMutableBytes { read(fd, $0.baseAddress, 1) }
                TestRunner.assertEqual(probe[0], 0, "空洞内应为 0")
            }
            _ = lseek(fd, 0, SEEK_SET)
            _ = probe.withUnsafeMutableBytes { read(fd, $0.baseAddress, 1) }
            TestRunner.assertEqual(probe[0], 0xAB, "数据段内容不应被当空洞")
        }
    }

    // MARK: - BUG-04：高频事件下采样点恒为 1

    private static func registerSpeedSampler() {
        TestRunner.register("BUG-04：每 0.2s 采样 20 次应得到约 4 个点，速度非 0") {
            var sampler = SpeedSampler()
            let t0 = Date(timeIntervalSince1970: 0)
            var cumulative: Int64 = 0
            for i in 0..<20 {
                cumulative += 1024 * 1024
                sampler.sample(
                    bytes: cumulative,
                    now: t0.addingTimeInterval(Double(i) * 0.2)
                )
            }
            TestRunner.assertTrue(
                sampler.allSamples.count >= 3,
                "采样点不应恒为 1，实际 \(sampler.allSamples.count)"
            )
            TestRunner.assertTrue(sampler.instantaneous > 0, "瞬时速度不应为 0")
            TestRunner.assertNotNil(sampler.eta(remainingBytes: 10 * 1024 * 1024))
        }

        TestRunner.register("BUG-04：每 0.5s 采样 40 次（模拟 CopyEngine）速度非 0") {
            var sampler = SpeedSampler()
            let t0 = Date(timeIntervalSince1970: 0)
            var cumulative: Int64 = 0
            for i in 0..<40 {
                cumulative += 4 * 1024 * 1024
                sampler.sample(
                    bytes: cumulative,
                    now: t0.addingTimeInterval(Double(i) * 0.5)
                )
            }
            TestRunner.assertTrue(sampler.instantaneous > 0)
            TestRunner.assertTrue(sampler.average > 0)
        }
    }

    // MARK: - BUG-05：xattr 属性名解析

    private static func registerXattr() {
        TestRunner.register("BUG-05：copyExtendedAttributes 能真正复制用户 xattr") {
            let root = IOTests.scratchDirectory("qa-xattr")
            defer { try? FileManager.default.removeItem(at: root) }

            let source = root.appendingPathComponent("src.bin").path
            let destination = root.appendingPathComponent("dst.bin").path
            IOTests.writeFile(source, "S")
            IOTests.writeFile(destination, "D")

            let value = Array("hello".utf8)
            let setResult = value.withUnsafeBytes { raw -> Int32 in
                setxattr(source, "user.qa.test", raw.baseAddress, raw.count, 0, 0)
            }
            if setResult != 0 {
                // 环境不支持 setxattr → 跳过（v5 已标注为平台限制）。
                TestRunner.assertTrue(true, "环境不支持 setxattr，跳过")
                return
            }

            let copied = MetadataOps.copyExtendedAttributes(
                from: source, to: destination
            )
            TestRunner.assertEqual(copied, 1, "应复制 1 个用户 xattr")

            var buffer = [UInt8](repeating: 0, count: 64)
            let got = buffer.withUnsafeMutableBytes { raw -> Int in
                getxattr(destination, "user.qa.test", raw.baseAddress, 64, 0, 0)
            }
            TestRunner.assertEqual(got, 5)
            TestRunner.assertEqual(Array(buffer.prefix(5)), value)
        }
    }

    // MARK: - BUG-06：文件口径进度

    private static func registerProgressTracker() {
        TestRunner.register("BUG-06：ProgressTracker 三个计数方法都能累加并反映在 snapshot") {
            var tracker = ProgressTracker()
            tracker.begin(totalBytes: 100, totalFiles: 5)
            tracker.completeFile()
            tracker.completeFile()
            tracker.failFile()
            tracker.skipFile()

            let progress = tracker.snapshot()
            TestRunner.assertEqual(progress.completedFiles, 2)
            TestRunner.assertEqual(progress.failedFiles, 1)
            TestRunner.assertEqual(progress.skippedFiles, 1)
        }

        TestRunner.register("BUG-06：CopyEngine 端到端后文件口径进度不为 0") {
            let root = IOTests.scratchDirectory("qa-progress")
            defer { try? FileManager.default.removeItem(at: root) }

            let source = root.appendingPathComponent("src", isDirectory: true)
            try PathWalker().createDirectory(at: source.path)
            for i in 0..<3 {
                IOTests.writeFile(
                    source.appendingPathComponent("f\(i).txt").path,
                    String(repeating: "X", count: 1000)
                )
            }
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
            let engine = CopyEngine(
                configuration: .init(
                    options: task.options,
                    conflictResolver: ConflictResolver(policy: .overwrite)
                ),
                eventSink: { _ in }
            )
            let batches = PlanBuilder().build(
                sourceRoots: task.sourceRoots,
                destinationRoot: task.destinationRoot
            )
            let summary = await engine.run(task: task, batches: batches)
            TestRunner.assertEqual(summary.succeededCount, 3)

            let progress = await engine.progress
            TestRunner.assertEqual(
                progress.completedFiles, 3,
                "文件口径进度必须跟上字节口径（此前恒 0）"
            )
            TestRunner.assertEqual(progress.failedFiles, 0)
            TestRunner.assertTrue(progress.transferredBytes > 0, "字节口径仍应正确")
        }
    }
}

/// 收集 StreamCopier 的增量回调（actor 隔离，避免并发写竞态）。
actor DeltaCollector {
    private var total: Int64 = 0
    func add(_ delta: Int64) { total += delta }
    var sum: Int64 { total }
}
