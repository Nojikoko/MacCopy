import SwiftUI
import UniformTypeIdentifiers
import MacCopyKit

/// 快速开始页：源拖放区 + 目标选择 + 控制条 + 进度 + 文件列表。
struct QuickStartView: View {
    @EnvironmentObject private var vm: TransferViewModel
    @StateObject private var ui = QuickStartUIState()

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
        .fileImporter(
            isPresented: $ui.isChoosingSources,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { vm.addSources(urls) }
        }
        .fileImporter(
            isPresented: $ui.isChoosingDestination,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result { vm.setDestination(url) }
        }
    }

    // MARK: - 工具条

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                ui.isChoosingSources = true
            } label: {
                Label(Localization.string("ui.add", default: "添加文件"), systemImage: "plus")
            }
            .disabled(vm.isRunning)

            Button {
                ui.isChoosingDestination = true
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
                ui.isChoosingSources = true
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
                    ui.isChoosingDestination = true
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


/// 快速开始页的暂态 UI 状态（用 ObservableObject 而非 @State，规避 SwiftUI 宏）。
@MainActor
final class QuickStartUIState: ObservableObject {
    @Published var isChoosingSources = false
    @Published var isChoosingDestination = false
}
