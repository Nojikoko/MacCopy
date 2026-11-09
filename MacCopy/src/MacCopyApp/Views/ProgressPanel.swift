import SwiftUI
import Charts
import MacCopyKit

/// 进度面板：速度曲线 + 双口径进度条 + 统计 + 降级警示。
struct ProgressPanel: View {
    @EnvironmentObject private var vm: TransferViewModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                header
                byteProgress
                fileProgress

                if !vm.speedHistory.isEmpty {
                    speedChart
                }

                statsGrid

                if !vm.degradedReasons.isEmpty {
                    degradedBanner
                }

                if let summary = vm.summary {
                    summaryBanner(summary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(Localization.string("ui.section.progress", default: "传输进度"), systemImage: "chart.xyaxis.line")
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            statusBadge
            Spacer()
            Text(ByteFormatter.string(from: vm.progress.bytesPerSecond) + "/s")
                .font(.system(.title3, design: .rounded).monospacedDigit())
                .foregroundStyle(.primary)
            if let eta = vm.progress.estimatedRemaining {
                Text("· " + Localization.format("ui.eta", default: "剩余 %@", DurationFormatter.string(from: eta)))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusBadge: some View {
        Text(vm.state.displayName)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(stateColor.opacity(0.16), in: Capsule())
            .foregroundStyle(stateColor)
    }

    private var stateColor: Color {
        switch vm.state {
        case .pending: return .secondary
        case .running: return .blue
        case .paused: return .orange
        case .succeeded: return .green
        case .partialFailed: return .orange
        case .cancelled: return .gray
        }
    }

    // MARK: - 进度条

    private var byteProgress: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(Localization.string("ui.progress.bytes", default: "字节"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(ByteFormatter.string(from: vm.progress.transferredBytes)) / \(ByteFormatter.string(from: vm.progress.totalBytes))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(max(vm.progress.byteFraction, 0), 1))
                .progressViewStyle(.linear)
        }
    }

    private var fileProgress: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(Localization.string("ui.progress.files", default: "文件"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(vm.progress.completedFiles) / \(vm.progress.totalFiles)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(max(vm.progress.fileFraction, 0), 1))
                .progressViewStyle(.linear)
                .tint(.teal)
        }
    }

    // MARK: - 速度曲线

    private var speedChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Localization.string("ui.chart.speed", default: "速度曲线（最近 120 秒）"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Chart {
                ForEach(Array(vm.speedHistory.enumerated()), id: \.offset) { index, value in
                    LineMark(
                        x: .value("t", index),
                        y: .value("v", value / 1_048_576)
                    )
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    AreaMark(
                        x: .value("t", index),
                        y: .value("v", value / 1_048_576)
                    )
                    .foregroundStyle(Color.accentColor.opacity(0.12))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxisLabel(Localization.string("ui.chart.unit", default: "MiB/s"))
            .frame(height: 84)
        }
    }

    // MARK: - 统计

    private var statsGrid: some View {
        HStack(spacing: 0) {
            statCell(Localization.string("ui.stat.success", default: "成功"), "\(vm.progress.completedFiles)", .green)
            statCell(Localization.string("ui.stat.failed", default: "失败"), "\(vm.progress.failedFiles)", .red)
            statCell(Localization.string("ui.stat.skipped", default: "跳过"), "\(vm.progress.skippedFiles)", .orange)
            statCell(Localization.string("ui.stat.avg", default: "平均速度"), ByteFormatter.string(from: vm.progress.bytesPerSecond) + "/s", .primary)
        }
    }

    private func statCell(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.callout, design: .rounded).weight(.medium).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 警示

    private var degradedBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(Localization.string("ui.degraded.title", default: "部分文件未做内容哈希，无法证明与源一致"), systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            ForEach(Array(vm.degradedReasons.prefix(3).enumerated()), id: \.offset) { _, reason in
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func summaryBanner(_ summary: TransferSummary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: summary.failedCount == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(summary.failedCount == 0 ? .green : .orange)
            Text(Localization.format(
                "ui.summary.line",
                default: "完成：成功 %d 项 · 失败 %d 项 · 跳过 %d 项 · 耗时 %@",
                summary.succeededCount, summary.failedCount, summary.skippedCount,
                DurationFormatter.string(from: summary.duration)
            ))
            .font(.caption)
            Spacer()
            if summary.failedCount > 0 {
                Button(Localization.string("ui.retryFailed", default: "重试失败项")) {
                    vm.retryFailed()
                }
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - 格式化工具（UI 层，避免 MacCopyKit 暴露 ByteCountFormatter）

enum ByteFormatter {
    static func string(from bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }

    static func string(from bytes: Double) -> String {
        string(from: Int64(bytes.rounded()))
    }
}

enum DurationFormatter {
    static func string(from seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else {
            return Localization.string("ui.duration.unknown", default: "计算中")
        }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \((total % 3600) / 60)m"
    }
}
