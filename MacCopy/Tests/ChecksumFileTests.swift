import Foundation
import Darwin
import MacCopyKit

/// 校验清单落盘测试（PRD P1-07）。
///
/// 验证：开启 generateChecksumFile 后，CopyEngine 会把成功文件的目标摘要
/// 写入目标目录，且格式能被系统 `shasum -c` 直接校验。
@MainActor
enum ChecksumFileTests {
    static func register() {
        TestRunner.register("校验清单：生成后可由 shasum -c 验证") {
            let root = IOTests.scratchDirectory("checksum-file")
            defer { try? FileManager.default.removeItem(at: root) }

            // ① 源目录：2 个文件（含中文名）。
            let source = root.appendingPathComponent("源", isDirectory: true)
            try PathWalker().createDirectory(at: source.path)
            IOTests.writeFile(
                source.appendingPathComponent("甲.txt").path,
                String(repeating: "甲", count: 777)
            )
            IOTests.writeFile(
                source.appendingPathComponent("乙.bin").path,
                String(repeating: "乙", count: 2048)
            )

            let destination = root.appendingPathComponent("目标", isDirectory: true)

            // ② 开启清单生成。
            var options = TransferOptions(
                checksumAlgorithms: [.sha256],
                verificationMode: .teeDuringCopy,
                threadCount: 2,
                bufferSize: 64 * 1024,
                conflictPolicy: .overwrite,
                enableClone: false,
                maxRetries: 1
            )
            options.generateChecksumFile = true

            let task = TransferTask(
                sourceRoots: [source.path],
                destinationRoot: destination.path,
                options: options
            )

            let batches = PlanBuilder().build(
                sourceRoots: task.sourceRoots,
                destinationRoot: task.destinationRoot
            )
            let engine = CopyEngine(
                configuration: .init(
                    options: options,
                    conflictResolver: ConflictResolver(policy: .overwrite)
                ),
                eventSink: { _ in }
            )
            let summary = await engine.run(task: task, batches: batches)

            TestRunner.assertEqual(summary.failedCount, 0, "复制不应失败")
            TestRunner.assertEqual(summary.succeededCount, 2, "应有 2 个成功文件")

            // ③ 清单文件必须存在。
            let ext = ChecksumFileWriter.fileExtension(for: .sha256)
            let manifest = destination.appendingPathComponent("MacCopy.\(ext)")
            let exists = FileManager.default.fileExists(atPath: manifest.path)
            TestRunner.assertTrue(exists, "应生成 MacCopy.\(ext) 清单")

            guard exists,
                  let text = try? String(contentsOf: manifest, encoding: .utf8) else {
                return
            }

            // ④ 格式：每行「64位hex  两个空格  相对路径」。
            let lines = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            TestRunner.assertEqual(lines.count, 2, "清单应有 2 行")
            for line in lines {
                TestRunner.assertTrue(line.count > 66, "行长度应包含摘要与路径：\(line)")
                TestRunner.assertTrue(
                    line.contains("  "),
                    "应使用两个空格分隔（shasum 惯例）"
                )
            }

            // ⑤ 用系统 shasum -c 真正校验（最强证据）。
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
            process.arguments = ["-a", "256", "-c", manifest.lastPathComponent]
            process.currentDirectoryURL = destination
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try? process.run()
            process.waitUntilExit()
            let output = String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            TestRunner.assertEqual(
                process.terminationStatus, 0,
                "shasum -c 应全部通过，实际输出：\(output)"
            )
        }

        TestRunner.register("校验清单：未开启时不生成文件") {
            let root = IOTests.scratchDirectory("checksum-off")
            defer { try? FileManager.default.removeItem(at: root) }

            let source = root.appendingPathComponent("源", isDirectory: true)
            try PathWalker().createDirectory(at: source.path)
            IOTests.writeFile(source.appendingPathComponent("a.txt").path, "hello")
            let destination = root.appendingPathComponent("目标", isDirectory: true)

            var options = TransferOptions(
                checksumAlgorithms: [.sha256],
                verificationMode: .teeDuringCopy,
                threadCount: 1,
                bufferSize: 64 * 1024,
                conflictPolicy: .overwrite,
                enableClone: false,
                maxRetries: 0
            )
            options.generateChecksumFile = false

            let task = TransferTask(
                sourceRoots: [source.path],
                destinationRoot: destination.path,
                options: options
            )
            let batches = PlanBuilder().build(
                sourceRoots: task.sourceRoots,
                destinationRoot: task.destinationRoot
            )
            let engine = CopyEngine(
                configuration: .init(
                    options: options,
                    conflictResolver: ConflictResolver(policy: .overwrite)
                ),
                eventSink: { _ in }
            )
            _ = await engine.run(task: task, batches: batches)

            let manifest = destination.appendingPathComponent(
                "MacCopy.\(ChecksumFileWriter.fileExtension(for: .sha256))"
            )
            TestRunner.assertFalse(
                FileManager.default.fileExists(atPath: manifest.path),
                "未开启时不应生成清单"
            )
        }
    }
}
