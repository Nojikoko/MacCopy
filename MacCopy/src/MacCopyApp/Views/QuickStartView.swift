import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MacCopyKit

/// 快速开始页：源拖放区 + 目标选择 + 控制条 + 进度 + 文件列表。
///
/// 目录/文件选择一律用 **AppKit `NSOpenPanel`**（v1.2 BugFix）：
/// SwiftUI 的 `.fileImporter(allowedContentTypes: [.folder])` 在 macOS 上
/// 选目录不可靠（目录可见但选不中、或选中后不回调 success），会让
/// 「选择目标文件夹」这个核心功能完全不可用。NSOpenPanel 可显式配置
/// `canChooseDirectories` / `canChooseFiles`，行为确定。
///
/// AD-02：`AppKit` 只出现在 App target；`MacCopyKit` 保持 Foundation-only。
struct QuickStartView: View {
    @EnvironmentObject private var vm: TransferViewModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if vm.pendingTaskCount > 0 {
                        pendingBanner
                    }
                    sourceCard
                    destinationCard
                    ProgressPanel()
                    if !vm.rows.isEmpty {
                        FileListView()
                    }
                    if !vm.logLines.isEmpty {
                        LogView()
                    }
                }
                .padding(18)
            }
        }
        .frame(minWidth: 520)
    }

    // MARK: - 工具条

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                chooseSources()
            } label: {
                Label(Localization.string("ui.add", default: "添加文件"), systemImage: "plus")
            }
            .disabled(vm.isRunning)

            Button {
                chooseDestination()
            } label: {
                Label(Localization.string("ui.chooseTarget", default: "选择目标"), systemImage: "folder")
            }
            .disabled(vm.isRunning)

            Spacer()

            if vm.isRunning {
                Button {
                    vm.cancel()
                } label: {
                    Label(Localization.string("ui.cancel", default: "取消"), systemImage: "xmark.circle")
                }
                .tint(.red)
            } else {
                Button {
                    vm.start()
                } label: {
                    Label(Localization.string("ui.start", default: "开始复制"), systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!vm.canStart)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - AppKit 面板（主线程即时创建）

    /// 选择**目标文件夹**。
    ///
    /// - 面板在点按钮时即时创建，不复用长期实例
    /// - `runModal()` 在 `@MainActor` 上同步运行，成功后直接更新 `@Published`，
    ///   无需跨 actor 跳转（也就不存在「回调没回到主线程」的问题）
    /// - 本 App 为 ad-hoc 签名**非沙盒**（Info.plist 无 sandbox entitlement），
    ///   NSOpenPanel 返回的是普通 file URL，无需 `startAccessingSecurityScopedResource()`
    @MainActor
    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = Localization.string("ui.chooseTarget", default: "选择目标")
        panel.message = Localization.string("ui.section.target", default: "目标位置")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        vm.setDestination(url)
    }

    /// 选择**源文件/文件夹**（可多选，两者都要能选）。
    ///
    /// 同 `chooseDestination()`，把选源也统一到确定性 AppKit 路径：
    /// `.fileImporter(allowedContentTypes: [.item])` 与目标面板是同一 SwiftUI API
    /// 家族，目录选中不回调的失败模式无法在本机 GUI 自动化验证，
    /// 不留下第二个不可验证的风险点。
    @MainActor
    private func chooseSources() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = Localization.string("ui.add", default: "添加文件")
        panel.message = Localization.string("ui.section.source", default: "源文件")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        vm.addSources(panel.urls)
    }

    // MARK: - 源卡片

    private var sourceCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if vm.sources.isEmpty {
                    dropHint
                } else {
                    ForEach(vm.sources, id: \.path) { url in
                        HStack(spacing: 8) {
                            Image(systemName: url.hasDirectoryPath ? "folder.fill" : "doc.fill")
                                .foregroundStyle(.secondary)
                            Text(url.lastPathComponent)
                                .lineLimit(1)
                            Text(url.deletingLastPathComponent().path)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                vm.removeSource(url)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .disabled(vm.isRunning)
                        }
                    }
                    HStack {
                        Text(vm.sourceDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(Localization.string("ui.clear", default: "清空")) {
                            vm.clearSources()
                        }
                        .font(.caption)
                        .disabled(vm.isRunning)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        } label: {
            Label(Localization.string("ui.section.source", default: "源文件"), systemImage: "doc.on.doc")
        }
        .onDrop(of: [.fileURL], isTargeted: $vm.isDropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(vm.isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
        )
    }

    private var dropHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(Localization.string("ui.drop.hint", default: "把文件或文件夹拖到这里"))
                .foregroundStyle(.secondary)
            Button(Localization.string("ui.drop.choose", default: "或点此选择…")) {
                chooseSources()
            }
            .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }

    // MARK: - 目标卡片

    private var destinationCard: some View {
        GroupBox {
            HStack(spacing: 8) {
                Image(systemName: vm.destination == nil ? "folder.badge.questionmark" : "folder.fill")
                    .foregroundStyle(vm.destination == nil ? Color.secondary : Color.accentColor)
                Text(vm.destinationDescription)
                    .lineLimit(1)
                    .foregroundStyle(vm.destination == nil ? .secondary : .primary)
                Spacer()
                Button(Localization.string("ui.change", default: "更改")) {
                    chooseDestination()
                }
                .disabled(vm.isRunning)
            }
            .padding(10)
        } label: {
            Label(Localization.string("ui.section.target", default: "目标位置"), systemImage: "arrow.right.doc.on.clipboard")
        }
        .onDrop(of: [.fileURL], isTargeted: .constant(false)) { providers in
            // 拖到目标卡片时，若只有一个文件夹则设为目标。
            handleDrop(providers, asDestination: true)
        }
    }

    // MARK: - 待恢复任务横幅

    private var pendingBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.orange)
            Text(Localization.format(
                "ui.pending.banner",
                default: "发现 %d 个上次未完成的任务，可从断点继续",
                vm.pendingTaskCount
            ))
            .font(.callout)
            Spacer()
            Button(Localization.string("ui.pending.go", default: "查看")) {
                vm.selection = .queue
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - 拖放

    private func handleDrop(_ providers: [NSItemProvider], asDestination: Bool = false) -> Bool {
        // 用 async 串行加载，避免在 @Sendable 回调里并发修改共享数组（Swift 6 严格并发）。
        Task { @MainActor in
            var collected: [URL] = []
            for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                if let url = await Self.loadFileURL(from: provider) {
                    collected.append(url)
                }
            }
            guard !collected.isEmpty else { return }
            if asDestination, collected.count == 1, collected[0].hasDirectoryPath {
                vm.setDestination(collected[0])
            } else {
                vm.addSources(collected)
            }
        }
        return true
    }

    /// 从 NSItemProvider 异步取出文件 URL。
    private static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: item as? URL)
                }
            }
        }
    }
}
