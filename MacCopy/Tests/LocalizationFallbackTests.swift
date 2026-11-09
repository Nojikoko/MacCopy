import Foundation
import MacCopyKit

/// 运行期本地化防护（架构 V-A5 / V-A6，PRD-I18N P0-06 / P0-10 ③）。
///
/// 关键：占位符类型不匹配会让 `String(format:)` 直接 SIGSEGV，
/// 因此这些用例本身也是对「防护已生效」的验证 —— 若防护失效，测试进程会崩溃。
@MainActor
enum LocalizationFallbackTests {
    /// 构造一个含 `Localizable.strings` 的临时 Bundle 根。
    private static func makeBundle(
        named tag: String,
        lines: [String],
        scratch: URL
    ) -> Bundle? {
        let root = scratch.appendingPathComponent("bundle-\(UUID().uuidString)", isDirectory: true)
        let lproj = root.appendingPathComponent("\(tag).lproj", isDirectory: true)
        try? FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
        let strings = lproj.appendingPathComponent("Localizable.strings")
        try? (lines.joined(separator: "\n") + "\n").write(to: strings, atomically: false, encoding: .utf8)
        return Bundle(path: root.path)
    }

    private static func resetLanguageState() {
        LanguageState.shared.set(bundle: nil, tag: SupportedLanguage.zhHans.rawValue)
    }

    static func register() {
        TestRunner.register("本地化：无语言 Bundle 时返回中文基准") {
            resetLanguageState()
            let value = Localization.string("ui.start", default: "开始复制")
            TestRunner.assertEqual(value, "开始复制")
        }

        TestRunner.register("本地化：漏 key → 回退中文 defaultValue") {
            let scratch = IOTests.scratchDirectory("loc-missing")
            defer {
                resetLanguageState()
                try? FileManager.default.removeItem(at: scratch)
            }
            let bundle = makeBundle(
                named: "en",
                lines: ["\"ui.other\" = \"Other\";"],
                scratch: scratch
            )
            TestRunner.assertNotNil(bundle)
            LanguageState.shared.set(bundle: bundle, tag: "en")
            let value = Localization.string("ui.start", default: "开始复制")
            TestRunner.assertEqual(value, "开始复制")
        }

        TestRunner.register("本地化：空串译文 → 回退中文（V-A5，原生 API 不会回退）") {
            let scratch = IOTests.scratchDirectory("loc-empty")
            defer {
                resetLanguageState()
                try? FileManager.default.removeItem(at: scratch)
            }
            let bundle = makeBundle(
                named: "en",
                lines: ["\"ui.start\" = \"\";"],
                scratch: scratch
            )
            TestRunner.assertNotNil(bundle)
            LanguageState.shared.set(bundle: bundle, tag: "en")
            let value = Localization.string("ui.start", default: "开始复制")
            TestRunner.assertEqual(value, "开始复制", "空串必须回退中文基准")
        }

        TestRunner.register("本地化：全空白译文 → 回退中文") {
            let scratch = IOTests.scratchDirectory("loc-blank")
            defer {
                resetLanguageState()
                try? FileManager.default.removeItem(at: scratch)
            }
            let bundle = makeBundle(
                named: "en",
                lines: ["\"ui.start\" = \"   \";"],
                scratch: scratch
            )
            LanguageState.shared.set(bundle: bundle, tag: "en")
            let value = Localization.string("ui.start", default: "开始复制")
            TestRunner.assertEqual(value, "开始复制")
        }

        TestRunner.register("本地化：正常英文译文生效") {
            let scratch = IOTests.scratchDirectory("loc-normal")
            defer {
                resetLanguageState()
                try? FileManager.default.removeItem(at: scratch)
            }
            let bundle = makeBundle(
                named: "en",
                lines: ["\"ui.start\" = \"Start Copy\";"],
                scratch: scratch
            )
            TestRunner.assertNotNil(bundle)
            LanguageState.shared.set(bundle: bundle, tag: "en")
            let value = Localization.string("ui.start", default: "开始复制")
            TestRunner.assertEqual(value, "Start Copy")
        }

        TestRunner.register("本地化：format 占位符签名一致 → 使用译文（不崩溃）") {
            let scratch = IOTests.scratchDirectory("loc-fmt-ok")
            defer {
                resetLanguageState()
                try? FileManager.default.removeItem(at: scratch)
            }
            let bundle = makeBundle(
                named: "en",
                lines: ["\"ui.settings.buffer\" = \"Buffer: %d MiB\";"],
                scratch: scratch
            )
            LanguageState.shared.set(bundle: bundle, tag: "en")
            let value = Localization.format(
                "ui.settings.buffer", default: "缓冲区：%d MiB", 8
            )
            TestRunner.assertEqual(value, "Buffer: 8 MiB")
        }

        TestRunner.register("本地化：format 占位符类型错(%d→%@) → 退回中文基准且不崩溃（V-A6 致命项）") {
            let scratch = IOTests.scratchDirectory("loc-fmt-bad")
            defer {
                resetLanguageState()
                try? FileManager.default.removeItem(at: scratch)
            }
            // 故意把 %d 写成 %@：若无防护，String(format:) 会 SIGSEGV。
            let bundle = makeBundle(
                named: "en",
                lines: ["\"ui.settings.buffer\" = \"Buffer: %@ MiB\";"],
                scratch: scratch
            )
            LanguageState.shared.set(bundle: bundle, tag: "en")
            let value = Localization.format(
                "ui.settings.buffer", default: "缓冲区：%d MiB", 8
            )
            TestRunner.assertEqual(value, "缓冲区：8 MiB", "必须退回中文基准")
        }

        TestRunner.register("本地化：format 占位符数量不足 → 退回中文基准且不崩溃") {
            let scratch = IOTests.scratchDirectory("loc-fmt-count")
            defer {
                resetLanguageState()
                try? FileManager.default.removeItem(at: scratch)
            }
            let bundle = makeBundle(
                named: "en",
                lines: ["\"ui.settings.buffer\" = \"%d %d\";"],
                scratch: scratch
            )
            LanguageState.shared.set(bundle: bundle, tag: "en")
            let value = Localization.format(
                "ui.settings.buffer", default: "缓冲区：%d MiB", 8
            )
            TestRunner.assertEqual(value, "缓冲区：8 MiB")
        }

        TestRunner.register("本地化：format 参数个数少于基准 → 不崩溃，返回原始格式串") {
            resetLanguageState()
            // 故意不传参数：防护应拦下，不能读取越界 CVarArg。
            let value = Localization.format(
                "ui.settings.buffer", default: "缓冲区：%d MiB"
            )
            TestRunner.assertEqual(value, "缓冲区：%d MiB")
        }

        TestRunner.register("本地化：整个 lproj 缺失 → BundleFactory 返回 nil 且不崩溃") {
            let missing = LanguageBundleFactory.make(tag: "xx-NONE")
            TestRunner.assertTrue(missing == nil, "非法 tag 应返回 nil")
            // 合法但目录缺失时同样安全返回 nil（CLI / 单测环境）。
            resetLanguageState()
            let value = Localization.string("ui.start", default: "开始复制")
            TestRunner.assertEqual(value, "开始复制")
        }

        TestRunner.register("本地化：LanguageState 跨 Task.detached 读到最新 tag") {
            resetLanguageState()
            LanguageState.shared.set(bundle: nil, tag: "de")
            let observed = await Task.detached {
                LanguageState.shared.tag
            }.value
            TestRunner.assertEqual(observed, "de")
            resetLanguageState()
        }

        TestRunner.register("本地化：FormatSignature 类型签名比对正确") {
            TestRunner.assertEqual(
                FormatSignatureForTest.types(of: "共 %d 项 · %@ 剩余"),
                ["d", "@"]
            )
            TestRunner.assertEqual(
                FormatSignatureForTest.types(of: "%1$@ / %2$d"),
                ["@", "d"]
            )
            TestRunner.assertEqual(
                FormatSignatureForTest.types(of: "100%% 完成"),
                ["%"]
            )
        }
    }
}

/// 测试侧的占位符签名提取（与生产 `FormatSignature` 同一正则，便于独立断言）。
enum FormatSignatureForTest {
    private static let regex = try! NSRegularExpression(
        pattern: "%(?:\\d+\\$)?[-+ #0]*\\d*(?:\\.\\d+)?(?:hh|h|ll|l|q|L|z|t|j)?[@%dDuUxXoOfFeEgGcCsSaAp]"
    )

    static func types(of s: String) -> [String] {
        let range = NSRange(s.startIndex..., in: s)
        return regex.matches(in: s, range: range).compactMap { match in
            Range(match.range, in: s).map { String(s[$0].last!) }
        }
    }
}
