import SwiftUI
import MacCopyKit

/// 文件列表：逐文件状态、大小、校验结果、失败原因。
struct FileListView: View {
    @EnvironmentObject private var vm: TransferViewModel

    var body: some View {
        GroupBox {
            VStack(spacing: 0) {
                HStack {
                    Text(Localization.string("ui.column.name", default: "名称")).frame(maxWidth: .infinity, alignment: .leading)
                    Text(Localization.string("ui.column.status", default: "状态")).frame(width: 90, alignment: .leading)
                    Text(Localization.string("ui.column.size", default: "已传输")).frame(width: 90, alignment: .trailing)
                    Text(Localization.string("ui.column.verify", default: "校验")).frame(width: 70, alignment: .trailing)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)

                Divider()

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(vm.rows) { row in
                            FileRowView(row: row)
                                .background(
                                    vm.selectedRowID == row.id
                                        ? Color.accentColor.opacity(0.1)
                                        : Color.clear
                                )
                                .contentShape(Rectangle())
                                .onTapGesture { vm.selectedRowID = row.id }
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        } label: {
            Label(
                Localization.format("ui.section.files", default: "文件列表（%d 项）", vm.rows.count),
                systemImage: "list.bullet"
            )
        }
    }
}

/// 单行文件。
private struct FileRowView: View {
    let row: FileRow

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .lineLimit(1)
                if let reason = row.failureReason {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                } else if row.wasCloned {
                    Text(Localization.string("ui.row.cloned", default: "APFS 克隆（秒拷）"))
                        .font(.caption2)
                        .foregroundStyle(.teal)
                } else if let path = row.destinationPath {
                    Text(path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(row.status.displayName)
                .font(.caption)
                .foregroundStyle(statusColor)
                .frame(width: 90, alignment: .leading)

            Text(ByteFormatter.string(from: row.bytesTransferred))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)

            verificationBadge
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private var iconName: String {
        switch row.status {
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .skipped: return "arrow.uturn.right.circle"
        case .transferring: return "arrow.down.circle"
        case .verifying: return "magnifyingglass.circle"
        case .cancelled: return "xmark.circle"
        case .queued: return "circle"
        }
    }

    private var iconColor: Color {
        switch row.status {
        case .succeeded: return .green
        case .failed: return .red
        case .skipped, .cancelled: return .orange
        case .transferring, .verifying: return .blue
        case .queued: return .secondary
        }
    }

    private var statusColor: Color { iconColor }

    @ViewBuilder
    private var verificationBadge: some View {
        if let verification = row.verification {
            if verification.isPassed {
                Label(Localization.string("ui.verify.passed", default: "通过"), systemImage: "checkmark")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else {
                Label(Localization.string("ui.verify.failed", default: "不符"), systemImage: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        } else {
            Text("—")
                .font(.caption)
                .foregroundStyle(.quaternary)
        }
    }
}

/// 运行日志。
struct LogView: View {
    @EnvironmentObject private var vm: TransferViewModel

    var body: some View {
        GroupBox {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(vm.logLines.suffix(60)) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(line.date, style: .time)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.quaternary)
                            Text(line.text)
                                .font(.caption)
                                .foregroundStyle(color(for: line.kind))
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(maxHeight: 130)
        } label: {
            Label(Localization.string("ui.section.log", default: "运行日志"), systemImage: "text.alignleft")
        }
    }

    private func color(for kind: LogLine.Kind) -> Color {
        switch kind {
        case .info: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}
