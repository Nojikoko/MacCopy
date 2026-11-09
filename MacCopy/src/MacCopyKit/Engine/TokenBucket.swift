import Foundation

/// 令牌桶限速器（架构 T05 遗留项 1 / PRD P1-06）。
///
/// 设计要点：
/// - **令牌桶**而非「累计字节数 + sleep」：简单 sleep 会让吞吐剧烈抖动
///   （写 8 MiB 睡 8 秒 → 用户看到「卡住 8 秒然后瞬间传完」）。
/// - 令牌按经过时间连续补充，等待按「还缺多少令牌 / 速率」精确计算。
/// - **默认初始令牌为 0**（不送免费突发额度）：这样短期传输的实测均速也能
///   精确贴合设定速率。PRD 验收要求「1 MB/s 时实测偏差 ≤10%」，
///   若初始就给 1 秒的免费额度，4 MiB 传输只需 3 秒 → 均速 1.33 MB/s（偏差 33%）。
///   需要突发能力的场景可显式传 `initialTokens`。
public struct TokenBucket: Sendable {
    /// 每秒补充的令牌数（= 限速字节/秒）。
    public let rateBytesPerSecond: Double
    /// 桶容量（= 允许的最大突发字节数）。
    public let capacity: Double

    /// 当前令牌数。
    private var tokens: Double
    /// 上次补充令牌的时刻。
    private var lastRefill: Date

    /// 构造令牌桶。
    ///
    /// - Parameters:
    ///   - rateBytesPerSecond: 限速（字节/秒）。≤ 0 表示不限速。
    ///   - capacityBytes: 桶容量（允许的突发字节数）。默认取 1 秒的速率，
    ///     最少 64 KiB（避免低速时桶太小导致请求永远超过容量）。
    ///   - initialTokens: 初始令牌数。默认 **0**（不送免费突发）。
    ///   - now: 当前时刻。
    public init(
        rateBytesPerSecond: Double,
        capacityBytes: Double? = nil,
        initialTokens: Double? = nil,
        now: Date = Date()
    ) {
        self.rateBytesPerSecond = max(0, rateBytesPerSecond)
        let capacity = capacityBytes ?? max(rateBytesPerSecond, 64 * 1024)
        self.capacity = max(capacity, 64 * 1024)
        self.tokens = min(max(initialTokens ?? 0, 0), self.capacity)
        self.lastRefill = now
    }

    /// 是否不限速。
    public var isUnlimited: Bool { rateBytesPerSecond <= 0 }

    /// 补充令牌（按经过的时间）。
    ///
    /// - Parameter now: 当前时刻。
    public mutating func refill(now: Date = Date()) {
        guard !isUnlimited else { return }
        let elapsed = now.timeIntervalSince(lastRefill)
        guard elapsed > 0 else { return }
        tokens = min(capacity, tokens + elapsed * rateBytesPerSecond)
        lastRefill = now
    }

    /// 尝试消费指定字节数的令牌（**不自动补充**）。
    ///
    /// - Parameter bytes: 需要的字节数。
    /// - Returns: 是否足够（不足时返回 false，调用方需等待）。
    public mutating func tryConsume(_ bytes: Int64) -> Bool {
        guard !isUnlimited else { return true }
        guard Double(bytes) <= capacity else {
            // 单次请求超过桶容量 → 直接放行（否则会死锁）。
            // 注意：此处**不能**把 tokens 置 0 后再由 consume 扣减，
            // 那会让 tokens 变成负数，导致后续所有请求都需等待。
            return true
        }
        return tokens >= Double(bytes)
    }

    /// 消费令牌（不足则返回 false，不等待）。
    ///
    /// - Parameters:
    ///   - bytes: 需要的字节数。
    ///   - now: 当前时刻（用于补充令牌）。
    /// - Returns: 是否消费成功。
    public mutating func consume(_ bytes: Int64, now: Date = Date()) -> Bool {
        guard !isUnlimited else { return true }
        refill(now: now)
        guard Double(bytes) <= capacity else {
            // 单次请求超过桶容量：直接放行，不扣减令牌（避免 tokens 变负）。
            return true
        }
        guard tokens >= Double(bytes) else { return false }
        tokens -= Double(bytes)
        return true
    }

    /// 计算需要等待多少秒才能有足够令牌。
    ///
    /// - Parameter bytes: 需要的字节数。
    /// - Returns: 等待秒数（已有足够令牌时返回 0）。
    public func waitTime(for bytes: Int64) -> TimeInterval {
        guard !isUnlimited else { return 0 }
        let deficit = Double(bytes) - tokens
        guard deficit > 0 else { return 0 }
        return deficit / rateBytesPerSecond
    }

    /// 当前可用令牌数。
    public var availableTokens: Double {
        guard !isUnlimited else { return .greatestFiniteMagnitude }
        return tokens
    }
}
