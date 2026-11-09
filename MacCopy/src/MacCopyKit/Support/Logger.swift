import Foundation
import os

/// 全项目日志入口（架构 §8.5）。
///
/// 规则：
/// - 分类按「层」划分，不按模块划分（便于 `log show --predicate 'category == "io"'`）
/// - 路径等敏感信息用 `privacy: .private`
/// - 绝不打印文件内容
/// - 进度类日志不逐事件打印
public enum Log {
    /// 日志子系统标识。
    public static let subsystem = "com.maccopy"

    /// 复制引擎相关日志。
    public static let engine = Logger(subsystem: subsystem, category: "engine")
    /// 校验算法相关日志。
    public static let checksum = Logger(subsystem: subsystem, category: "checksum")
    /// 文件系统访问相关日志。
    public static let io = Logger(subsystem: subsystem, category: "io")
    /// 持久化相关日志。
    public static let persistence = Logger(subsystem: subsystem, category: "persistence")
    /// UI 层相关日志。
    public static let ui = Logger(subsystem: subsystem, category: "ui")
    /// 本地化 / 语言切换相关日志（v1.1：Debug 记回退，Release 静默）。
    public static let i18n = Logger(subsystem: subsystem, category: "i18n")

    /// 是否为调试构建。进度类日志仅在调试构建输出，避免刷屏。
    public static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// 调试级别日志，仅调试构建输出。
    public static func debug(_ logger: Logger, _ message: String) {
        guard isDebugBuild else { return }
        logger.debug("\(message, privacy: .public)")
    }
}
