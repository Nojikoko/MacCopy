import Foundation

/// 全项目 Feature Flag 的**唯一定义处**（AD-04）。
///
/// 规则：其他文件不得硬编码 Pro 开关或线程上限，一律引用本文件。
public enum FeatureFlags {
    /// Pro 功能总开关。v1.0 恒为 false（无授权 SDK，Q8）。
    public static let proFeaturesEnabled: Bool = false

    /// 是否显示 Pro 锁定态 UI（锁定态要**可见**，但不可启用）。
    public static let showProLockedUI: Bool = true

    /// 免费版线程数硬上限（Q9）。
    public static let freeTierMaxThreads: Int = 2

    /// 免费版线程数绝对上限（设置 UI 可选范围的上界）。
    public static let absoluteMaxThreads: Int = 8

    /// 实际生效线程数：免费版恒 ≤ 2。
    ///
    /// - Parameter requested: 用户请求的线程数。
    /// - Returns: 裁剪后的实际线程数，最小为 1。
    public static func effectiveThreadCount(_ requested: Int) -> Int {
        let upperBound = proFeaturesEnabled ? absoluteMaxThreads : freeTierMaxThreads
        return max(1, min(requested, upperBound))
    }
}
