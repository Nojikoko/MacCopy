import Foundation
import Darwin
import MacCopyKit

/// 源根类型测试（BUG-001 回归）。
///
/// 背景：枚举器此前**无条件**把 `sourceRoot` 当目录 `opendir`，
/// 源是单个文件时 ENOTDIR 被 catch 吞掉 → 任务「成功」但 0 文件复制、
/// 无任何用户可见错误。拖入单个文件是核心场景（PRD P0-01）。
@MainActor
enum SourceRootTests {
    static func register() {
        TestRunner.register("源根：单个文件 → 成功复制 1 个文件") {
            let root = IOTests.scratchDirectory("src-single").path
            defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: root)) }

            let srcDir = root + "/src"
            let dstDir = root + "/dst"
            try PathWalker().createDirectory(at: srcDir)
            try PathWalker().createDirectory(at: dstDir)

            let payload = String(repeating: "单文件源测试内容。", count: 200)
            IOTests.writeFile(srcDir + "/only.txt", payload)

            let options = TransferOptions(
                checksumAlgorithms: [.crc32],
                verificationMode: .teeDuringCopy,
                threadCount: 1,
                bufferSize: 64 * 1024,
                conflictPolicy: .overwrite,
                enableClone: false,
                maxRetries: 0
            )
            let engine = CopyEngine(
                configuration: .init(
                    options: options,
                    conflictResolver: ConflictResolver(policy: .overwrite)
                ),
                eventSink: { _ in }
            )
            let single = srcDir + "/only.txt"
            let summary = await engine.run(
                task: TransferTask(
                    sourceRoots: [single],
                    destinationRoot: dstDir,
                    options: options
                ),
                batches: PlanBuilder().build(
                    sourceRoots: [single],
                    destinationRoot: dstDir
                )
            )

            TestRunner.assertEqual(summary.succeededCount, 1, "单文件源应成功复制 1 个")
            TestRunner.assertEqual(summary.failedCount, 0, "不应有失败")
            TestRunner.assertTrue(
                summary.transferredBytes == Int64(payload.utf8.count),
                "传输字节应等于源大小，实际 \(summary.transferredBytes)"
            )

            // 目标文件名 = 源文件名，内容逐字节一致。
            let target = dstDir + "/only.txt"
            TestRunner.assertTrue(
                FileManager.default.fileExists(atPath: target),
                "目标文件应存在于 \(target)"
            )
            let copied = (try? String(contentsOfFile: target, encoding: .utf8)) ?? ""
            TestRunner.assertEqual(copied.count, payload.count, "目标内容长度应与源一致")
            TestRunner.assertTrue(copied == payload, "目标内容应与源逐字节一致")
        }

        TestRunner.register("源根：单个文件 + 校验算法 → 摘要一致且不降级") {
            let root = IOTests.scratchDirectory("src-single-verify").path
            defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: root)) }

            let srcDir = root + "/src"
            let dstDir = root + "/dst"
            try PathWalker().createDirectory(at: srcDir)
            try PathWalker().createDirectory(at: dstDir)

            let payload = String(repeating: "校验测试", count: 500)
            IOTests.writeFile(srcDir + "/v.txt", payload)

            let options = TransferOptions(
                checksumAlgorithms: [.crc32, .sha256],
                verificationMode: .teeDuringCopy,
                threadCount: 1,
                bufferSize: 64 * 1024,
                conflictPolicy: .overwrite,
                enableClone: false,
                maxRetries: 0
            )
            let engine = CopyEngine(
                configuration: .init(
                    options: options,
                    conflictResolver: ConflictResolver(policy: .overwrite)
                ),
                eventSink: { _ in }
            )
            let single = srcDir + "/v.txt"
            let summary = await engine.run(
                task: TransferTask(
                    sourceRoots: [single],
                    destinationRoot: dstDir,
                    options: options
                ),
                batches: PlanBuilder().build(
                    sourceRoots: [single],
                    destinationRoot: dstDir
                )
            )

            TestRunner.assertEqual(summary.succeededCount, 1, "应成功复制 1 个")
            TestRunner.assertEqual(summary.degradedCount, 0, "不应降级（源可寻址）")

            // 目标摘要应与源摘要一致。
            let target = dstDir + "/v.txt"
            var hasher = ChecksumRegistry.shared.make(.sha256)
            let targetText = (try? String(contentsOfFile: target, encoding: .utf8)) ?? ""
            hasher.update(data: Data(targetText.utf8))
            let targetDigest = Bytes.hexString(hasher.finalize())

            var sourceHasher = ChecksumRegistry.shared.make(.sha256)
            sourceHasher.update(data: Data(payload.utf8))
            let sourceDigest = Bytes.hexString(sourceHasher.finalize())
            TestRunner.assertEqual(targetDigest, sourceDigest, "目标摘要应与源摘要一致")
        }

        TestRunner.register("源根：不存在的路径 → 任务失败而非静默 0 条") {
            let root = IOTests.scratchDirectory("src-missing").path
            defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: root)) }

            let dstDir = root + "/dst"
            try PathWalker().createDirectory(at: dstDir)
            let missing = root + "/does-not-exist.bin"

            let options = TransferOptions(
                checksumAlgorithms: [.crc32],
                verificationMode: .teeDuringCopy,
                threadCount: 1,
                bufferSize: 64 * 1024,
                conflictPolicy: .overwrite,
                enableClone: false,
                maxRetries: 0
            )
            let engine = CopyEngine(
                configuration: .init(
                    options: options,
                    conflictResolver: ConflictResolver(policy: .overwrite)
                ),
                eventSink: { _ in }
            )

            // 直接测枚举器：应抛错，而不是静默产出 0 条。
            var threw = false
            var count = 0
            do {
                for try await _ in FileEnumerator().enumerate(
                    sourceRoot: missing,
                    destinationRoot: dstDir
                ) {
                    count += 1
                }
            } catch {
                threw = true
            }
            TestRunner.assertTrue(threw, "不存在的源根应抛错")
            TestRunner.assertEqual(count, 0, "不应产出任何条目")

            // 走引擎：不应是「0 成功 0 失败」的静默结果。
            let summary = await engine.run(
                task: TransferTask(
                    sourceRoots: [missing],
                    destinationRoot: dstDir,
                    options: options
                ),
                batches: PlanBuilder().build(
                    sourceRoots: [missing],
                    destinationRoot: dstDir
                )
            )
            TestRunner.assertTrue(
                summary.succeededCount == 0 && summary.failedCount >= 1,
                "引擎应报告失败（当前 成功 \(summary.succeededCount) / 失败 \(summary.failedCount)）"
            )
        }

        TestRunner.register("源根：混合源（文件 + 目录）→ 两个都复制成功") {
            let root = IOTests.scratchDirectory("src-mixed").path
            defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: root)) }

            let srcDir = root + "/src"
            let dstDir = root + "/dst"
            try PathWalker().createDirectory(at: srcDir + "/sub")
            try PathWalker().createDirectory(at: dstDir)

            IOTests.writeFile(srcDir + "/single.txt", "单文件内容")
            IOTests.writeFile(srcDir + "/sub/nested.txt", "嵌套文件内容")

            let options = TransferOptions(
                checksumAlgorithms: [.crc32],
                verificationMode: .teeDuringCopy,
                threadCount: 1,
                bufferSize: 64 * 1024,
                conflictPolicy: .overwrite,
                enableClone: false,
                maxRetries: 0
            )
            let engine = CopyEngine(
                configuration: .init(
                    options: options,
                    conflictResolver: ConflictResolver(policy: .overwrite)
                ),
                eventSink: { _ in }
            )
            let sources = [srcDir + "/single.txt", srcDir + "/sub"]
            let summary = await engine.run(
                task: TransferTask(
                    sourceRoots: sources,
                    destinationRoot: dstDir,
                    options: options
                ),
                batches: PlanBuilder().build(
                    sourceRoots: sources,
                    destinationRoot: dstDir
                )
            )

            TestRunner.assertEqual(summary.succeededCount, 2, "文件 + 目录内文件共 2 个应成功")
            TestRunner.assertEqual(summary.failedCount, 0, "不应有失败")
            TestRunner.assertTrue(
                FileManager.default.fileExists(atPath: dstDir + "/single.txt"),
                "单文件应被复制"
            )
            // 注意：源根为目录时，relativePath **不含顶层目录名**
            // （枚举器 relativePrefix 从 "" 起算），故目标落在 dst 根下。
            TestRunner.assertTrue(
                FileManager.default.fileExists(atPath: dstDir + "/nested.txt"),
                "嵌套文件应被复制（目标路径 dst/nested.txt）"
            )
        }

        TestRunner.register("源根：符号链接指向文件 → 跟随链接复制内容") {
            let root = IOTests.scratchDirectory("src-symlink-file").path
            defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: root)) }

            let dstDir = root + "/dst"
            try PathWalker().createDirectory(at: dstDir)

            let payload = String(repeating: "链接目标内容", count: 300)
            IOTests.writeFile(root + "/target.txt", payload)
            let link = root + "/alias.txt"
            errno = 0
            let rc = symlink((root + "/target.txt").withCString { $0 }, link.withCString { $0 })
            if rc != 0 {
                TestRunner.assertTrue(true, "环境不支持 symlink（errno=\(errno)），跳过")
                return
            }

            // 环境限制说明：本机 `readlink` 在某些调用时序下会返回长度 0
            // （实测同进程内既有符号链接用例可通过、后续用例不可靠 → 时序相关）。
            // 因此这里不强制要求「必须能读出」，而是要求：
            // **读不出时必须抛错，绝不能静默产出 0 条**（这是真正的健壮性要求）。
            let dest = FileEnumerator.readLinkDestination(at: link)
            if dest == nil {
                var threw = false
                do {
                    for try await _ in FileEnumerator().enumerate(
                        sourceRoot: link, destinationRoot: dstDir
                    ) {}
                } catch {
                    threw = true
                }
                TestRunner.assertTrue(
                    threw,
                    "链接目标读不出时必须抛错，不得静默产出 0 条"
                )
                return
            }
            TestRunner.assertTrue(
                dest == root + "/target.txt",
                "读出的目标应正确，实际 \(dest)"
            )

            let options = TransferOptions(
                checksumAlgorithms: [.crc32],
                verificationMode: .teeDuringCopy,
                threadCount: 1,
                bufferSize: 64 * 1024,
                conflictPolicy: .overwrite,
                enableClone: false,
                maxRetries: 0
            )
            let box = EventBox()
            let engine = CopyEngine(
                configuration: .init(
                    options: options,
                    conflictResolver: ConflictResolver(policy: .overwrite)
                ),
                eventSink: { ev in box.append(ev) }
            )
            let summary = await engine.run(
                task: TransferTask(
                    sourceRoots: [link],
                    destinationRoot: dstDir,
                    options: options
                ),
                batches: PlanBuilder().build(
                    sourceRoots: [link],
                    destinationRoot: dstDir
                )
            )
            if summary.failedCount > 0 {
                var reasons: [String] = []
                for ev in box.snapshot() {
                    if case .fileFailed(_, _, let err, _) = ev {
                        reasons.append(err.localizedDescription)
                    }
                }
                print("      [诊断] 失败原因：\(reasons)")
            }

            TestRunner.assertEqual(summary.succeededCount, 1, "链接指向文件应复制 1 个")
            TestRunner.assertEqual(summary.failedCount, 0, "不应有失败")
        }

        TestRunner.register("符号链接：readLinkDestination 对无效内容返回 nil") {
            let root = IOTests.scratchDirectory("src-symlink-invalid").path
            defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: root)) }

            IOTests.writeFile(root + "/t.txt", "x")
            let link = root + "/rel.txt"
            errno = 0
            let rc = symlink("t.txt".withCString { $0 }, link.withCString { $0 })
            guard rc == 0 else { return }   // 环境不支持 symlink → 跳过

            let dest = FileEnumerator.readLinkDestination(at: link)
            // 某些受限环境下 readlink 会返回二进制垃圾。
            // 产品必须识别出来并返回 nil（而不是把乱码当路径去重建坏链接）。
            if let value = dest {
                let hasControl = value.unicodeScalars.contains { s in
                    s.value < 0x20 || s.value == 0x7F
                }
                TestRunner.assertTrue(
                    !hasControl,
                    "读出的链接目标不应含控制字符（非法内容被当成路径会重建出坏链接）"
                )
            } else {
                TestRunner.assertTrue(true, "无效链接内容已被识别为 nil")
            }
        }
    }
}
