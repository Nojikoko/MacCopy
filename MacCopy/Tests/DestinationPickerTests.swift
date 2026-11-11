import Foundation
import MacCopyKit

/// 「选择目标无法选中文件夹」BugFix 的静态回归。
///
/// 为什么用静态断言而非 UI 自动化：本机无 GUI 自动化宿主，`NSOpenPanel`
/// 的真实点击无法在测试进程里触发。这里锁定**代码路径的正确配置**，
/// 防止有人把 `.fileImporter(.folder)` 改回来或漏掉关键面板参数。
///
/// QA 对 f39d0da 做过负向验证，指出三处可绕过（注释假阳性、函数体切片
/// 退化到 EOF、AD-02 平凡通过），本版逐条修掉：
/// 1. 所有断言都过 `codeOnly()`（带字符串字面量保护的状态机，剥行注释/
///    块注释/文档注释/行尾注释），不再被注释里的同名字样满足
/// 2. 函数体改**大括号配平**提取，不再依赖 `@MainActor` / `// MARK:`
///    这类可被删除的哨兵；边界找不到直接判失败，不退化到 EOF
/// 3. AD-02 先断言目录存在 + 扫描到的 `.swift` 文件数 > 0，再判违规为空
@MainActor
enum DestinationPickerTests {
    // MARK: - 源码读取

    /// 优先从 cwd 读（QA 的临时源码副本 harness 依赖这个），
    /// cwd 找不到时回退到由 `#filePath` 推导的工程根，
    /// 支持从仓库根直接 `bash MacCopy/test.sh`。
    private static func source(_ relative: String) -> String {
        let fromCWD = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(relative)
        if FileManager.default.fileExists(atPath: fromCWD.path) {
            return (try? String(contentsOf: fromCWD, encoding: .utf8)) ?? ""
        }
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // MacCopy/
        let fromSource = projectRoot.appendingPathComponent(relative)
        return (try? String(contentsOf: fromSource, encoding: .utf8)) ?? ""
    }

    /// 剥离注释，只留真实代码。
    ///
    /// 用字符级状态机而非「整行 hasPrefix("//")」：
    /// - 支持 `//` 行注释、`///` 文档注释、`/* */` 块注释、**行尾注释**
    /// - 保护字符串字面量，里面的 `//`（如 URL）不会被误伤
    /// - 保留换行，避免不同行的代码粘连产生假匹配
    /// 这样「把真实配置行改成注释」不再能让断言平凡通过，
    /// 「`var body… { // .fileImporter`」这类行尾注释也不会造成误报。
    private static func codeOnly(_ text: String) -> String {
        var result = ""
        let chars = Array(text)
        var i = 0
        var inString = false
        var inLineComment = false
        var inBlockComment = false
        var escaped = false

        while i < chars.count {
            let c = chars[i]
            let n: Character? = (i + 1 < chars.count) ? chars[i + 1] : nil

            if inLineComment {
                if c == "\n" {
                    inLineComment = false
                    result.append(c)
                }
                i += 1
                continue
            }
            if inBlockComment {
                if c == "*" && n == "/" {
                    inBlockComment = false
                    i += 2
                } else {
                    if c == "\n" { result.append(c) }
                    i += 1
                }
                continue
            }
            if inString {
                result.append(c)
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
                i += 1
                continue
            }
            if c == "\"" {
                inString = true
                result.append(c)
                i += 1
                continue
            }
            if c == "/" && n == "/" {
                inLineComment = true
                i += 2
                continue
            }
            if c == "/" && n == "*" {
                inBlockComment = true
                i += 2
                continue
            }
            result.append(c)
            i += 1
        }
        return result
    }

    /// 按大括号配平提取函数体（输入须先过 `codeOnly`）。
    ///
    /// 不依赖 `@MainActor` / `// MARK:` 等可被删除的哨兵：QA 的 B2 破坏
    /// 「删掉 chooseSources 前的 @MainActor + 把目标面板目录配置改 false」
    /// 曾因切片退化到 EOF、被下一个函数里的同名字样满足而漏检。
    /// 边界找不到或括号不配平 → 返回 nil，调用方直接判失败。
    private static func functionBody(_ name: String, in code: String) -> String? {
        guard let signature = code.range(of: "func \(name)(") else { return nil }
        guard let open = code.range(
            of: "{", range: signature.upperBound..<code.endIndex
        ) else { return nil }

        var depth = 1
        var idx = open.upperBound
        var inString = false
        var escaped = false
        while idx < code.endIndex {
            let c = code[idx]
            let next = code.index(after: idx)
            if inString {
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
            } else if c == "\"" {
                inString = true
            } else if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 { return String(code[open.upperBound..<idx]) }
            }
            idx = next
        }
        return nil
    }

    // MARK: - 用例

    static func register() {
        TestRunner.register("目标选择：codeOnly 注释剥离器自身有效（防止平凡通过）") {
            let sample = """
            // .fileImporter 整行注释
            let x = 1 // 行尾注释 .fileImporter
            let url = "https://example.com/path"  // 字符串里的 // 应保留
            /* 块注释 .fileImporter */
            /// 文档注释 .fileImporter
            """
            let stripped = codeOnly(sample)
            TestRunner.assertFalse(
                stripped.contains(".fileImporter"),
                "注释里的 .fileImporter 必须被剥离，否则是平凡通过"
            )
            TestRunner.assertTrue(
                stripped.contains("https://example.com/path"),
                "字符串字面量里的 // 不得被误伤"
            )
            TestRunner.assertTrue(stripped.contains("let x = 1"), "真实代码必须保留")
        }

        TestRunner.register("目标选择：QuickStartView 不再用 .fileImporter 选目录") {
            let code = codeOnly(source("src/MacCopyApp/Views/QuickStartView.swift"))
            TestRunner.assertFalse(code.isEmpty, "必须读到 QuickStartView.swift 源码")
            TestRunner.assertTrue(code.contains("import AppKit"), "应引入 AppKit")
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
            let code = codeOnly(source("src/MacCopyApp/Views/QuickStartView.swift"))
            guard let body = functionBody("chooseDestination", in: code) else {
                TestRunner.fail("无法按大括号配平定位 chooseDestination() 函数体")
                return
            }
            // 必须是函数体内 `let panel = NSOpenPanel()`（即时创建），
            // 而非复用长期持有的属性；宽松的 `contains("NSOpenPanel()")` 会
            // 被注释/字符串里的同名字样满足。
            TestRunner.assertTrue(
                body.contains("let panel = NSOpenPanel()"),
                "面板须在函数体内即时创建"
            )
            TestRunner.assertFalse(
                body.contains("private let panel") || body.contains("private var panel"),
                "不得长期复用一个面板实例"
            )
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
            let code = codeOnly(source("src/MacCopyApp/Views/QuickStartView.swift"))
            guard let body = functionBody("chooseSources", in: code) else {
                TestRunner.fail("无法按大括号配平定位 chooseSources() 函数体")
                return
            }
            TestRunner.assertTrue(
                body.contains("let panel = NSOpenPanel()"),
                "选源面板须在函数体内即时创建"
            )
            TestRunner.assertTrue(body.contains("canChooseFiles = true"), "文件可选")
            TestRunner.assertTrue(body.contains("canChooseDirectories = true"), "目录也可选")
            TestRunner.assertTrue(body.contains("allowsMultipleSelection = true"), "多选")
            TestRunner.assertTrue(body.contains("vm.addSources(panel.urls)"), "批量回填源")
        }

        TestRunner.register("目标选择：AD-02 MacCopyKit 不得引入 AppKit") {
            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            var kit = cwd.appendingPathComponent("src/MacCopyKit", isDirectory: true)
            if !FileManager.default.fileExists(atPath: kit.path) {
                let projectRoot = URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                kit = projectRoot.appendingPathComponent("src/MacCopyKit", isDirectory: true)
            }
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: kit.path, isDirectory: &isDirectory
            )
            TestRunner.assertTrue(
                exists && isDirectory.boolValue,
                "src/MacCopyKit 目录必须存在，否则是平凡通过：\(kit.path)"
            )
            guard let enumerator = FileManager.default.enumerator(atPath: kit.path) else {
                TestRunner.fail("无法枚举 src/MacCopyKit，不得视为通过")
                return
            }
            var swiftFileCount = 0
            var violations: [String] = []
            while let file = enumerator.nextObject() as? String {
                guard file.hasSuffix(".swift") else { continue }
                swiftFileCount += 1
                let text = (try? String(
                    contentsOf: kit.appendingPathComponent(file), encoding: .utf8
                )) ?? ""
                for line in codeOnly(text).split(separator: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed == "import AppKit" || trimmed == "import SwiftUI" {
                        violations.append("\(file): \(trimmed)")
                    }
                }
            }
            TestRunner.assertTrue(
                swiftFileCount > 0,
                "必须真的扫描到 .swift 文件（实际 \(swiftFileCount)），否则是平凡通过"
            )
            TestRunner.assertTrue(
                violations.isEmpty,
                "MacCopyKit 必须 Foundation-only，实际：\(violations)"
            )
        }

        TestRunner.register("目标选择：拖放目标与最近目标路径未被破坏") {
            let quick = codeOnly(source("src/MacCopyApp/Views/QuickStartView.swift"))
            let root = codeOnly(source("src/MacCopyApp/Views/RootView.swift"))
            TestRunner.assertFalse(quick.isEmpty, "必须读到 QuickStartView.swift")
            TestRunner.assertFalse(root.isEmpty, "必须读到 RootView.swift")
            TestRunner.assertTrue(
                quick.contains("vm.setDestination(collected[0])"),
                "拖放设置目标的路径应保留"
            )
            TestRunner.assertTrue(
                root.contains("vm.setDestination(url)"),
                "最近目标列表的路径应保留"
            )
        }
    }
}
