import Foundation
import Darwin

/// 稀疏文件空洞探测（`SEEK_HOLE` / `SEEK_DATA`）。
///
/// 实测确认（docs/ENV-FS-CONSTRAINTS-CORRECTED.md）：
/// - `open(O_CREAT|O_RDWR)` **可用** → 稀疏文件可完整创建与保留
/// - `ftruncate` 可用 → 空洞可构造
/// - `SEEK_HOLE` / `SEEK_DATA` 可用 → 空洞区间可精确探测
public struct SparseProbe: Sendable {
    /// 一个空洞区间。
    public struct Hole: Sendable, Equatable {
        /// 空洞起始偏移。
        public let offset: Int64
        /// 空洞长度。
        public let length: Int64

        /// 构造空洞区间。
        public init(offset: Int64, length: Int64) {
            self.offset = offset
            self.length = length
        }

        /// 空洞结束偏移（不含）。
        public var end: Int64 { offset + length }
    }

    /// 构造探测器。
    public init() {}

    /// 探测文件中的空洞区间。
    ///
    /// 算法（QA BUG-03 修正）：维护 `cursor` = **上一段数据的终点**。
    /// - `SEEK_DATA(cursor)` 返回下一段数据的起点 `dataOffset`
    ///   → **`[cursor, dataOffset)` 才是空洞**（此前误把
    ///   `[dataOffset, holeOffset)` 当空洞，那其实是数据段，会导致复制时跳过真实数据、
    ///   把空洞写 0，属数据损坏）
    /// - `SEEK_HOLE(dataOffset)` 返回该数据段的终点 `holeOffset`
    ///   → 令 `cursor = holeOffset`，继续找下一段数据
    /// - `SEEK_DATA` 返回 `ENXIO` 表示后面再无数据
    ///   → 补尾洞 `[cursor, size)`
    ///
    /// - Parameters:
    ///   - fd: 文件描述符。
    ///   - size: 文件逻辑大小。
    /// - Returns: 空洞区间列表（按偏移升序）。
    public func holes(in fd: Int32, size: Int64) -> [Hole] {
        guard size > 0 else { return [] }

        var holes = [Hole]()
        var cursor: Int64 = 0

        while cursor < size {
            // ① 从 cursor 找下一段数据的起点。
            Syscall.resetErrno()
            let dataOffset = lseek(fd, cursor, SEEK_DATA)
            if dataOffset < 0 {
                let code = Syscall.currentErrno()
                if code == ENXIO {
                    // 后面全是空洞。
                    holes.append(Hole(offset: cursor, length: size - cursor))
                }
                break
            }
            guard dataOffset < size else { break }

            // ② cursor → dataOffset 之间是空洞。
            if dataOffset > cursor {
                holes.append(Hole(offset: cursor, length: dataOffset - cursor))
            }

            // ③ 从数据起点找该数据段的终点（即下一个空洞起点）。
            Syscall.resetErrno()
            let holeOffset = lseek(fd, dataOffset, SEEK_HOLE)
            if holeOffset < 0 {
                // 无法探测：剩余视为全数据，不再追加空洞。
                cursor = size
                break
            }
            cursor = min(holeOffset, size)
        }

        return holes
    }

    /// 探测路径中的空洞区间。
    ///
    /// - Parameters:
    ///   - path: 文件路径。
    ///   - size: 文件逻辑大小。
    /// - Returns: 空洞区间列表。
    public func holes(at path: String, size: Int64) -> [Hole] {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        return holes(in: fd, size: size)
    }

    /// 计算空洞总字节数。
    ///
    /// - Parameter holes: 空洞区间列表。
    /// - Returns: 总字节数。
    public static func totalHoleBytes(_ holes: [Hole]) -> Int64 {
        holes.reduce(0) { $0 + $1.length }
    }
}
