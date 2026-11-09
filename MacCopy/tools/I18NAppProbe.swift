import Foundation
import MacCopyKit

/// 真实 .app 内的 i18n 验收探针（AD-I12 / V-B1~V-B4 / QA 5 场景）。
///
/// 关键：这个二进制必须放在 `<X>.app/Contents/MacOS/` 内运行，
/// 让 `Bundle.main` 真的带 8 个 `.lproj`，否则测不出
/// 「裸 String(localized:defaultValue:) 被系统语言资源劫持」的坑（假通过）。
///
/// 与 QA 的 A/B 探针不同：这里调用的是**产品代码** `Localization.string/format`
/// 和 `LanguageBundleFactory` / `LanguageState`，直接验证修复是否落盘。
///
/// 用法：
///   I18NAppProbe <scenario>
///     all      — 正常译文 / 空串 / 漏 key / 坏占位符 / 无 Bundle
///     noBundle — 物理删除整个 ko.lproj 后，ko tag 走 bundle == nil 分支
///
/// 退出码：0 = 全部通过；1 = 有断言失败；139 = SIGSEGV（防护失效，最严重）。
@main
enum I18NAppProbe {
    static func main() {
        // `-AppleLanguages "(en)"` 会占据参数列表，需显式找出场景名。
        let args = Array(CommandLine.arguments.dropFirst())
        let scenario = args.first(where: { $0 == "all" || $0 == "noBundle" }) ?? "all"
        var failures = 0

        func check(_ label: String, _ actual: String, _ expected: String) {
            if actual == expected {
                print("  ✅ \(label): 「\(actual)」")
            } else {
                print("  ❌ \(label): 期望「\(expected)」，实际「\(actual)」")
                failures += 1
            }
        }

        print("Bundle.main = \(Bundle.main.bundlePath)")
        print("preferredLocalizations = \(Bundle.main.preferredLocalizations)")
        print("resourceURL = \(Bundle.main.resourceURL?.path ?? "<nil>")")

        // 模拟 applyLanguage() 把 en 作为当前语言。
        let enBundle = LanguageBundleFactory.make(tag: "en")
        print("en Bundle 构造: \(enBundle == nil ? "nil" : "OK")")
        LanguageState.shared.set(bundle: enBundle, tag: "en")

        if scenario == "all" {
            // ① 正常译文：`qa.total` 的中文基准是「共 %d 项」，en 译文为 TOTAL %d ITEMS。
            check(
                "① 正常译文 format",
                Localization.format("qa.total", default: "共 %d 项", 5),
                "TOTAL 5 ITEMS"
            )

            // ② 空串译文 → 必须回退**中文基准**（不能是空串，也不能是英文）。
            check(
                "② 空串回退中文",
                Localization.string("qa.empty", default: "中文兜底文案"),
                "中文兜底文案"
            )

            // ③ 漏 key → 中文基准。
            check(
                "③ 漏 key 回退中文",
                Localization.string("qa.missing.key", default: "中文缺失兜底"),
                "中文缺失兜底"
            )

            // ④ 坏占位符：en.lproj 注入 `qa.bad = "TOTAL %@ ITEMS"`，
            //    中文基准是「共 %d 项」。签名不符必须触发防护、退回中文且**不崩溃**。
            //    若 baseline() 缺失，base 也被劫持成 %@ → 签名相等 → 防护不触发 → SIGSEGV。
            let bad = Localization.format("qa.bad", default: "共 %d 项", 5)
            check("④ 坏占位符退回中文且未崩溃", bad, "共 5 项")

            // ⑤ HIJACKED 注入：`"操作已取消。" = "HIJACKED"` 想劫持 defaultValue 本身。
            check(
                "⑤ defaultValue 不被劫持",
                Localization.string("qa.cancelled", default: "操作已取消。"),
                "CANCELLED"
            )

            // ⑥ 整个语言 Bundle 缺失（CLI / 单测环境）：必须恒中文。
            LanguageState.shared.set(bundle: nil, tag: "zh-Hans")
            check(
                "⑥ 无 Bundle 恒中文",
                Localization.string("qa.total", default: "共 %d 项"),
                "共 %d 项"
            )
            check(
                "⑥ 无 Bundle format 恒中文",
                Localization.format("qa.total", default: "共 %d 项", 7),
                "共 7 项"
            )
        } else if scenario == "noBundle" {
            // QA 场景 5：物理删除整个 ko.lproj 后以 -AppleLanguages "(ko)" 启动，
            // LanguageBundleFactory.make(tag:"ko") 返回 nil → bundle == nil 分支
            // 也必须返回中文基准（修复前会返回被劫持的英文串）。
            let koBundle = LanguageBundleFactory.make(tag: "ko")
            print("ko Bundle 构造: \(koBundle == nil ? "nil（符合预期：lproj 已删）" : "⚠️ 仍存在")")
            LanguageState.shared.set(bundle: koBundle, tag: "ko")
            check(
                "⑤ 删整个 ko.lproj 后恒中文",
                Localization.string("qa.total", default: "共 %d 项"),
                "共 %d 项"
            )
            check(
                "⑤ 删整个 ko.lproj 后 format 恒中文",
                Localization.format("qa.total", default: "共 %d 项", 3),
                "共 3 项"
            )
        }

        LanguageState.shared.set(bundle: nil, tag: "zh-Hans")

        if failures == 0 {
            print("APP PROBE PASS（scenario=\(scenario)）")
            exit(0)
        }
        print("APP PROBE FAIL（\(failures) 项）")
        exit(1)
    }
}
