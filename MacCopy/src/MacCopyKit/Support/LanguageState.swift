import Foundation

/// 跨线程共享的当前语言状态（AD-I04）。
///
/// 为什么放在 `MacCopyKit`（Foundation-only）而不是 App 层：
/// `MacCopyError.localizedDescription` / `ConflictPolicy.displayName` / `TaskState` 文案
/// / `Verifier` 失败原因都由 `Task.detached` 后台 worker 产生，
/// SwiftUI 的 `.environment(\.locale)` 无法穿透到后台。
/// 全局单例让后台 worker 直接读到最新 Bundle，无需跨 actor 传递。
/// AD-02 禁止的是 `import SwiftUI/AppKit/ServiceManagement`，不禁止 Foundation 的
/// `Bundle` / `NSLock` / `UserDefaults`。
public final class LanguageState: @unchecked Sendable {
    /// 全局唯一实例。
    public static let shared = LanguageState()

    /// 保护 `_bundle` / `_tag` 的锁。
    private let lock = NSLock()
    /// 语言专用 Bundle（nil = 使用中文 `defaultValue` 基准）。
    private var _bundle: Bundle?
    /// 当前语言 tag。
    private var _tag: String = SupportedLanguage.zhHans.rawValue

    /// 私有构造（强制单例）。
    private init() {}

    /// 当前语言 Bundle。nil 时 `Localization` 直接返回中文基准。
    public var bundle: Bundle? {
        lock.lock()
        defer { lock.unlock() }
        return _bundle
    }

    /// 当前语言 tag。
    public var tag: String {
        lock.lock()
        defer { lock.unlock() }
        return _tag
    }

    /// 原子地更新语言状态（后台 worker 立即可见）。
    ///
    /// - Parameters:
    ///   - bundle: 语言专用 Bundle；nil 表示回退到中文基准。
    ///   - tag: 语言 tag。
    public func set(bundle: Bundle?, tag: String) {
        lock.lock()
        defer { lock.unlock() }
        _bundle = bundle
        _tag = tag
    }
}

/// 语言专用 Bundle 工厂。
public enum LanguageBundleFactory: Sendable {
    /// 由 `<Resources>/<tag>.lproj` 构造 Bundle。
    ///
    /// 目录缺失 / CLI 环境 / `resourceURL == nil` → 返回 nil，
    /// `Localization` 自动回退中文 `defaultValue`，行为确定且不崩溃（Q12）。
    ///
    /// - Parameter tag: 语言 tag（必须是 `SupportedLanguage` 之一）。
    /// - Returns: Bundle 或 nil。
    public static func make(tag: String) -> Bundle? {
        guard SupportedLanguage(rawValue: tag) != nil,
              let resource = Bundle.main.resourceURL else { return nil }
        let lproj = resource.appendingPathComponent("\(tag).lproj", isDirectory: true)
        guard FileManager.default.fileExists(atPath: lproj.path) else { return nil }
        return Bundle(path: lproj.path)
    }
}
