import Foundation

/// v1.1 支持的八种界面语言标签。
///
/// 顺序固定（PRD-I18N §2 / 主理人 Q10 锁定），**不按当前界面语言重排**。
/// 一律使用 ``rawValue`` 作为语言 tag，禁止在代码里硬编码字符串。
public enum SupportedLanguage: String, CaseIterable, Sendable {
    /// 简体中文（产品基准语言）。
    case zhHans = "zh-Hans"
    /// 英语（系统语言未覆盖时的兜底）。
    case en = "en"
    /// 繁體中文（单一 zh-Hant，不区分 TW/HK/MO）。
    case zhHant = "zh-Hant"
    /// 日本語。
    case ja = "ja"
    /// 한국어.
    case ko = "ko"
    /// Français.
    case fr = "fr"
    /// Deutsch.
    case de = "de"
    /// Español（Q10：保留 es，不换 pt-BR）。
    case es = "es"

    /// 各语言的自称（endonym）。
    ///
    /// 设置页 Picker 一律用此显示，与当前界面语言无关。
    public var endonym: String {
        switch self {
        case .zhHans: return "简体中文"
        case .en: return "English"
        case .zhHant: return "繁體中文"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .fr: return "Français"
        case .de: return "Deutsch"
        case .es: return "Español"
        }
    }

    /// 全部语言 tag（与 `Info.plist` 的 `CFBundleLocalizations` 顺序一致）。
    public static var allTags: [String] { allCases.map(\.rawValue) }
}

/// 语言解析结果。
public struct LanguageResolution: Sendable, Equatable {
    /// 最终生效的语言。
    public let language: SupportedLanguage
    /// 是否因「系统语言全部未覆盖」而回退到英语（P1-02 非阻塞提示用）。
    public let isSystemFallback: Bool

    /// 构造解析结果。
    public init(language: SupportedLanguage, isSystemFallback: Bool) {
        self.language = language
        self.isSystemFallback = isSystemFallback
    }
}

/// 语言解析协议（可 mock，便于单测）。
public protocol LanguageResolving: Sendable {
    /// 解析当前应生效的语言。
    ///
    /// - Parameters:
    ///   - systemLocalizations: 系统偏好语言列表（如 `Bundle.main.preferredLocalizations`）。
    ///   - manualTag: 用户手动选择的语言 tag；nil 表示未设置。
    ///   - followsSystem: 是否跟随系统语言。
    /// - Returns: 解析结果。
    func resolve(
        systemLocalizations: [String],
        manualTag: String?,
        followsSystem: Bool
    ) -> LanguageResolution
}

/// 默认语言解析器：纯函数、无状态、可单测。
///
/// 优先级（PRD-I18N §3.3，顺序不可调换）：
/// 1. 手动值合法 → 使用
/// 2. 手动值非法/损坏 → 视为未设置 + 诊断日志，落入系统解析
/// 3. 系统列表为空 → `zh-Hans`
/// 4. 逐项：精确命中 → 两段前缀（`en-GB`→`en`、`zh-Hant-TW`→`zh-Hant`）
///    → 裸 `zh` 按区域判简繁 → 裸语言标签
/// 5. 全部未覆盖 → `en`（Q1 裁决）
/// 6. 异常兜底 → `zh-Hans`
public struct LanguageResolver: LanguageResolving {
    /// 构造解析器。
    public init() {}

    /// 解析当前应生效的语言。
    public func resolve(
        systemLocalizations: [String],
        manualTag: String?,
        followsSystem: Bool
    ) -> LanguageResolution {
        // ① 手动覆盖（`followsSystem == false` 时生效）。
        if !followsSystem, let tag = manualTag {
            if let hit = SupportedLanguage(rawValue: tag) {
                return LanguageResolution(language: hit, isSystemFallback: false)
            }
            // ② 手动值非法 → 视为未设置，落入系统解析。
            Log.debug(
                Log.i18n,
                "手动语言值非法，按未设置处理：\(tag)"
            )
        }

        // ③ 系统列表为空 → 中文基准。
        guard !systemLocalizations.isEmpty else {
            return LanguageResolution(language: .zhHans, isSystemFallback: false)
        }

        for raw in systemLocalizations {
            // 4-pre 精确命中。
            if let exact = SupportedLanguage(rawValue: raw) {
                return LanguageResolution(language: exact, isSystemFallback: false)
            }
            let parts = raw.split(separator: "-", omittingEmptySubsequences: false).map(String.init)

            // 4a 两段前缀：**必须早于裸 zh 判定**，否则 zh-Hant-TW 会被误判成 zh-Hans。
            if parts.count >= 2,
               let hit = SupportedLanguage(rawValue: parts[0] + "-" + parts[1]) {
                return LanguageResolution(language: hit, isSystemFallback: false)
            }
            // 4b 裸 zh 按区域判简繁。
            if parts.first == "zh" {
                let region = parts.dropFirst().last?.uppercased() ?? ""
                let isHant = ["TW", "HK", "MO"].contains(region)
                return LanguageResolution(
                    language: isHant ? .zhHant : .zhHans,
                    isSystemFallback: false
                )
            }
            // 4c 裸语言标签。
            if let hit = SupportedLanguage(rawValue: parts.first ?? "") {
                return LanguageResolution(language: hit, isSystemFallback: false)
            }
        }

        // ⑤ 全部未覆盖 → 英语。
        return LanguageResolution(language: .en, isSystemFallback: true)
    }
}
