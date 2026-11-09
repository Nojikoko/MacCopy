import AppKit
import MacCopyKit

/// `.commands` 菜单标题兜底刷新（Q2b 裁决 / AD-I11）。
///
/// 定位难题：菜单项标题本身会随语言变化，不能按标题查找。
/// 方案用**快捷键作稳定标识** —— `⌘R` / `⌘.` 是编译期常量，永不本地化：
/// 按 `keyEquivalent` + `.command` 掩码找到子项，再从命中子项反查父菜单改标题。
///
/// **必须 `@MainActor`**：`NSApp` / `NSApplication.mainMenu` 是 MainActor 隔离，
/// 未标注时 Swift 6 严格并发会报 2 条警告（架构 V-M1 实测）。
///
/// AD-02：`AppKit` 只出现在 App target；`MacCopyKit` 保持 Foundation-only。
@MainActor
enum MenuBarLocalizer {
    /// 刷新主菜单的「传输」父项与两个子项标题。
    ///
    /// `applyLanguage()` **总是调用**此方法（幂等），不判断 SwiftUI 是否已刷新：
    /// 若已刷新，重复设置相同 title 无副作用；若未刷新，此处补上。
    /// 两条路径互为保险，不引入运行时不确定性（AD-I11）。
    static func refresh() {
        guard let main = NSApp?.mainMenu else { return }

        let keyed: [String: String] = [
            "r": Localization.string("ui.menu.start", default: "开始复制"),
            ".": Localization.string("ui.menu.cancel", default: "取消传输"),
        ]
        let parentTitle = Localization.string("ui.menu.transfer", default: "传输")

        for item in main.items {
            guard let submenu = item.submenu else { continue }
            var hit = false
            for child in submenu.items {
                guard child.keyEquivalentModifierMask.contains(.command),
                      let title = keyed[child.keyEquivalent] else { continue }
                child.title = title
                hit = true
            }
            if hit { item.title = parentTitle }
        }
    }
}
