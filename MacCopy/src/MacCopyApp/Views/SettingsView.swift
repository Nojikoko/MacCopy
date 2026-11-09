import SwiftUI
import MacCopyKit

/// 设置页：复制引擎 / 校验 / 冲突 / 限速 / Pro 锁定态。
struct SettingsView: View {
    @EnvironmentObject private var vm: TransferViewModel

    var body: some View {
        Form {
            // v1.1：语言 Section 必须是第一个（架构 T-I03 §7）。
            Section(Localization.string("ui.settings.language", default: "界面语言")) {
                LanguageSectionView()
            }

            Section(Localization.string("ui.settings.engine", default: "复制引擎")) {
                HStack {
                    Stepper(value: $vm.settings.threadCount, in: 1...8) {
                        Text(Localization.format("ui.settings.threads", default: "并发线程数：%d", vm.settings.threadCount))
                    }
                    Spacer()
                    if vm.settings.threadCount > FeatureFlags.freeTierMaxThreads {
                        ProBadge()
                    }
                }
                Text(Localization.format(
                    "ui.settings.threads.hint",
                    default: "免费版最多使用 %d 线程，当前实际生效 %d 线程",
                    FeatureFlags.freeTierMaxThreads,
                    vm.settings.effectiveThreadCount
                ))
                .font(.caption)
                .foregroundStyle(.secondary)

                Stepper(value: $vm.settings.bufferSizeMB, in: 1...64) {
                    Text(Localization.format("ui.settings.buffer", default: "缓冲区：%d MiB", vm.settings.bufferSizeMB))
                }

                Toggle(Localization.string("ui.settings.timestamps", default: "保留文件时间戳"), isOn: $vm.settings.preserveTimestamps)
                Toggle(Localization.string("ui.settings.clone", default: "同卷启用 APFS 克隆（秒拷）"), isOn: $vm.settings.enableClone)

                Picker(Localization.string("ui.settings.sparse", default: "稀疏文件"), selection: $vm.settings.sparseMode) {
                    ForEach(SparseMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                Stepper(value: $vm.settings.maxRetries, in: 0...5) {
                    Text(Localization.format("ui.settings.retries", default: "失败重试次数：%d", vm.settings.maxRetries))
                }
            }

            Section(Localization.string("ui.settings.verification", default: "完整性校验")) {
                Text(Localization.string("ui.settings.algorithms", default: "校验算法（可多选）"))
                ForEach(ChecksumAlgorithmID.allCases, id: \.self) { algorithm in
                    MultipleChoiceRow(
                        title: algorithm.displayName,
                        isSelected: vm.settings.defaultAlgorithms.contains(algorithm)
                    ) {
                        toggle(algorithm)
                    }
                }

                Picker(Localization.string("ui.settings.verifyMode", default: "校验方式"), selection: $vm.settings.verificationMode) {
                    ForEach(VerificationMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                Toggle(Localization.string("ui.settings.checksumFile", default: "生成校验清单文件（兼容 shasum -c）"),
                       isOn: $vm.settings.generateChecksumFile)

                Text(Localization.string("ui.settings.verify.hint",
                    default: "源与目标摘要逐算法比对。若源不可寻址且无法回读，会明确标注「未做内容哈希」，不会静默通过。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(Localization.string("ui.settings.conflict", default: "冲突处理")) {
                Picker(Localization.string("ui.settings.conflictPolicy", default: "目标已存在时"), selection: $vm.settings.defaultConflictPolicy) {
                    ForEach(ConflictPolicy.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
            }

            Section(Localization.string("ui.settings.throttle", default: "速率限制")) {
                Toggle(isOn: Binding(
                    get: { vm.settings.bandwidthLimit != nil },
                    set: { vm.settings.bandwidthLimit = $0 ? 1_048_576 : nil }
                )) {
                    Text(Localization.string("ui.settings.throttle.enable", default: "启用限速"))
                }
                if let limit = vm.settings.bandwidthLimit {
                    HStack {
                        Slider(value: Binding(
                            get: { Double(limit) / 1_048_576 },
                            set: { vm.settings.bandwidthLimit = Int($0 * 1_048_576) }
                        ), in: 0.5...200)
                        Text(ByteFormatter.string(from: Int64(limit)) + "/s")
                            .font(.caption.monospacedDigit())
                            .frame(width: 90, alignment: .trailing)
                    }
                }
            }

            Section(Localization.string("ui.settings.pro", default: "Pro 功能")) {
                HStack { Text(Localization.string("ui.pro.threads", default: "3 线程及以上并发")); Spacer(); ProBadge() }
                HStack { Text(Localization.string("ui.pro.algorithms", default: "17 种校验算法")); Spacer(); ProBadge() }
                HStack { Text(Localization.string("ui.pro.html", default: "HTML 报告导出")); Spacer(); ProBadge() }
                HStack { Text(Localization.string("ui.pro.automation", default: "复制后自动运行脚本")); Spacer(); ProBadge() }
                Text(Localization.string("ui.pro.hint", default: "v1.0 仅展示占位，Pro 功能通过编译期开关预留。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(Localization.string("ui.settings.maintenance", default: "维护")) {
                Button(Localization.string("ui.settings.reset", default: "恢复默认设置")) {
                    // v1.1 / Q7：必须走 resetEngineSettings() 保留语言偏好。
                    vm.resetEngineSettings()
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460)
    }

    private func toggle(_ algorithm: ChecksumAlgorithmID) {
        if vm.settings.defaultAlgorithms.contains(algorithm) {
            vm.settings.defaultAlgorithms.remove(algorithm)
        } else {
            vm.settings.defaultAlgorithms.insert(algorithm)
        }
    }
}

/// Pro 锁定徽标。
private struct ProBadge: View {
    var body: some View {
        Text(Localization.string("ui.pro.badge", default: "Pro"))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.purple.opacity(0.14), in: Capsule())
            .foregroundStyle(.purple)
    }
}

/// 多选行。
private struct MultipleChoiceRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                Text(title)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
