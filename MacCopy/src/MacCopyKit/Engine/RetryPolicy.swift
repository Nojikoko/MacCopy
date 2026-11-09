import Foundation

/// 重试策略：退避计算、可重试判定、最大次数。
///
/// 架构 Q7：校验失败自动重传 1 次。
public struct RetryPolicy: Sendable {
    /// 退避基数（秒）。
    public static let baseDelay: TimeInterval = 0.5
    /// 退避上限（秒）。
    public static let maxDelay: TimeInterval = 30

    /// 最大重试次数。
    public let maxRetries: Int

    /// 构造重试策略。
    ///
    /// - Parameter maxRetries: 最大重试次数（默认 1）。
    public init(maxRetries: Int = 1) {
        self.maxRetries = max(0, maxRetries)
    }

    /// 是否应该重试。
    ///
    /// - Parameters:
    ///   - error: 错误。
    ///   - attempt: 当前尝试次数（从 1 开始）。
    /// - Returns: 是否重试。
    public func shouldRetry(error: MacCopyError, attempt: Int) -> Bool {
        guard attempt <= maxRetries else { return false }
        return error.isRetryable
    }

    /// 计算退避时长（指数退避 + 抖动上限）。
    ///
    /// - Parameter attempt: 当前尝试次数（从 1 开始）。
    /// - Returns: 退避秒数。
    public func backoff(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        let exponent = Double(attempt - 1)
        let delay = Self.baseDelay * pow(2, exponent)
        return min(delay, Self.maxDelay)
    }
}
