import Foundation
import Darwin

/// APFS 克隆路径实现（`copyfile` + `COPYFILE_CLONE`，fd 通道）。
///
/// 架构 §4.3 关键约束：**克隆路径没有 tee**（数据不流经用户态），
/// 所以克隆成功后必须**回读源**算摘要。
/// 若源不可寻址 → 无法回读 → **不能使用克隆路径**，必须走流式 tee。
public struct CloneCopier: Sendable {
    /// 构造克隆复制器。
    public init() {}

    /// 克隆结果。
    public struct Result: Sendable {
        /// 是否真的发生了克隆（由 `WAS_CLONED` 判定，不能只看返回值）。
        public let wasCloned: Bool
        /// 传输的字节数（逻辑大小）。
        public let bytesTransferred: Int64

        /// 构造结果。
        public init(wasCloned: Bool, bytesTransferred: Int64) {
            self.wasCloned = wasCloned
            self.bytesTransferred = bytesTransferred
        }
    }

    /// 通过 fd 通道执行克隆复制。
    ///
    /// - Parameters:
    ///   - sourceFD: 源 fd。
    ///   - destinationFD: 目标 fd。
    ///   - attemptClone: 是否尝试 CoW 克隆。
    ///   - logicalSize: 源的逻辑大小（用于报告传输字节数）。
    /// - Returns: 复制结果。
    /// - Throws: `MacCopyError.cloneFailed`（调用方应回退到流式路径，**不计为失败**）。
    public func copy(
        sourceFD: Int32,
        destinationFD: Int32,
        attemptClone: Bool,
        logicalSize: Int64
    ) throws -> Result {
        let wasCloned = try CopyfileBridge.copyWithClone(
            sourceFD: sourceFD,
            destinationFD: destinationFD,
            attemptClone: attemptClone
        )
        return Result(wasCloned: wasCloned, bytesTransferred: logicalSize)
    }

    /// 判断是否可以走克隆路径。
    ///
    /// 架构 §4.3 + AD-08：克隆必须同时满足
    /// 1. 允许克隆（`options.enableClone`）
    /// 2. 同卷
    /// 3. 目标卷是 APFS
    /// 4. **源可寻址**（否则无法回读算摘要）
    ///
    /// - Parameters:
    ///   - sourcePath: 源路径。
    ///   - destinationDirectory: 目标目录。
    ///   - enableClone: 用户是否启用克隆。
    ///   - sourceIsSeekable: 源是否可寻址。
    /// - Returns: 是否可以走克隆路径。
    public static func canUseClone(
        sourcePath: String,
        destinationDirectory: String,
        enableClone: Bool,
        sourceIsSeekable: Bool
    ) -> Bool {
        guard enableClone else { return false }
        // AD-08：不可寻址源一律不走克隆。
        guard sourceIsSeekable else { return false }
        guard VolumeInspector.sameVolume(sourcePath, destinationDirectory) else { return false }
        guard VolumeInspector.fileSystemType(at: destinationDirectory) == "apfs" else { return false }
        return true
    }
}
