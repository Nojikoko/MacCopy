import SwiftUI
import MacCopyKit

/// 主窗口：NavigationSplitView 三栏（架构 PRD §5.1）。
struct RootView: View {
    @EnvironmentObject private var vm: TransferViewModel
    @StateObject private var ui = RootUIState()

    var body: some View {
        NavigationSplitView(columnVisibility: $ui.columnVisibility) {
            sidebar
        } content: {
            contentColumn
        } detail: {
            InspectorView()
        }
        .navigationTitle(Localization.string("app.title", default: "MacCopy"))
        .frame(minWidth: 1000, minHeight: 620)
        .alert(
            Localization.string("ui.alert.title", default: "提示"),
            isPresented: Binding(
                get: { vm.alertMessage != nil },
                set: { if !$0 { vm.alertMessage = nil } }
            )
        ) {
            Button(Localization.string("ui.ok", default: "好"), role: .cancel) {}
        } message: {
            Text(vm.alertMessage ?? "")
        }
    }

    // MARK: - 侧边栏

    private var sidebar: some View {
        List(selection: Binding(
            get: { vm.selection },
            set: { if let value = $0 { vm.selection = value } }
        )) {
            Section(Localization.string("ui.sidebar.section.work", default: "工作区")) {
                ForEach(SidebarItem.allCases) { item in
                    Label(item.title, systemImage: item.systemImage)
                        .tag(item)
                }
            }

            if !vm.recentDestinations.isEmpty {
                Section(Localization.string("ui.sidebar.section.recent", default: "最近目标")) {
                    ForEach(vm.recentDestinations.prefix(5), id: \.path) { url in
                        Button {
                            vm.setDestination(url)
                        } label: {
                            Label(url.lastPathComponent, systemImage: "folder")
                                .lineLimit(1)
                                .help(url.path)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 190)
    }

    // MARK: - 中间栏

    @ViewBuilder
    private var contentColumn: some View {
        switch vm.selection {
        case .quickStart:
            QuickStartView()
        case .queue:
            QueueView()
        case .history:
            HistoryView()
        case .settings:
            SettingsView()
        }
    }
}

/// 主窗口的暂态 UI 状态（用 ObservableObject 而非 @State，避免 SwiftUI 宏在本机 swiftc 直编下失败）。
@MainActor
final class RootUIState: ObservableObject {
    @Published var columnVisibility: NavigationSplitViewVisibility = .all
}
