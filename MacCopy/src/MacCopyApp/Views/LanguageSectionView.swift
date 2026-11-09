import SwiftUI
import MacCopyKit

/// 设置页「界面语言」Section 的**内容**（v1.1 / F11）。
///
/// 结构说明：`Section(...)` 外壳放在 `SettingsView.swift`（作为第一个 Section），
/// 本视图只提供其中的行，这样 `SettingsView.swift` 的 Section 数恰为 7
/// （架构 T-I03 验收命令），同时语言逻辑仍独立成文件便于维护。
///
/// - Picker 用 `SupportedLanguage.endonym`（自称），顺序固定为 Q10 锁定的八语
/// - 「跟随系统」开启时 Picker 禁用 + 降低不透明度
/// - 全部文案走 `Localization.string`，零裸中文字面量
struct LanguageSectionView: View {
    @EnvironmentObject private var vm: TransferViewModel

    var body: some View {
        // 跟随系统开关。
        Toggle(
            Localization.string(
                "ui.settings.language.followSystem",
                default: "跟随系统语言"
            ),
            isOn: $vm.settings.languageFollowsSystem
        )

        // 八语 Picker：顺序固定，与 Info.plist 的 CFBundleLocalizations 一致。
        Picker(
            Localization.string("ui.settings.language.picker", default: "选择语言"),
            selection: Binding(
                get: {
                    vm.settings.manualLanguageTag ?? SupportedLanguage.zhHans.rawValue
                },
                set: { tag in
                    vm.settings.manualLanguageTag = tag
                    vm.settings.languageFollowsSystem = false
                }
            )
        ) {
            ForEach(SupportedLanguage.allCases, id: \.self) { language in
                Text(language.endonym).tag(language.rawValue)
            }
        }
        .disabled(vm.settings.languageFollowsSystem)
        .opacity(vm.settings.languageFollowsSystem ? 0.5 : 1.0)

        // 当前生效语言（静态行，动态值单独 Text 渲染，避免新增格式串）。
        HStack {
            Text(Localization.string("ui.settings.language.current", default: "当前生效语言"))
            Spacer()
            Text(activeEndonym)
                .foregroundStyle(.secondary)
        }

        // 即时生效说明。
        Text(Localization.string(
            "ui.settings.language.instantHint",
            default: "切换后立即生效，无需重启。"
        ))
        .font(.caption)
        .foregroundStyle(.secondary)

        // Section 说明。
        Text(Localization.string(
            "ui.settings.language.sectionHint",
            default: "此设置只影响界面文字，不影响文件内容与校验结果。"
        ))
        .font(.caption)
        .foregroundStyle(.secondary)

        // 手动模式下提供「恢复跟随系统」。
        if !vm.settings.languageFollowsSystem {
            Button(Localization.string(
                "ui.settings.language.restoreFollow",
                default: "恢复跟随系统"
            )) {
                vm.settings.languageFollowsSystem = true
                vm.settings.manualLanguageTag = nil
            }
        }

        // 一次性迁移提示（P0-08 ③）。
        if vm.settings.didMigrateFromV10 {
            Text(Localization.string(
                "ui.settings.language.migratedHint",
                default: "已从旧版本升级，界面语言保持简体中文。"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        // 系统语言未覆盖的非阻塞提示（P1-02）。
        if vm.isSystemFallback {
            Text(Localization.string(
                "ui.settings.language.unsupportedHint",
                default: "当前系统语言暂未支持，已显示 English。"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// 当前生效语言的自称（endonym），始终以自身文字显示。
    private var activeEndonym: String {
        SupportedLanguage(rawValue: vm.activeLanguageTag)?.endonym
            ?? SupportedLanguage.zhHans.endonym
    }
}
