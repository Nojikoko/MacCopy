import Foundation
import MacCopyKit

/// 「选择目标无法选中文件夹」BugFix 的静态回归。
///
/// 为什么用静态断言而非 UI 自动化：本机无 GUI 自动化宿主，`NSOpenPanel`
/// 的真实点击无法在测试进程里触发。这里锁定**代码路径的正确配置**，
/// 防止有人把 `.fileImporter(.folder)` 改回来或漏掉关键面板参数。
@MainActor
enum DestinationPickerTests {
    private static func source(_ relative: String) -> String {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(relative)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// 去掉注释行/文档注释行，只留真实代码（避免注释里提到 `.fileImporter` 导致误报）。
    private static func codeOnly(_ text: String) -> String {
        text.split(separator: "\n")
            .filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return !t.hasPrefix("//") && !t.hasPrefix("*") && !t.hasPrefix("///")
            }
            .joined(separator: "\n")
    }

    static func register() {
        TestRunner.register("目标选择：QuickStartView 不再用 .fileImporter 选目录") {
            let quick = source("src/MacCopyApp/Views/QuickStartView.swift")
            let code = codeOnly(quick)
            TestRunner.assertTrue(quick.contains("import AppKit"), "应引入 AppKit")
            TestRunner.assertFalse(
                code.contains(".fileImporter"),
                "选择目标/选择源都不得再用 SwiftUI .fileImporter（目录选择不可靠）"
            )
            TestRunner.assertFalse(
                code.contains("QuickStartUIState"),
                "旧的 @State 临时类已无用，不应残留死状态"
            )
            TestRunner.assertFalse(
                code.contains("isChoosingDestination"),
                "不应残留 isChoosingDestination 死状态"
            )
        }

        TestRunner.register("目标选择：NSOpenPanel 目标面板配置正确") {
            let quick = source("src/MacCopyApp/Views/QuickStartView.swift")
            guard let start = quick.range(of: "private func chooseDestination()") else {
                TestRunner.fail("找不到 chooseDestination()")
                return
            }
            let tail = String(quick[start.lowerBound...])
            let end = tail.range(of: "\n    @MainActor", options: .regularExpression)?.lowerBound
                ?? tail.endIndex
            let body = String(tail[..<end])

            TestRunner.assertTrue(body.contains("NSOpenPanel()"), "面板须即时创建")
            TestRunner.assertTrue(body.contains("canChooseDirectories = true"), "目录可选")
            TestRunner.assertTrue(body.contains("canChooseFiles = false"), "文件不可选")
            TestRunner.assertTrue(body.contains("allowsMultipleSelection = false"), "单选")
            TestRunner.assertTrue(body.contains("canCreateDirectories = true"), "允许新建目标文件夹")
            TestRunner.assertTrue(body.contains("panel.runModal()"), "主线程模态运行")
            TestRunner.assertTrue(body.contains("vm.setDestination(url)"), "成功后回填目标")
            TestRunner.assertTrue(
                body.contains("Localization.string(\"ui.chooseTarget\""),
                "prompt 复用已有本地化 key，不硬编码中文"
            )
            TestRunner.assertFalse(
                body.contains("startAccessingSecurityScopedResource"),
                "非沙盒 App 不需要 security-scoped，避免预埋复杂逻辑"
            )
        }

        TestRunner.register("目标选择：NSOpenPanel 选源面板配置正确（文件+目录、多选）") {
            let quick = source("src/MacCopyApp/Views/QuickStartView.swift")
            guard let start = quick.range(of: "private func chooseSources()") else {
                TestRunner.fail("找不到 chooseSources()")
                return
            }
            let tail = String(quick[start.lowerBound...])
            let end = tail.range(of: "\n    // MARK:", options: .regularExpression)?.lowerBound
                ?? tail.endIndex
            let body = String(tail[..<end])

            TestRunner.assertTrue(body.contains("NSOpenPanel()"))
            TestRunner.assertTrue(body.contains("canChooseFiles = true"), "文件可选")
            TestRunner.assertTrue(body.contains("canChooseDirectories = true"), "目录也可选")
            TestRunner.assertTrue(body.contains("allowsMultipleSelection = true"), "多选")
            TestRunner.assertTrue(body.contains("vm.addSources(panel.urls)"), "批量回填源")
        }

        TestRunner.register("目标选择：AD-02 MacCopyKit 不得引入 AppKit") {
            let kit = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("src/MacCopyKit", isDirectory: true)
            var violations: [String] = []
            let enumerator = FileManager.default.enumerator(atPath: kit.path)
            while let file = enumerator?.nextObject() as? String {
                guard file.hasSuffix(".swift") else { continue }
                let text = (try? String(
                    contentsOf: kit.appendingPathComponent(file), encoding: .utf8
                )) ?? ""
                for line in text.split(separator: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed == "import AppKit" || trimmed == "import SwiftUI" {
                        violations.append("\(file): \(trimmed)")
                    }
                }
            }
            TestRunner.assertTrue(
                violations.isEmpty,
                "MacCopyKit 必须 Foundation-only，实际：\(violations)"
            )
        }

        TestRunner.register("目标选择：拖放目标与最近目标路径未被破坏") {
            let quick = source("src/MacCopyApp/Views/QuickStartView.swift")
            TestRunner.assertTrue(
                quick.contains("vm.setDestination(collected[0])"),
                "拖放设置目标的路径应保留"
            )
            let root = source("src/MacCopyApp/Views/RootView.swift")
            TestRunner.assertTrue(
                root.contains("vm.setDestination(url)"),
                "最近目标列表的路径应保留"
            )
        }
    }
}
