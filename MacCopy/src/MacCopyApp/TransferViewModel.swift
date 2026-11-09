import Foundation
import SwiftUI
import MacCopyKit

/// 主窗口视图模型（AD-01：ObservableObject + @Published + @MainActor，禁用 @Observable）。
///
/// 事件流严格单向（架构 §8.6）：
/// CopyEngine(actor) → AsyncStream<TransferEvent> → 本类(@MainActor) → @Published → SwiftUI
@MainActor
final class TransferViewModel: ObservableObject {

    // MARK: - 源与目标

    /// 待复制的源路径。
    @Published var sources: [URL] = []
    /// 目标目录。
    @Published var destination: URL?
    /// 最近使用的目标目录（最多 10 个）。
    @Published var recentDestinations: [URL] = []

    // MARK: - 运行状态

    /// 当前任务状态。
    @Published var state: TaskState = .pending
    /// 实时进度。
    @Published var progress = TransferProgress()
    /// 任务汇总（完成后非空）。
    @Published var summary: TransferSummary?
    /// 文件行（按加入顺序）。
    @Published var rows: [FileRow] = []
    /// 速度采样（最近 120 个点，1 Hz）。
    @Published var speedHistory: [Double] = []
    /// 运行日志（中文）。
    @Published var logLines: [LogLine] = []
    /// 错误提示（Alert）。
    @Published var alertMessage: String?
    /// 校验降级警示（Q5：必须显著可见）。
    @Published var degradedReasons: [String] = []
    /// 是否正在拖拽悬停。
    @Published var isDropTargeted = false
    /// 侧边栏选中项。
    @Published var selection: SidebarItem = .quickStart
    /// 选中的文件行 ID（Inspector 用）。
    @Published var selectedRowID: UUID?
    /// 重启后待恢复的任务数（PRD P0-09：队列状态重启恢复）。
    @Published var pendingTaskCount = 0

    // MARK: - 设置

    /// 用户设置。
    ///
    /// v1.1：仅当**语言字段**变化时才重建视图树，避免改线程数也触发刷新。
    @Published var settings: AppSettings {
        didSet {
            settingsStore.save(settings)
            if oldValue.languageFollowsSystem != settings.languageFollowsSystem
                || oldValue.manualLanguageTag != settings.manualLanguageTag {
                applyLanguage()
            }
        }
    }

    // MARK: - v1.1 语言状态（AD-I05：只改文案状态）

    /// 语言版本号：每次切换 +1，用于 `.id()` 重建视图树。
    @Published private(set) var languageRevision: Int = 0
    /// 当前生效语言 tag。
    @Published private(set) var activeLanguageTag: String = SupportedLanguage.zhHans.rawValue
    /// 是否因系统语言未覆盖而回退到英语（P1-02 非阻塞提示）。
    @Published private(set) var isSystemFallback: Bool = false
    /// 「传输」菜单标题（`.commands` 的 CommandMenu 需要 String，不是 LocalizedStringKey）。
    @Published private(set) var menuTransferTitle: String = ""
    /// 「开始复制」菜单标题。
    @Published private(set) var menuStartTitle: String = ""
    /// 「取消传输」菜单标题。
    @Published private(set) var menuCancelTitle: String = ""

    /// 设置持久化。
    private let settingsStore: SettingsStore
    /// 队列持久化（构造可能失败，失败时降级为不持久化）。
    private let queueStore: (any TaskQueueStore)?
    /// 当前运行中的 Swift Task（用于取消）。
    private var runningTask: Task<Void, Never>?
    /// 当前引擎（用于恢复）。
    private var engine: CopyEngine?
    /// 当前任务定义。
    private var currentTask: TransferTask?
    /// 日志序号。
    private var logSequence = 0

    /// 构造视图模型。
    init() {
        let store = SettingsStore()
        self.settingsStore = store
        self.settings = store.load()
        self.queueStore = try? JSONTaskQueueStore()
        self.recentDestinations = Self.loadRecentDestinations()
        refreshPendingTasks()
        applyLanguage()
    }

    // MARK: - 语言生效（v1.1 / Q2b 即时生效）

    /// 语言生效的**唯一入口**。
    ///
    /// AD-I05：只写 `LanguageState` 与 6 个 `@Published` 文案字段，
    /// **绝不触碰** `runningTask` / `engine` / `stream` / `rows` / `progress` / `speedHistory`。
    /// 这是「复制任务进行中切换语言不中断」的实现保证（架构 §4.2）。
    func applyLanguage() {
        let resolution = LanguageResolver().resolve(
            systemLocalizations: Bundle.main.preferredLocalizations,
            manualTag: settings.manualLanguageTag,
            followsSystem: settings.languageFollowsSystem
        )
        let tag = resolution.language.rawValue

        // ① MacCopyKit 全局：后台 worker 立刻可见（Foundation-only，AD-02）。
        LanguageState.shared.set(bundle: LanguageBundleFactory.make(tag: tag), tag: tag)

        // ② SwiftUI 状态（菜单文字也在此重算）。
        activeLanguageTag = tag
        isSystemFallback = resolution.isSystemFallback
        menuTransferTitle = Localization.string("ui.menu.transfer", default: "传输")
        menuStartTitle = Localization.string("ui.menu.start", default: "开始复制")
        menuCancelTitle = Localization.string("ui.menu.cancel", default: "取消传输")
        languageRevision += 1

        // ③ Q2b 兜底：`NSApp.mainMenu` 手动刷新（@MainActor，总调用、幂等，AD-I11）。
        MenuBarLocalizer.refresh()
    }

    /// 恢复默认设置，但**保留语言偏好**（Q7 / P0-09）。
    ///
    /// 语言是身份偏好，不随「恢复默认设置」重置。
    func resetEngineSettings() {
        var fresh = AppSettings()
        fresh.languageFollowsSystem = settings.languageFollowsSystem
        fresh.manualLanguageTag = settings.manualLanguageTag
        fresh.didMigrateFromV10 = settings.didMigrateFromV10
        settings = fresh                     // didSet → save（一次）
        applyLanguage()                      // 语言未变，确保 Bundle 状态一致
    }

    /// 探测重启后待恢复的任务（PRD P0-09）。
    ///
    /// 通过 `TaskQueueRecovery` 读取队列，**不自动开始复制**——
    /// 用户打开 App 就突然搬运文件是糟糕的体验，交由「任务队列」页显式继续。
    func refreshPendingTasks() {
        guard let queueStore else {
            pendingTaskCount = 0
            return
        }
        let options = settings.makeTransferOptions()
        let policy = settings.defaultConflictPolicy
        let resume = try? JSONResumeStore()
        let recovery = TaskQueueRecovery(
            store: queueStore,
            makeEngine: { [options, policy, resume] in
                CopyEngine(
                    configuration: CopyEngine.Configuration(
                        options: options,
                        resumeManager: resume.map { ResumeManager(store: $0) },
                        conflictResolver: ConflictResolver(policy: policy),
                        verifier: Verifier()
                    ),
                    eventSink: { _ in }
                )
            },
            makeBatches: { task in
                PlanBuilder().build(
                    sourceRoots: task.sourceRoots,
                    destinationRoot: task.destinationRoot
                )
            }
        )
        Task { @MainActor in
            let tasks = try? await recovery.recoverableTasks()
            pendingTaskCount = tasks?.count ?? 0
        }
    }

    // MARK: - 派生显示值

    /// 是否可开始复制。
    var canStart: Bool {
        !sources.isEmpty && destination != nil && !state.isRunningLike
    }

    /// 是否正在运行。
    var isRunning: Bool { state == .running || state == .paused }

    /// 源总大小（字节，异步统计在 start 时做，此处仅显示条目数）。
    var sourceDescription: String {
        sources.isEmpty
            ? Localization.string("ui.source.empty", default: "尚未添加文件")
            : Localization.format("ui.source.count", default: "已添加 %d 项", sources.count)
    }

    /// 目标显示文本。
    var destinationDescription: String {
        destination?.path ?? Localization.string("ui.destination.empty", default: "尚未选择目标文件夹")
    }

    // MARK: - 源与目标操作

    /// 添加源路径（去重 + 存在性校验）。
    ///
    /// 拖入的可能是**文件**也可能是**文件夹**，两者都合法（PRD P0-01）。
    /// 但**不存在的路径**必须当场拒绝并告知用户 —— 否则任务会走到枚举阶段
    /// 才失败，用户看到的是「任务结束但什么都没复制」。
    ///
    /// - Parameter urls: 拖入或选择的文件/文件夹 URL。
    func addSources(_ urls: [URL]) {
        var seen = Set(sources.map(\.standardizedFileURL))
        var added = 0
        var rejected: [String] = []
        for url in urls {
            let key = url.standardizedFileURL
            guard seen.insert(key).inserted else { continue }
            guard FileManager.default.fileExists(atPath: url.path) else {
                rejected.append(url.lastPathComponent)
                continue
            }
            sources.append(url)
            added += 1
        }
        isDropTargeted = false
        if added > 0 {
            appendLog(
                Localization.format("ui.log.added", default: "已添加 %d 个源", added),
                kind: .info
            )
        }
        if !rejected.isEmpty {
            let names = rejected.joined(separator: "、")
            let message = Localization.format(
                "ui.log.sourceMissing",
                default: "以下源不存在，已忽略：%@",
                names
            )
            appendLog(message, kind: .error)
            alertMessage = message
        }
    }

    /// 移除指定源。
    func removeSource(_ url: URL) {
        sources.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
    }

    /// 清空源列表。
    func clearSources() {
        sources.removeAll()
        rows.removeAll()
        summary = nil
        state = .pending
        progress = TransferProgress()
        speedHistory.removeAll()
        degradedReasons.removeAll()
    }

    /// 设置目标目录。
    func setDestination(_ url: URL) {
        destination = url
        var recent = recentDestinations.filter { $0.standardizedFileURL != url.standardizedFileURL }
        recent.insert(url, at: 0)
        recentDestinations = Array(recent.prefix(10))
        Self.saveRecentDestinations(recentDestinations)
    }

    // MARK: - 复制控制

    /// 开始复制。
    func start() {
        guard let destination else {
            alertMessage = Localization.string("ui.alert.noDestination", default: "请先选择目标文件夹")
            return
        }
        guard !sources.isEmpty else {
            alertMessage = Localization.string("ui.alert.noSource", default: "请先添加要复制的文件或文件夹")
            return
        }
        guard canStart else { return }

        // 重置 UI 状态。
        rows = sources.map { FileRow(sourceURL: $0) }
        progress = TransferProgress()
        summary = nil
        degradedReasons.removeAll()
        speedHistory.removeAll()
        state = .running
        appendLog(Localization.string("ui.log.started", default: "开始复制"), kind: .info)

        let options = settings.makeTransferOptions()
        let task = TransferTask(
            sourceRoots: sources.map(\.path),
            destinationRoot: destination.path,
            options: options
        )
        currentTask = task

        // 持久化到队列，保证重启可恢复（PRD P0-09）。
        try? queueStore?.save(task)

        // 单向事件流（架构 §8.6，.bufferingNewest 防高频事件撑爆内存）。
        let (stream, continuation) = AsyncStream<TransferEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )

        let resumeManager = (try? JSONResumeStore()).map { ResumeManager(store: $0) }
        let configuration = CopyEngine.Configuration(
            options: options,
            resumeManager: resumeManager,
            conflictResolver: ConflictResolver(policy: settings.defaultConflictPolicy),
            verifier: Verifier()
        )
        let engine = CopyEngine(configuration: configuration) { event in
            continuation.yield(event)
        }
        self.engine = engine

        let planBuilder = PlanBuilder()
        let batches = planBuilder.build(
            sourceRoots: task.sourceRoots,
            destinationRoot: task.destinationRoot
        )

        // 消费事件（MainActor）。
        runningTask = Task { [weak self] in
            for await event in stream {
                guard let self else { break }
                await MainActor.run { self.handle(event) }
            }
        }

        // 执行复制（后台）。
        Task.detached { [weak self] in
            let result = await engine.run(task: task, batches: batches)
            continuation.finish()
            await MainActor.run {
                guard let self else { return }
                self.finish(with: result)
                try? self.queueStore?.delete(taskID: task.id)
            }
        }
    }

    /// 暂停（当前实现：取消并保留断点，下次可从 .partial 续传）。
    func pause() {
        guard state == .running else { return }
        runningTask?.cancel()
        state = .paused
        appendLog(Localization.string("ui.log.paused", default: "已暂停，未完成的文件保留断点，可继续传输"), kind: .warning)
    }

    /// 继续（从断点续传）。
    func resume() {
        guard state == .paused else { return }
        state = .pending
        appendLog(Localization.string("ui.log.resuming", default: "正在从断点继续…"), kind: .info)
        start()
    }

    /// 取消任务。
    func cancel() {
        runningTask?.cancel()
        state = .cancelled
        appendLog(Localization.string("ui.log.cancelled", default: "已取消传输"), kind: .warning)
    }

    /// 重试失败项（清空已成功行，仅保留失败行对应的源）。
    func retryFailed() {
        let failedPaths = Set(rows.filter { $0.status == .failed }.map { $0.sourceURL.standardizedFileURL })
        guard !failedPaths.isEmpty else { return }
        sources.removeAll { !failedPaths.contains($0.standardizedFileURL) }
        start()
    }

    // MARK: - 事件处理

    /// 处理引擎事件（仅在 MainActor 调用）。
    private func handle(_ event: TransferEvent) {
        switch event {
        case .taskStateChanged(_, let newState):
            state = newState

        case .progress(_, let p):
            progress = p
            speedHistory.append(p.bytesPerSecond)
            if speedHistory.count > 120 { speedHistory.removeFirst(speedHistory.count - 120) }

        case .fileStatusChanged(_, let fileID, let status):
            updateRow(fileID: fileID) { $0.status = status }

        case .fileCompleted(_, let fileID, let outcome):
            updateRow(fileID: fileID) {
                $0.status = outcome.status
                $0.bytesTransferred = outcome.bytesTransferred
                $0.wasCloned = outcome.wasCloned
                $0.duration = outcome.duration
                $0.verification = outcome.verificationResults.first
                $0.destinationPath = outcome.destinationPath
            }
            if let error = outcome.error {
                appendLog(error.localizedDescription, kind: .error)
            }

        case .fileFailed(_, let fileID, let error, let attempt):
            updateRow(fileID: fileID) {
                $0.status = .failed
                $0.failureReason = error.localizedDescription
                $0.attempts = attempt
            }
            appendLog(error.localizedDescription, kind: .error)

        case .verification(_, let result):
            if let index = rows.firstIndex(where: { $0.verification == nil }) {
                rows[index].verification = result
            }

        case .verificationDegraded(_, _, let reason):
            degradedReasons.append(reason)
            appendLog(reason, kind: .warning)

        case .taskFinished(_, let value):
            summary = value

        case .resumable(_, let token):
            appendLog(
                Localization.format(
                    "ui.log.resumable",
                    default: "已保存断点：%@",
                    (token.partialPath as NSString).lastPathComponent
                ),
                kind: .info
            )
        }
    }

    /// 任务收尾。
    private func finish(with result: TransferSummary) {
        summary = result
        if state != .cancelled {
            state = result.failedCount == 0 ? .succeeded : .partialFailed
        }
        appendLog(
            Localization.format(
                "ui.log.finished",
                default: "完成：成功 %d 项，失败 %d 项，跳过 %d 项",
                result.succeededCount, result.failedCount, result.skippedCount
            ),
            kind: result.failedCount == 0 ? .success : .warning
        )
    }

    /// 按文件 ID 更新行；若找不到则忽略（事件可能早于行创建）。
    private func updateRow(fileID: UUID, mutate: (inout FileRow) -> Void) {
        // FileEntry 的 id 与 FileRow.id 一致；若引擎用了不同 ID，则退化为按状态推进第一行。
        if let index = rows.firstIndex(where: { $0.id == fileID }) {
            mutate(&rows[index])
        } else if let index = rows.firstIndex(where: { $0.status == .queued || $0.status == .transferring }) {
            mutate(&rows[index])
        }
    }

    // MARK: - 日志

    /// 追加一条中文日志。
    func appendLog(_ text: String, kind: LogLine.Kind) {
        logSequence += 1
        logLines.append(LogLine(id: logSequence, text: text, kind: kind, date: Date()))
        if logLines.count > 500 { logLines.removeFirst(logLines.count - 500) }
    }

    // MARK: - 最近目录持久化

    private static let recentKey = "MacCopy.RecentDestinations"

    private static func loadRecentDestinations() -> [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
        return paths.map { URL(fileURLWithPath: $0) }
    }

    private static func saveRecentDestinations(_ urls: [URL]) {
        UserDefaults.standard.set(urls.map(\.path), forKey: recentKey)
    }
}

// MARK: - 视图模型用的轻量模型

/// 文件列表中的一行。
struct FileRow: Identifiable, Equatable {
    let id: UUID
    let sourceURL: URL
    var status: FileStatus = .queued
    var bytesTransferred: Int64 = 0
    var wasCloned = false
    var duration: TimeInterval = 0
    var attempts = 0
    var failureReason: String?
    var verification: VerificationResult?
    var destinationPath: String?

    init(id: UUID = UUID(), sourceURL: URL) {
        self.id = id
        self.sourceURL = sourceURL
    }

    var name: String { sourceURL.lastPathComponent }
}

/// 一条运行日志。
struct LogLine: Identifiable, Equatable {
    enum Kind: String { case info, success, warning, error }
    let id: Int
    let text: String
    let kind: Kind
    let date: Date
}

/// 侧边栏项目。
enum SidebarItem: String, CaseIterable, Identifiable {
    case quickStart
    case queue
    case history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quickStart: return Localization.string("ui.sidebar.quickStart", default: "快速开始")
        case .queue: return Localization.string("ui.sidebar.queue", default: "任务队列")
        case .history: return Localization.string("ui.sidebar.history", default: "历史记录")
        case .settings: return Localization.string("ui.sidebar.settings", default: "设置")
        }
    }

    var systemImage: String {
        switch self {
        case .quickStart: return "square.and.arrow.down.on.square"
        case .queue: return "list.bullet.rectangle"
        case .history: return "clock"
        case .settings: return "gearshape"
        }
    }
}

private extension TaskState {
    /// 是否处于「看起来在运行」的状态。
    var isRunningLike: Bool { self == .running || self == .paused }
}
