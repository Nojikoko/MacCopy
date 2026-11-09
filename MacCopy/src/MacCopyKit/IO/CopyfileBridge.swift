import Foundation
import Darwin

/// `copyfile` / `fcopyfile` Swift 封装。
///
/// 架构 §8.4 坑位（全部已实测确认，见 docs/ENV-FS-CONSTRAINTS-CORRECTED.md）：
/// - `copyfile_flags_t` 是 `UInt32`，`COPYFILE_*` 常量是 `Int32` → **必须显式 `UInt32(...)`**
/// - `copyfile_state_set` 第三参是 `UnsafeRawPointer`，不是 `Int32`
/// - `copyfile_state_get` 第三参是 `UnsafeMutablePointer<Int32>`
/// - **`fcopyfile` 的路径参数是 fd**（`Int32`），不是 `String` 路径
/// - `fcopyfile` 是纯 fd 通道，**不经过路径解析**，天然绕开 PATH_MAX(1024)
///
/// 实测补充：
/// - `copyfile(DATA|CLONE)` 在 **dst 已存在** 时失败（EEXIST），需回退到 `DATA`
/// - `copyfile(DATA)` 可覆盖已存在的 dst
public enum CopyfileBridge {
    /// 通过 fd 通道复制（天然支持长路径）。
    ///
    /// - Parameters:
    ///   - sourceFD: 源 fd。
    ///   - destinationFD: 目标 fd。
    ///   - attemptClone: 是否尝试 APFS CoW 克隆。
    /// - Returns: 是否真的发生了克隆。
    /// - Throws: `MacCopyError.cloneFailed`（调用方应回退到流式路径）。
    public static func copyWithClone(
        sourceFD: Int32,
        destinationFD: Int32,
        attemptClone: Bool
    ) throws -> Bool {
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }

        var src = sourceFD
        var dst = destinationFD
        _ = withUnsafeMutablePointer(to: &src) { pointer in
            copyfile_state_set(state, UInt32(COPYFILE_STATE_SRC_FD), UnsafeRawPointer(pointer))
        }
        _ = withUnsafeMutablePointer(to: &dst) { pointer in
            copyfile_state_set(state, UInt32(COPYFILE_STATE_DST_FD), UnsafeRawPointer(pointer))
        }

        var flags = UInt32(COPYFILE_DATA)
        if attemptClone {
            flags |= UInt32(COPYFILE_CLONE)
        }

        let (rc, code) = Syscall.call {
            fcopyfile(sourceFD, destinationFD, state, flags)
        }
        guard rc == 0 else {
            throw MacCopyError.cloneFailed(
                path: "",
                underlying: "errno=\(code) \(Syscall.describe(code))"
            )
        }

        // 检测是否真的克隆了（不能只看返回值）。
        //
        // ⚠️ `man 3 copyfile`：`COPYFILE_STATE_WAS_CLONED` 的 dst 是 **`bool*`（1 字节）**，
        // 不是 `Int32*`。用 4 字节 `Int32` 接收时只有低字节被写入；若初值非 0
        // （如 -1），高位残留会让 `== 1` 永远为 false。这里用 `UInt8`（= Darwin 的
        // `bool` 宽度）并初始化为 0，消除未定义行为边缘。架构 §5.2 / AD-13 实测结论。
        var wasCloned: UInt8 = 0
        copyfile_state_get(state, UInt32(COPYFILE_STATE_WAS_CLONED), &wasCloned)
        return wasCloned == 1
    }

    /// 通过路径复制（用于 `.partial` → 正式文件的「提交」步骤）。
    ///
    /// 实测约束：`rename` 不可用，所以提交用 copyfile。
    /// 但 `copyfile(DATA|CLONE)` 在 **dst 已存在** 时会失败（EEXIST），
    /// 因此这里**先试 CLONE，失败自动回退到 DATA**（DATA 可覆盖已存在的 dst）。
    ///
    /// - Parameters:
    ///   - sourcePath: 源路径。
    ///   - destinationPath: 目标路径。
    ///   - attemptClone: 是否尝试克隆。
    /// - Returns: 是否发生了克隆。
    /// - Throws: `MacCopyError`。
    public static func commit(
        from sourcePath: String,
        to destinationPath: String,
        attemptClone: Bool = true
    ) throws -> Bool {
        // 第一步：尝试 CLONE（dst 不存在时是 CoW，几乎零成本）。
        if attemptClone {
            let state = copyfile_state_alloc()
            defer { copyfile_state_free(state) }
            let flags = UInt32(COPYFILE_DATA) | UInt32(COPYFILE_CLONE)
            let (rc, code) = Syscall.call {
                copyfile(sourcePath, destinationPath, state, flags)
            }
            if rc == 0 {
                // `bool*`（1 字节）而非 `Int32*`，理由同 copyWithClone。
                var wasCloned: UInt8 = 0
                copyfile_state_get(state, UInt32(COPYFILE_STATE_WAS_CLONED), &wasCloned)
                return wasCloned == 1
            }
            // dst 已存在时 CLONE 会 EEXIST(17) → 回退到 DATA（可覆盖）。
            Log.io.info("copyfile CLONE 失败，回退 DATA errno=\(code)")
        }

        // 第二步：回退 DATA。
        //
        // **关键**：必须用**全新的 state**（或 nil）。
        // 实测：CLONE 失败后复用同一个 state 会返回 EINVAL(22) —— state 被污染了。
        // 见 docs/ENV-FS-CONSTRAINTS.md v3 §3.1 与本文件的实测记录。
        let (rc, code) = Syscall.call {
            copyfile(sourcePath, destinationPath, nil, UInt32(COPYFILE_DATA))
        }
        guard rc == 0 else {
            throw MacCopyError.unknown(
                underlying: "提交到「\(destinationPath)」失败：errno=\(code) \(Syscall.describe(code))"
            )
        }
        return false
    }

    /// 通过 fd 通道复制数据（不含克隆，用于已知目标可覆盖的场景）。
    ///
    /// - Parameters:
    ///   - sourceFD: 源 fd。
    ///   - destinationFD: 目标 fd。
    /// - Throws: `MacCopyError`。
    public static func copyData(sourceFD: Int32, destinationFD: Int32) throws {
        let (rc, code) = Syscall.call {
            fcopyfile(sourceFD, destinationFD, nil, UInt32(COPYFILE_DATA))
        }
        guard rc == 0 else {
            throw MacCopyError.unknown(
                underlying: "fd 通道复制失败：errno=\(code) \(Syscall.describe(code))"
            )
        }
    }
}
