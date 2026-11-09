import Foundation

/// 速度采样环形缓冲（120 秒 @ 1 Hz）。
public struct SpeedSampler: Sendable {
    /// 一个采样点。
    public struct Sample: Sendable, Equatable {
        /// 采样时刻。
        public let time: Date
        /// 该时刻的累计已传输字节数。
        public let cumulativeBytes: Int64

        /// 构造采样点。
        public init(time: Date, cumulativeBytes: Int64) {
            self.time = time
            self.cumulativeBytes = cumulativeBytes
        }
    }

    /// 采样间隔（秒）。
    public static let sampleInterval: TimeInterval = 1
    /// 环形缓冲容量（秒）。
    public static let capacity = 120
    /// ETA 计算窗口（秒）—— PRD P0-03 ②要求用最近 10 秒吞吐外推。
    public static let etaWindow: TimeInterval = 10

    /// 采样点数组（环形）。
    private var samples: [Sample] = []
    /// 上次采样的累计字节数。
    private var lastBytes: Int64 = 0
    /// 上次采样时刻。
    private var lastTime: Date?

    /// 构造速度采样器。
    public init() {}

    /// 记录一次采样。
    ///
    /// - Parameters:
    ///   - bytes: 当前累计已传输字节数。
    ///   - now: 当前时刻。
    public mutating func sample(bytes: Int64, now: Date = Date()) {
        // QA BUG-04：`lastTime` / `lastBytes` 只能在**真正采样**后更新。
        // 原实现放在 `defer` 里，导致「跳过采样」的提前 return 也会推后时间基准：
        // 高频事件（每 0.2s）永远凑不满 1 秒 → 采样点恒为 1 → 速度恒 0、ETA 恒 nil。
        if let lastTime, now.timeIntervalSince(lastTime) < Self.sampleInterval {
            return
        }

        samples.append(Sample(time: now, cumulativeBytes: bytes))
        if samples.count > Self.capacity {
            samples.removeFirst(samples.count - Self.capacity)
        }
        lastBytes = bytes
        lastTime = now
    }

    /// 瞬时速度（最近 1 秒窗口，字节/秒）。
    public var instantaneous: Double {
        guard samples.count >= 2 else { return 0 }
        let last = samples[samples.count - 1]
        let previous = samples[samples.count - 2]
        let elapsed = last.time.timeIntervalSince(previous.time)
        guard elapsed > 0 else { return 0 }
        return Double(last.cumulativeBytes - previous.cumulativeBytes) / elapsed
    }

    /// 平均速度（全程，字节/秒）。
    public var average: Double {
        guard let first = samples.first, let last = samples.last, samples.count >= 2 else { return 0 }
        let elapsed = last.time.timeIntervalSince(first.time)
        guard elapsed > 0 else { return 0 }
        return Double(last.cumulativeBytes - first.cumulativeBytes) / elapsed
    }

    /// 最近窗口内的吞吐（用于 ETA 外推）。
    ///
    /// - Parameter window: 窗口秒数，默认 10 秒。
    /// - Returns: 字节/秒；数据不足时返回 0。
    public func throughput(inLast window: TimeInterval = SpeedSampler.etaWindow) -> Double {
        guard samples.count >= 2 else { return 0 }
        guard let last = samples.last else { return 0 }

        // 找到窗口内最早的采样点。
        let cutoff = last.time.addingTimeInterval(-window)
        let inWindow = samples.filter { $0.time >= cutoff }
        guard let first = inWindow.first, inWindow.count >= 2 else { return 0 }

        let elapsed = last.time.timeIntervalSince(first.time)
        guard elapsed > 0 else { return 0 }
        return Double(last.cumulativeBytes - first.cumulativeBytes) / elapsed
    }

    /// 预计剩余时间。
    ///
    /// - Parameter remainingBytes: 剩余字节数。
    /// - Returns: 剩余秒数；无法估算时返回 nil。
    public func eta(remainingBytes: Int64) -> TimeInterval? {
        guard remainingBytes > 0 else { return 0 }
        let speed = throughput()
        guard speed > 0 else { return nil }
        return Double(remainingBytes) / speed
    }

    /// 全部采样点（供 UI 画曲线）。
    public var allSamples: [Sample] { samples }
}
