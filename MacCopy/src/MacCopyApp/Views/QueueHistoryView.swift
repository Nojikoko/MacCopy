import SwiftUI
import MacCopyKit

/// 任务队列页：显示当前任务与持久化队列中待恢复的任务。
struct QueueView: View {
    @EnvironmentObject private var vm: TransferViewModel
    @StateObject private var ui = QueueUIState()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(Localization.string("ui.queue.title", default: "任务队列"), systemImage: "list.bullet.rectangle")
                .font(.title2.weight(.semibold))

            currentCard

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    if ui.pending.isEmpty {
                        Text(Localization.string("ui.queue.empty", default: "没有待恢复的任务"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(ui.pending) { task in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(task.sourceRoots.map { ($0 as NSString).lastPathComponent }.joined(separator: "、"))
                                        .lineLimit(1)
                                    Text(Localization.format("ui.queue.detail", default: "目标：%@ · %d 项",
                                                             (task.destinationRoot as NSString).lastPathComponent,
                                                             task.sourceRoots.count))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(Localization.string("ui.queue.resume", default: "继续")) {
                                    vm.clearSources()
                                    vm.addSources(task.sourceRoots.map { URL(fileURLWithPath: $0) })
                                    vm.setDestination(URL(fileURLWithPath: task.destinationRoot))
                                    vm.selection = .quickStart
                                    vm.start()
                                }
                                .controlSize(.small)
                            }
                            Divider()
                        }
                    }
                    if let loadError = ui.loadError {
                        Text(loadError).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label(Localization.string("ui.queue.pending", default: "待恢复任务（重启后自动保留）"),
                      systemImage: "clock.arrow.circlepath")
            }

            Text(Localization.string("ui.queue.hint",
                default: "任务在创建时写入持久化队列。若应用意外退出，下次打开可从这里继续；未完成的文件通过 .maccopy.partial 断点续传。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: reload)
    }

    private var currentCard: some View {
        GroupBox {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(vm.state.displayName).font(.headline)
                    Text("\(vm.sources.count) " + Localization.string("ui.queue.items", default: "个源"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(Localization.string("ui.queue.go", default: "前往工作台")) {
                    vm.selection = .quickStart
                }
            }
            .padding(10)
        } label: {
            Label(Localization.string("ui.queue.current", default: "当前任务"), systemImage: "square.and.arrow.down.on.square")
        }
    }

    private func reload() {
        do {
            let store = try JSONTaskQueueStore()
            let ids = try store.pendingTaskIDs()
            ui.pending = try store.loadTasks().filter { ids.contains($0.id) && !$0.state.isTerminal }
            ui.loadError = nil
        } catch {
            ui.loadError = error.localizedDescription
        }
    }
}



/// 队列页暂态状态（ObservableObject 规避 SwiftUI 宏）。
@MainActor
final class QueueUIState: ObservableObject {
    @Published var pending: [TransferTask] = []
    @Published var loadError: String?
}
/// 历史记录页（从 SQLite 任务历史读取）。
struct HistoryView: View {
    @StateObject private var ui = HistoryUIState()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(Localization.string("ui.history.title", default: "历史记录"), systemImage: "clock")
                .font(.title2.weight(.semibold))

            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    if ui.records.isEmpty {
                        Text(Localization.string("ui.history.empty", default: "暂无历史记录"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(ui.records.prefix(50), id: \.id) { record in
                            HStack {
                                Image(systemName: record.failedCount == 0 ? "checkmark.circle" : "exclamationmark.circle")
                                    .foregroundStyle(record.failedCount == 0 ? .green : .orange)
                                Text(record.destinationRoot)
                                    .lineLimit(1)
                                Spacer()
                                Text(record.createdAt, style: .date)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Divider()
                        }
                    }
                    if let loadError = ui.loadError {
                        Text(loadError).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label(Localization.string("ui.history.recent", default: "最近的传输"), systemImage: "list.bullet")
            }
            Spacer()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: reload)
    }

    private func reload() {
        Task { @MainActor in
            do {
                let base = FileManager.default.urls(
                    for: .applicationSupportDirectory, in: .userDomainMask
                ).first ?? URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent("Library/Application Support")
                let directory = base.appendingPathComponent("MacCopy", isDirectory: true)
                try? FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true
                )
                let path = directory.appendingPathComponent("history.sqlite").path
                let db = try Database(path: path)
                try Migration.migrate(db)
                let repo = SQLiteTaskHistoryRepository(database: db)
                ui.records = try await repo.listTasks(limit: 50, offset: 0)
                ui.loadError = nil
            } catch {
                ui.loadError = error.localizedDescription
            }
        }
    }
}


/// 历史页暂态状态（ObservableObject 规避 SwiftUI 宏）。
@MainActor
final class HistoryUIState: ObservableObject {
    @Published var records: [TaskRecord] = []
    @Published var loadError: String?
}
