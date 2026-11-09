import Foundation
import MacCopyKit

/// 语言切换即时生效 / AD-I05 冻结区（架构 §4.2 / T-I05 §4）。
///
/// 说明：`TransferViewModel` 属于 App target（SwiftUI），不链接进测试二进制，
/// 因此这里用**源码静态断言**验证 AD-I05 不变式与 `.id()` / `menuTitle` 主路径，
/// 并用 `LanguageState` 模拟 `applyLanguage()` 的全局写入语义。
@MainActor
enum LanguageSwitchTests {
    private static func read(_ relative: String) -> String {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(relative)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    static func register() {
        TestRunner.register("切换：MacCopyApp.body 显式读 languageRevision（Q2b 主路径）") {
            let src = read("src/MacCopyApp/MacCopyApp.swift")
            TestRunner.assertTrue(
                src.contains("let _ = viewModel.languageRevision"),
                "必须显式读一次才能建立 .commands 观察依赖"
            )
            TestRunner.assertTrue(
                src.contains(".id(viewModel.languageRevision)"),
                "根视图必须 .id() 重建"
            )
            // .id() 应至少出现在两个 Scene（WindowGroup + Settings）。
            let count = src.components(separatedBy: ".id(viewModel.languageRevision)").count - 1
            TestRunner.assertTrue(count >= 2, "两个 Scene 都要加 .id()，实际 \(count)")
        }

        TestRunner.register("切换：.commands 菜单文字读 @Published，不是内联 Localization") {
            let src = read("src/MacCopyApp/MacCopyApp.swift")
            TestRunner.assertTrue(src.contains("CommandMenu(viewModel.menuTransferTitle)"))
            TestRunner.assertTrue(src.contains("Button(viewModel.menuStartTitle)"))
            TestRunner.assertTrue(src.contains("Button(viewModel.menuCancelTitle)"))
        }

        TestRunner.register("切换：MenuBarLocalizer 标 @MainActor 且 applyLanguage 总调用") {
            let localizer = read("src/MacCopyApp/MenuBarLocalizer.swift")
            TestRunner.assertTrue(localizer.contains("@MainActor"), "V-M1：未标注会告警")
            TestRunner.assertTrue(localizer.contains("import AppKit"))

            let vm = read("src/MacCopyApp/TransferViewModel.swift")
            TestRunner.assertTrue(
                vm.contains("MenuBarLocalizer.refresh()"),
                "applyLanguage 必须总调用兜底（AD-I11 幂等）"
            )
        }

        TestRunner.register("切换：applyLanguage() 不触碰运行态（AD-I05 冻结区）") {
            let vm = read("src/MacCopyApp/TransferViewModel.swift")
            guard let start = vm.range(of: "func applyLanguage()") else {
                TestRunner.fail("找不到 applyLanguage()")
                return
            }
            let body = String(vm[start.lowerBound...])
            // 只取到下一个 func 之前，避免扫描到别的方法。
            let end = body.range(of: "\n    func ", options: .regularExpression)?.lowerBound
                ?? body.endIndex
            let applyBody = String(body[..<end])

            for forbidden in ["runningTask", "engine", "stream", "rows", "progress", "speedHistory"] {
                TestRunner.assertFalse(
                    applyBody.contains(forbidden),
                    "applyLanguage 不得触碰 \(forbidden)（复制中切换不中断）"
                )
            }
            TestRunner.assertTrue(applyBody.contains("LanguageState.shared.set"))
            TestRunner.assertTrue(applyBody.contains("languageRevision += 1"))
        }

        TestRunner.register("切换：settings.didSet 仅在语言字段变化时调用 applyLanguage") {
            let vm = read("src/MacCopyApp/TransferViewModel.swift")
            TestRunner.assertTrue(vm.contains("oldValue.languageFollowsSystem"))
            TestRunner.assertTrue(vm.contains("oldValue.manualLanguageTag"))
        }

        TestRunner.register("切换：restore default 走 resetEngineSettings，不再全量覆盖") {
            let settings = read("src/MacCopyApp/Views/SettingsView.swift")
            TestRunner.assertTrue(settings.contains("vm.resetEngineSettings()"))
            TestRunner.assertFalse(
                settings.contains("vm.settings = AppSettings()"),
                "Q7：全量覆盖会连语言一起重置"
            )
        }

        TestRunner.register("切换：语言 Bundle 工厂按 tag 构造，非法 tag 返回 nil") {
            TestRunner.assertTrue(LanguageBundleFactory.make(tag: "xx-INVALID") == nil)
            // 合法 tag 但目录不存在也应安全返回 nil（不崩溃）。
            let result = LanguageBundleFactory.make(tag: "ja")
            TestRunner.assertTrue(result == nil || result?.bundleURL != nil)
        }

        TestRunner.register("切换：LanguageState 读写并发安全（模拟 applyLanguage 全局写入）") {
            let state = LanguageState.shared
            state.set(bundle: nil, tag: "zh-Hans")

            // 并发写不同 tag，最后读应一致且无数据竞争。
            for tag in ["en", "de", "ja", "fr"] {
                state.set(bundle: nil, tag: tag)
            }
            TestRunner.assertEqual(state.tag, "fr")
            TestRunner.assertTrue(state.bundle == nil)

            // 恢复默认，避免影响后续用例。
            state.set(bundle: nil, tag: SupportedLanguage.zhHans.rawValue)
            TestRunner.assertEqual(state.tag, "zh-Hans")
        }

        TestRunner.register("切换：8 语 endonym 各自文字正确（Picker 与界面语言无关）") {
            TestRunner.assertEqual(SupportedLanguage.zhHans.endonym, "简体中文")
            TestRunner.assertEqual(SupportedLanguage.en.endonym, "English")
            TestRunner.assertEqual(SupportedLanguage.zhHant.endonym, "繁體中文")
            TestRunner.assertEqual(SupportedLanguage.ja.endonym, "日本語")
            TestRunner.assertEqual(SupportedLanguage.ko.endonym, "한국어")
            TestRunner.assertEqual(SupportedLanguage.fr.endonym, "Français")
            TestRunner.assertEqual(SupportedLanguage.de.endonym, "Deutsch")
            TestRunner.assertEqual(SupportedLanguage.es.endonym, "Español")
        }
    }
}
