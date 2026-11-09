import Foundation
import Darwin

/// 稀疏文件处理（PRD P0-12 / Q11）。
///
/// 实测确认（docs/ENV-FS-CONSTRAINTS-CORRECTED.md）：
/// `open(O_CREAT|O_RDWR)` + `ftruncate` **可用**，稀疏文件可完整保留。
public struct SparseHandler: Sendable {
    /// 稀疏处理结论。
    public struct Outcome: Sendable, Equatable {
        /// 是否保留了稀疏。
        public let preserved: Bool
        /// 空洞区间（未保留时为源文件的空洞列表）。
        public let holes: [SparseProbe.Hole]
        /// 说明（未保留时给用户看的提示）。
        public let note: String?

        /// 构造结论。
        public init(preserved: Bool, holes: [SparseProbe.Hole], note: String? = nil) {
            self.preserved = preserved
            self.holes = holes
            self.note = note
        }
    }

    /// 构造稀疏处理器。
    public init() {}

    /// 判断是否保留空洞。
    ///
    /// - Parameters:
    ///   - mode: 稀疏策略。
    ///   - destinationSupportsSparse: 目标文件系统是否支持稀疏。
    /// - Returns: 是否保留。
    public func shouldPreserve(
        mode: SparseMode,
        destinationSupportsSparse: Bool
    ) -> Bool {
        switch mode {
        case .automatic:
            return destinationSupportsSparse
        case .forceKeep:
            return true
        case .disabled:
            return false
        }
    }

    /// 探测源文件的空洞。
    ///
    /// - Parameters:
    ///   - fd: 源 fd。
    ///   - size: 源逻辑大小。
    /// - Returns: 空洞区间列表。
    public func probeHoles(fd: Int32, size: Int64) -> [SparseProbe.Hole] {
        SparseProbe().holes(in: fd, size: size)
    }

    /// 在目标文件上创建稀疏结构（`ftruncate` + 跳过空洞写入）。
    ///
    /// - Parameters:
    ///   - destinationFD: 目标 fd（必须以 `O_RDWR` 打开）。
    ///   - size: 目标逻辑大小。
    /// - Returns: 是否成功创建稀疏结构。
    public func createSparseStructure(destinationFD: Int32, size: Int64) -> Bool {
        Syscall.resetErrno()
        let result = ftruncate(destinationFD, size)
        if result != 0 {
            let code = Syscall.currentErrno()
            Log.io.error("ftruncate 失败，无法保留稀疏 errno=\(code)")
            return false
        }
        return true
    }

    /// 生成处理结论。
    ///
    /// - Parameters:
    ///   - mode: 稀疏策略。
    ///   - destinationSupportsSparse: 目标是否支持稀疏。
    ///   - holes: 检测到的空洞。
    ///   - creationSucceeded: 稀疏结构是否创建成功。
    /// - Returns: 处理结论。
    public func outcome(
        mode: SparseMode,
        destinationSupportsSparse: Bool,
        holes: [SparseProbe.Hole],
        creationSucceeded: Bool
    ) -> Outcome {
        let shouldPreserve = self.shouldPreserve(
            mode: mode,
            destinationSupportsSparse: destinationSupportsSparse
        )

        guard shouldPreserve, !holes.isEmpty else {
            let note: String? = holes.isEmpty
                ? nil
                : Localization.string(
                    "sparse.notPreserved.unsupported",
                    default: "未保留稀疏（目标文件系统不支持）"
                )
            return Outcome(preserved: false, holes: holes, note: note)
        }

        guard creationSucceeded else {
            return Outcome(
                preserved: false,
                holes: holes,
                note: Localization.string(
                    "sparse.notPreserved.writeFailed",
                    default: "未保留稀疏（目标环境不支持稀疏写入）"
                )
            )
        }

        return Outcome(preserved: true, holes: holes, note: nil)
    }
}
