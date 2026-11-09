import Foundation

/// 本地化辅助（架构 §8.8 / ARCHITECTURE-I18N §3.3）。
///
/// 约定：
/// - 代码中一律通过 `Localization.string/format` 取文案，key 是英文短语
/// - 中文文案以 `defaultValue` 形式内联，保证**零配置**环境下也一定是中文
/// - v1.1：`LanguageState` 持有语言专用 Bundle；有 Bundle 时从该 Bundle 取译文
/// - **AD-I03：以下两个函数签名冻结**，8 个 MacCopyKit 模块都在调用，改签名属破坏性变更
///
/// 实现说明：`String(localized:)` 的 key 参数要求 `StaticString`（编译期字面量），
/// 因此本工具把 key 作为 `StaticString` 传递；调用方必须传字面量。
public enum Localization {
    /// 一个**永不存在的** `.strings` table 名。
    ///
    /// 架构 AD-I12 / V-B1~V-B4：中文基准必须绕开 `Bundle.main`。
    ///
    /// 为什么不能用裸 `String(localized: key, defaultValue: dv)`：
    /// 该重载默认查 `Bundle.main`，而正式 `.app` 里我们自己会放 8 个 `.lproj`。
    /// 系统语言为英文时，这句「中文基准」实际拿到的是**英文译文**：
    /// 1. 空串兜底会退到英文（违反 P0-06 ②）
    /// 2. `FormatSignature` 的比对基准随系统语言漂移，占位符防护判定失真
    /// 3. 更严重：若坏译文把 `%d` 改成 `%@`，被劫持的 `base` 也会是 `%@`，
    ///    两边签名相等 → 防护**不触发** → `String(format:"...%@", Int)` → **SIGSEGV / exit 139**
    ///
    /// 传一个不存在的 table 名可强制回退编译期 `defaultValue`（中文原文），
    /// 与 `Bundle.main` / 系统语言 / 语言专用 Bundle 全部解耦。
    private static let baselineTable = "__MacCopy_Baseline_No_Such_Table__"

    /// 取编译期中文基准（**所有兜底与签名比对都必须用这个**）。
    ///
    /// - Parameters:
    ///   - key: 本地化 key（编译期字面量）。
    ///   - defaultValue: 中文基准文案。
    /// - Returns: 恒为中文的基准串。
    private static func baseline(
        _ key: StaticString,
        _ defaultValue: String.LocalizationValue
    ) -> String {
        String(localized: key, defaultValue: defaultValue, table: baselineTable)
    }

    /// 取本地化字符串。
    ///
    /// 运行期兜底（V-A5）：当 key 存在但**译文值为空串**时，原生 API 会原样返回
    /// `""` 而**不会**回退，必须显式补强（PRD-I18N P0-06 ②）。
    ///
    /// - Parameters:
    ///   - key: 本地化 key（英文短语字面量）。
    ///   - defaultValue: 无 String Catalog 时的兜底文案（必须是中文基准）。
    /// - Returns: 本地化后的字符串。
    public static func string(_ key: StaticString, default defaultValue: String.LocalizationValue) -> String {
        // 中文基准：必须来自 baseline()，与 Bundle.main 解耦（AD-I12）。
        let base = baseline(key, defaultValue)
        guard let bundle = LanguageState.shared.bundle else { return base }

        let value = String(localized: key, defaultValue: defaultValue, bundle: bundle)
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Log.debug(
                Log.i18n,
                "空串回退：\(String(describing: key)) lang=\(LanguageState.shared.tag)"
            )
            return base
        }
        return value
    }

    /// 取带参数占位符的本地化字符串，并做 `String(format:)` 替换。
    ///
    /// 运行期防护（V-A6，**致命项**）：译文的占位符类型与中文基准不一致时
    /// （例如基准 `%d` 被译成 `%@`），`String(format:)` 会直接 **SIGSEGV**。
    /// 因此必须先用 ``FormatSignature`` 比对**数量与类型**，并确认参数个数足够；
    /// 任一不符就退回中文基准，绝不崩溃（PRD-I18N P0-06 / P0-10 ③）。
    ///
    /// - Parameters:
    ///   - key: 本地化 key（英文短语字面量）。
    ///   - defaultValue: 兜底格式串，使用 `%@` / `%d` 等占位符。
    ///   - arguments: 替换参数。
    /// - Returns: 替换后的字符串。
    public static func format(
        _ key: StaticString,
        default defaultValue: String.LocalizationValue,
        _ arguments: CVarArg...
    ) -> String {
        let base = baseline(key, defaultValue)
        var pattern = base

        if let bundle = LanguageState.shared.bundle {
            let candidate = String(localized: key, defaultValue: defaultValue, bundle: bundle)
            if !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let baseTypes = FormatSignature.types(of: base)
                let candidateTypes = FormatSignature.types(of: candidate)

                if baseTypes == candidateTypes, candidateTypes.count <= arguments.count {
                    pattern = candidate
                } else {
                    // 签名不符或参数不足 → 退回中文基准。
                    Log.debug(
                        Log.i18n,
                        "格式串防护触发，退回基准：\(String(describing: key)) lang=\(LanguageState.shared.tag)"
                    )
                }
            }
        }

        // 基准自身也可能参数不足（调用方 bug）：此时不拼格式，直接返回基准，
        // 避免 String(format:) 读取越界参数导致未定义行为。
        guard FormatSignature.types(of: pattern).count <= arguments.count else {
            Log.debug(Log.i18n, "参数不足，返回原始格式串：\(String(describing: key))")
            return pattern
        }
        return String(format: pattern, arguments: arguments)
    }
}
