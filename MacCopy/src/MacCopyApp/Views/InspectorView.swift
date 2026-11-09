import SwiftUI
import MacCopyKit

/// 右侧检查器：当前任务概览 + 选中文件详情 + 校验差异。
struct InspectorView: View {
    @EnvironmentObject private var vm: TransferViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                overview
                Divider()
                if let row = selectedRow {
                    fileDetail(row)
                } else {
                    emptyHint
                }
                Divider()
                environmentNotes
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 250, idealWidth: 280)
        .background(.background)
    }

    private var selectedRow: FileRow? {
        vm.rows.first { $0.id == vm.selectedRowID }
    }

    // MARK: - 概览

    private var overview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(Localization.string("ui.inspector.overview", default: "任务概览"), systemImage: "info.circle")
                .font(.headline)
            infoRow(Localization.string("ui.inspector.state", default: "状态"), vm.state.displayName)
            infoRow(Localization.string("ui.inspector.sources", default: "源条目"), "\(vm.sources.count)")
            infoRow(Localization.string("ui.inspector.target", default: "目标"), vm.destination?.lastPathComponent ?? "—")
            infoRow(Localization.string("ui.inspector.transferred", default: "已传输"), ByteFormatter.string(from: vm.progress.transferredBytes))
            infoRow(Localization.string("ui.inspector.speed", default: "当前速度"), ByteFormatter.string(from: vm.progress.bytesPerSecond) + "/s")
            if let eta = vm.progress.estimatedRemaining {
                infoRow(Localization.string("ui.inspector.eta", default: "预计剩余"), DurationFormatter.string(from: eta))
            }
        }
    }

    // MARK: - 文件详情

    private func fileDetail(_ row: FileRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(Localization.string("ui.inspector.file", default: "文件详情"), systemImage: "doc.text.magnifyingglass")
                .font(.headline)
            infoRow(Localization.string("ui.inspector.name", default: "名称"), row.name)
            infoRow(Localization.string("ui.inspector.path", default: "源路径"), row.sourceURL.path)
            infoRow(Localization.string("ui.inspector.status", default: "状态"), row.status.displayName)
            infoRow(Localization.string("ui.inspector.bytes", default: "已写入"), ByteFormatter.string(from: row.bytesTransferred))
            if row.wasCloned {
                infoRow(Localization.string("ui.inspector.method", default: "方式"),
                        Localization.string("ui.inspector.clone", default: "APFS 克隆"))
            }
            if row.attempts > 0 {
                infoRow(Localization.string("ui.inspector.attempts", default: "尝试次数"), "\(row.attempts)")
            }
            if let reason = row.failureReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if let verification = row.verification {
                Divider()
                Label(Localization.string("ui.inspector.verify", default: "校验结果"), systemImage: "checkmark.seal")
                    .font(.subheadline.weight(.semibold))
                infoRow(Localization.string("ui.inspector.algorithm", default: "算法"), verification.algorithm.displayName)
                infoRow(Localization.string("ui.inspector.result", default: "结果"),
                        verification.isPassed
                        ? Localization.string("ui.verify.passed", default: "通过")
                        : Localization.string("ui.verify.failed", default: "不符"))
                if let expected = verification.expected {
                    monoRow(Localization.string("ui.inspector.expected", default: "源摘要"), expected)
                }
                if let actual = verification.actual {
                    monoRow(Localization.string("ui.inspector.actual", default: "目标摘要"), actual)
                }
                if let offset = verification.firstDifferenceOffset {
                    infoRow(Localization.string("ui.inspector.diffOffset", default: "首个差异偏移"), "\(offset)")
                }
            }
            if let destination = row.destinationPath {
                Divider()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: destination)])
                } label: {
                    Label(Localization.string("ui.inspector.reveal", default: "在 Finder 中显示"), systemImage: "folder")
                }
                .controlSize(.small)
            }
        }
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(Localization.string("ui.inspector.file", default: "文件详情"), systemImage: "doc.text.magnifyingglass")
                .font(.headline)
            Text(Localization.string("ui.inspector.selectHint", default: "在文件列表中点选一项，查看路径、状态与校验详情。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 环境说明

    private var environmentNotes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(Localization.string("ui.inspector.engine", default: "引擎信息"), systemImage: "cpu")
                .font(.subheadline.weight(.semibold))
            infoRow(Localization.string("ui.inspector.threads", default: "生效线程"), "\(vm.settings.effectiveThreadCount)")
            infoRow(Localization.string("ui.inspector.buffer", default: "缓冲区"), "\(vm.settings.bufferSizeMB) MiB")
            infoRow(Localization.string("ui.inspector.verifyMode", default: "校验方式"), vm.settings.verificationMode.displayName)
            infoRow(Localization.string("ui.inspector.algorithms", default: "算法数"), "\(vm.settings.defaultAlgorithms.count)")
            Text(Localization.string("ui.inspector.native", default: "原生 Swift 6 · arm64 · macOS 13+ · 零第三方依赖"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - 通用行

    private func infoRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .lineLimit(3)
        }
    }

    private func monoRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }
}
