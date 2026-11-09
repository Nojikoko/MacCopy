import SwiftUI
import MacCopyKit

/// MacCopy App 入口。
///
/// 架构 AD-01：状态管理层使用 `ObservableObject` + `@Published` + `@MainActor`。
/// `@Observable` 宏在 macOS 13 上不可用（需要 14+），全项目禁用。
///
/// v1.1（Q2b）：`body` 内**显式读一次** `languageRevision` 建立观察依赖，
/// 两个 Scene 根视图都加 `.id(...)` 重建，`.commands` 标题从 `@Published` 读。
/// 主路径 + `MenuBarLocalizer`（NSApp.mainMenu）兜底构成双保险，整体即时生效。
@main
struct MacCopyApp: App {
    @StateObject private var viewModel = TransferViewModel()

    var body: some Scene {
        // ✅ 必须显式读一次：否则 .commands 菜单标题不会随 languageRevision 重算。
        let _ = viewModel.languageRevision

        WindowGroup {
            RootView()
                .environmentObject(viewModel)
                .id(viewModel.languageRevision)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}

            // CommandMenu 的标题是 String（不是 LocalizedStringKey），
            // 从 @Published 读才能随依赖更新。
            CommandMenu(viewModel.menuTransferTitle) {
                Button(viewModel.menuStartTitle) {
                    viewModel.start()
                }
                .keyboardShortcut("r")
                .disabled(!viewModel.canStart)

                Button(viewModel.menuCancelTitle) {
                    viewModel.cancel()
                }
                .keyboardShortcut(".")
                .disabled(!viewModel.isRunning)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(viewModel)
                .id(viewModel.languageRevision)
                .frame(width: 520, height: 620)
        }
    }
}
