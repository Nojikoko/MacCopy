import Foundation
import Darwin

/// 流式复制（read/write + tee 哈希 + 断点续传）。
///
/// 架构 §5 要点：
/// - `read`/`write` **必须处理短读短写**（`written != n` 要循环重试剩余部分）
/// - `hasher.update` 用 `UnsafeRawBufferPointer(start:count:)` 零拷贝
/// - `progressReportInterval` = 4 MiB（避免高频 actor 调用）
/// - 源不可 seek 时（`lseek` 失败）：`startOffset` 必须为 0，且**断点续传不可用**
public struct StreamCopier: Sendable {
    /// 进度回报间隔（字节）。
    public static let progressReportInterval: Int64 = 4 * 1024 * 1024

    /// 复制结果。
    public struct Result: Sendable {
        /// 实际传输的字节数（不含断点续传已传部分）。
        public let transferredBytes: Int64
        /// 起始偏移（断点续传时 > 0）。
        public let startOffset: Int64
        /// 源是否可寻址。
        public let sourceIsSeekable: Bool

        /// 构造结果。
        public init(transferredBytes: Int64, startOffset: Int64, sourceIsSeekable: Bool) {
            self.transferredBytes = transferredBytes
            self.startOffset = startOffset
            self.sourceIsSeekable = sourceIsSeekable
        }
    }

    /// 构造流式复制器。
    public init() {}

    /// 执行流式复制。
    ///
    /// - Parameters:
    ///   - sourceFD: 源 fd（必须已打开）。
    ///   - destinationFD: 目标 fd（必须已打开）。
    ///   - startOffset: 起始偏移（断点续传）。
    ///   - bufferSize: 读写缓冲大小。
    ///   - hasher: 多算法哈希器（tee 模式）。
    ///   - bandwidthLimitBytesPerSecond: 限速（字节/秒）。nil 或 ≤ 0 表示不限速。
    ///   - onProgress: 进度回调（每 4 MiB 一次 + 收尾一次）。
    ///     **参数是「自上次回调以来新增的字节数」（增量），不是累计值**。
    ///     所有回调的参数之和恒等于 `Result.transferredBytes`。
    ///     调用方（CopyEngine.addTransferred）按增量累加，两边口径必须一致。
    /// - Returns: 复制结果。
    /// - Throws: `MacCopyError`。
    public func copy(
        sourceFD: Int32,
        destinationFD: Int32,
        startOffset: Int64,
        bufferSize: Int,
        hasher: inout MultiHasher,
        bandwidthLimitBytesPerSecond: Double? = nil,
        onProgress: @Sendable @escaping (Int64) async -> Void
    ) async throws -> Result {
        var effectiveStart = startOffset
        var sourceIsSeekable = true

        if startOffset > 0 {
            // 断点续传：把源定位到 startOffset。
            Syscall.resetErrno()
            let seekResult = lseek(sourceFD, startOffset, SEEK_SET)
            if seekResult < 0 {
                // 源不可寻址 → 断点续传不可用，退回从头复制。
                let code = Syscall.currentErrno()
                Log.io.error("lseek 失败，断点续传不可用 errno=\(code)")
                effectiveStart = 0
                sourceIsSeekable = false
            }
        } else {
            // 探测源是否可寻址。
            Syscall.resetErrno()
            let current = lseek(sourceFD, 0, SEEK_CUR)
            if current < 0 {
                sourceIsSeekable = false
            }
        }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 64)
        defer { buffer.deallocate() }

        // 限速令牌桶（PRD P1-06）。nil / ≤ 0 = 不限速。
        //
        // ⚠️ 桶容量必须 ≥ 单次 `read()` 的最大字节数（即 `bufferSize`）。
        // `TokenBucket` 对「单次请求 > capacity」会直接放行以防死锁；
        // 默认 bufferSize 是 8 MiB，若 capacity 只有「1 秒速率」(1 MiB)，
        // 一次读取 4 MiB 就会被整体放行 → 限速**完全失效**且无任何报错。
        // 显式把 capacity 设为 bufferSize，保证每次请求都真正经过令牌桶。
        var bucket = TokenBucket(
            rateBytesPerSecond: bandwidthLimitBytesPerSecond ?? 0,
            capacityBytes: Double(bufferSize)
        )

        var total: Int64 = 0
        var lastReport: Int64 = 0

        while true {
            if Task.isCancelled {
                throw MacCopyError.cancelled
            }

            // 读。
            let readCount = buffer.withMemoryRebound(to: UInt8.self, capacity: bufferSize) { pointer in
                Syscall.resetErrno()
                return read(sourceFD, pointer, bufferSize)
            }
            if readCount < 0 {
                let code = Syscall.currentErrno()
                if code == EINTR { continue }
                throw MacCopyError.sourceUnreadable(
                    path: "",
                    underlying: "errno=\(code) \(Syscall.describe(code))"
                )
            }
            if readCount == 0 { break }
            // 限速：写入前向令牌桶申请 readCount 字节。
            // 等待分片（单次 ≤ 50ms），保证进度回调与取消能及时响应。
            if !bucket.isUnlimited {
                while !bucket.consume(Int64(readCount)) {
                    if Task.isCancelled { throw MacCopyError.cancelled }
                    let wait = bucket.waitTime(for: Int64(readCount))
                    let sleepSeconds = min(max(wait, 0.001), 0.05)
                    try? await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
                }
            }
            // 写：**必须循环处理短写**。
            var written: Int = 0
            while written < readCount {
                let writeCount = buffer.advanced(by: written).withMemoryRebound(
                    to: UInt8.self,
                    capacity: readCount - written
                ) { pointer in
                    Syscall.resetErrno()
                    return write(destinationFD, pointer, readCount - written)
                }
                if writeCount < 0 {
                    let code = Syscall.currentErrno()
                    if code == EINTR { continue }
                    throw MacCopyError.destinationUnwritable(path: "")
                }
                if writeCount == 0 {
                    throw MacCopyError.destinationUnwritable(path: "")
                }
                written += writeCount
            }

            // tee：同一次读取既写盘又算哈希。
            hasher.update(buffer: UnsafeRawBufferPointer(start: buffer, count: readCount))

            total += Int64(readCount)

            // 进度回报（每 4 MiB）一律传**增量**，不是累计值。
            //
            // QA 第 2 轮缺陷 B：此前传累计 `total`，而 `CopyEngine.addTransferred`
            // 又把它当增量累加 → ≥4 MiB 文件时 transferredBytes 重复计数
            // （4 MiB 报 8 MiB、8 MiB 报 20 MiB），进度条 >100%、速度曲线失真。
            // 统一口径：本回调只负责「自上次回报以来新增的字节数」。
            if total - lastReport >= Self.progressReportInterval {
                let delta = total - lastReport
                lastReport = total
                await onProgress(delta)
            }
        }

        // 收尾：把不足 4 MiB 的剩余部分作为最后一个增量上报。
        // 不再重复传累计值（旧实现在循环外又调了一次 `onProgress(total)`）。
        let remaining = total - lastReport
        if remaining > 0 {
            await onProgress(remaining)
        }

        return Result(
            transferredBytes: total,
            startOffset: effectiveStart,
            sourceIsSeekable: sourceIsSeekable
        )
    }

    /// 计算目标文件应写入的偏移（断点续传用）。
    ///
    /// - Parameter fd: 目标 fd。
    /// - Returns: 当前文件大小（字节）。
    public static func currentSize(of fd: Int32) -> Int64 {
        Syscall.resetErrno()
        let result = lseek(fd, 0, SEEK_END)
        return result < 0 ? 0 : result
    }
}
