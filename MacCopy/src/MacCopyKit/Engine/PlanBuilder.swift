import Foundation

/// 传输计划：源枚举 → 分批的 `FileEntry` 计划。
///
/// 架构 Q-A8：10 万文件场景内存占用 ≤ 300 MB。
/// 做法：**分批产出**，不把全量条目驻留内存；每批用完即释放。
/// `FileEntry` 是 struct 紧凑布局（比 class 省堆分配）。
public struct PlanBuilder: Sendable {
    /// 每批条目数。
    public static let batchSize = 512

    /// 一个批次。
    public struct Batch: Sendable {
        /// 批次内的条目。
        public let entries: [FileEntry]
        /// 批次的总字节数。
        public let totalBytes: Int64
        /// 批次的文件数（不含目录）。
        public let fileCount: Int

        /// 构造批次。
        public init(entries: [FileEntry], totalBytes: Int64, fileCount: Int) {
            self.entries = entries
            self.totalBytes = totalBytes
            self.fileCount = fileCount
        }
    }

    /// 整个计划的统计。
    public struct Statistics: Sendable {
        /// 总字节数。
        public let totalBytes: Int64
        /// 总文件数（不含目录）。
        public let totalFiles: Int
        /// 总目录数。
        public let totalDirectories: Int
        /// 稀疏文件数。
        public let sparseFiles: Int
        /// 符号链接数。
        public let symbolicLinks: Int

        /// 构造统计。
        public init(
            totalBytes: Int64,
            totalFiles: Int,
            totalDirectories: Int,
            sparseFiles: Int,
            symbolicLinks: Int
        ) {
            self.totalBytes = totalBytes
            self.totalFiles = totalFiles
            self.totalDirectories = totalDirectories
            self.sparseFiles = sparseFiles
            self.symbolicLinks = symbolicLinks
        }
    }

    /// 构造计划构建器。
    public init() {}

    /// 构建计划（分批产出）。
    ///
    /// - Parameters:
    ///   - sourceRoots: 源根路径列表。
    ///   - destinationRoot: 目标根路径。
    ///   - options: 枚举选项。
    /// - Returns: 批次异步序列。
    public func build(
        sourceRoots: [String],
        destinationRoot: String,
        options: FileEnumerator.Options = .default
    ) -> AsyncThrowingStream<Batch, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let enumerator = FileEnumerator()
                    var batch: [FileEntry] = []
                    var batchBytes: Int64 = 0
                    var batchFiles = 0

                    for sourceRoot in sourceRoots {
                        for try await entry in enumerator.enumerate(
                            sourceRoot: sourceRoot,
                            destinationRoot: destinationRoot,
                            options: options
                        ) {
                            if Task.isCancelled { return }
                            batch.append(entry)
                            if !entry.isDirectory {
                                batchBytes += entry.size
                                batchFiles += 1
                            }
                            if batch.count >= Self.batchSize {
                                continuation.yield(
                                    Batch(
                                        entries: batch,
                                        totalBytes: batchBytes,
                                        fileCount: batchFiles
                                    )
                                )
                                // 批次已交付，释放引用（Q-A8 内存控制）。
                                batch.removeAll(keepingCapacity: true)
                                batchBytes = 0
                                batchFiles = 0
                            }
                        }
                    }

                    if !batch.isEmpty {
                        continuation.yield(
                            Batch(entries: batch, totalBytes: batchBytes, fileCount: batchFiles)
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 统计整个计划的规模（需要完整遍历一遍）。
    ///
    /// - Parameters:
    ///   - sourceRoots: 源根路径列表。
    ///   - destinationRoot: 目标根路径。
    ///   - options: 枚举选项。
    /// - Returns: 统计信息。
    public func statistics(
        sourceRoots: [String],
        destinationRoot: String,
        options: FileEnumerator.Options = .default
    ) async throws -> Statistics {
        var totalBytes: Int64 = 0
        var totalFiles = 0
        var totalDirectories = 0
        var sparseFiles = 0
        var symbolicLinks = 0

        let enumerator = FileEnumerator()
        for sourceRoot in sourceRoots {
            for try await entry in enumerator.enumerate(
                sourceRoot: sourceRoot,
                destinationRoot: destinationRoot,
                options: options
            ) {
                if entry.isDirectory {
                    totalDirectories += 1
                } else {
                    totalFiles += 1
                    totalBytes += entry.size
                    if entry.isSparse { sparseFiles += 1 }
                    if entry.isSymbolicLink { symbolicLinks += 1 }
                }
            }
        }

        return Statistics(
            totalBytes: totalBytes,
            totalFiles: totalFiles,
            totalDirectories: totalDirectories,
            sparseFiles: sparseFiles,
            symbolicLinks: symbolicLinks
        )
    }
}
