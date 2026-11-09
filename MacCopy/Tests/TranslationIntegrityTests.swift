import Foundation
import MacCopyKit

/// 译文完整性 / `--check-languages` 破坏性验证（架构 T-I05 §5）。
///
/// 每个用例都先备份目标 JSON，做一处破坏，运行 `sync_catalog.py --check-languages`
/// 断言非零退出，最后**无条件恢复**备份，避免污染后续用例与工作区。
@MainActor
enum TranslationIntegrityTests {
    private static let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    private static let translations = root
        .appendingPathComponent("src/MacCopyApp/Localization/translations", isDirectory: true)

    /// 运行校验脚本并返回退出码。
    private static func runCheck() -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            root.appendingPathComponent("sync_catalog.py").path,
            "--check-languages",
        ]
        process.currentDirectoryURL = root
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// 确保 8 份译文健康；若被并发的破坏性测试/外部进程写坏，
    /// 从不可变源（冻结快照 + TSV 分片）重新生成，避免级联假失败。
    ///
    /// BUG-004 修复：此前硬编码 `dict.count == 192`，新增文案后条数变化会被
    /// 误判为「文件损坏」→ 触发重建 → **新文案被静默丢弃**（表现是
    /// 「加了 key，跑一次 test.sh 就没了」）。现改为：只要能解析出字典且
    /// **8 份之间条数一致**，就认为健康；重建与否交给 `--check-languages` 判定。
    private static func ensureHealthyTranslations() {
        var counts: [Int] = []
        var allParseable = true
        for lang in SupportedLanguage.allTags {
            let url = translations.appendingPathComponent("\(lang).json")
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data),
                  let dict = obj as? [String: String] else {
                allParseable = false
                break
            }
            counts.append(dict.count)
        }
        // 全部可解析 且 各语言条数一致 → 健康，不重建。
        if allParseable, let first = counts.first, counts.allSatisfy({ $0 == first }) {
            return
        }

        let generator = root.appendingPathComponent("tools/gen_translations.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [generator.path]
        process.currentDirectoryURL = root
        try? process.run()
        process.waitUntilExit()
        print("  ℹ️  检测到译文文件损坏，已从冻结快照 + TSV 重新生成 8 份 JSON")
    }

    /// 在破坏后的上下文中执行断言，结束后**原子恢复**原文件。
    private static func withBroken<T>(
        lang: String,
        mutate: (inout [String: String]) -> Void,
        body: () -> T
    ) -> T {
        let url = translations.appendingPathComponent("\(lang).json")
        let original = (try? Data(contentsOf: url)) ?? Data()
        var data = (try? JSONSerialization.jsonObject(with: original)) as? [String: String] ?? [:]
        mutate(&data)
        if let rewritten = try? JSONSerialization.data(
            withJSONObject: data, options: [.prettyPrinted, .sortedKeys]
        ) {
            try? rewritten.write(to: url)
        }
        defer {
            // `.atomic` 避免留下半写/0 字节文件（并发环境下曾出现 ja.json 被截断）。
            try? original.write(to: url, options: .atomic)
        }
        return body()
    }

    static func register() {
        ensureHealthyTranslations()

        TestRunner.register("译文校验：当前 8 份译文全部通过 --check-languages") {
            TestRunner.assertEqual(runCheck(), 0)
        }

        TestRunner.register("译文校验：删 1 条 → 非零退出阻断") {
            let code = withBroken(lang: "de", mutate: { $0.removeValue(forKey: "ui.start") }) {
                runCheck()
            }
            assertNotEqual(code, 0, "缺 key 必须阻断打包")
            TestRunner.assertEqual(runCheck(), 0, "恢复后应重新通过")
        }

        TestRunner.register("译文校验：改 %d → %@ → 非零退出阻断（SIGSEGV 防线）") {
            let code = withBroken(lang: "fr", mutate: { dict in
                dict["ui.settings.buffer"] = dict["ui.settings.buffer"]?
                    .replacingOccurrences(of: "%d", with: "%@")
            }) {
                runCheck()
            }
            assertNotEqual(code, 0, "占位符类型不一致必须阻断")
            TestRunner.assertEqual(runCheck(), 0, "恢复后应重新通过")
        }

        TestRunner.register("译文校验：置空串 → 非零退出阻断") {
            let code = withBroken(lang: "ko", mutate: { $0["ui.cancel"] = "" }) {
                runCheck()
            }
            assertNotEqual(code, 0)
            TestRunner.assertEqual(runCheck(), 0)
        }

        TestRunner.register("译文校验：zh-Hant 混入简体字 → 非零退出阻断") {
            let code = withBroken(lang: "zh-Hant", mutate: { dict in
                dict["ui.start"] = "開始复制"   // 「复」是简体专用字
            }) {
                runCheck()
            }
            assertNotEqual(code, 0, "P0-15：禁止简繁机械转换")
            TestRunner.assertEqual(runCheck(), 0)
        }

        TestRunner.register("译文校验：整份 ja.json 缺失 → 非零退出阻断") {
            let url = translations.appendingPathComponent("ja.json")
            let original = (try? Data(contentsOf: url)) ?? Data()
            try? FileManager.default.removeItem(at: url)
            let code = runCheck()
            // 立刻恢复（不能等 defer，否则后面的「恢复后应通过」仍看到缺失）。
            try? original.write(to: url, options: .atomic)
            assertNotEqual(code, 0)
            TestRunner.assertEqual(runCheck(), 0, "恢复后应重新通过")
        }

        TestRunner.register("译文校验：中文基准 180 条被改动 → 非零退出阻断") {
            let code = withBroken(lang: "zh-Hans", mutate: { dict in
                dict["ui.start"] = "开始拷贝"   // 与冻结快照不一致
            }) {
                runCheck()
            }
            assertNotEqual(code, 0, "P0-03：中文基准逐字不变")
            TestRunner.assertEqual(runCheck(), 0)
        }

        TestRunner.register("译文校验：Info.plist 与 translations 目录名逐字一致（8 项）") {
            let plist = root.appendingPathComponent("src/MacCopyApp/Info.plist")
            guard let data = try? Data(contentsOf: plist),
                  let dict = try? PropertyListSerialization.propertyList(
                      from: data, format: nil
                  ) as? [String: Any],
                  let list = dict["CFBundleLocalizations"] as? [String] else {
                TestRunner.fail("Info.plist 读取失败")
                return
            }
            TestRunner.assertEqual(list, SupportedLanguage.allTags)
            TestRunner.assertEqual(dict["CFBundleDevelopmentRegion"] as? String, "zh-Hans")
            let files = (try? FileManager.default.contentsOfDirectory(atPath: translations.path))?
                .filter { $0.hasSuffix(".json") }
                .map { String($0.dropLast(5)) }
                .sorted() ?? []
            TestRunner.assertEqual(files.sorted(), list.sorted())
        }
    }

    /// 断言两个值不相等（测试运行器未提供）。
    private static func assertNotEqual<T: Equatable>(
        _ actual: T, _ expected: T, _ message: String = ""
    ) {
        TestRunner.assertTrue(actual != expected, message)
    }
}
