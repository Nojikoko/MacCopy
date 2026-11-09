import Foundation
import Darwin

/// fd 生命周期封装。
///
/// 架构 §8.2：`FileDescriptor` 用 `@unchecked Sendable` + 内部锁
/// （fd 本身是线程安全的，但 close 时机需保护）。
///
/// 架构 §8.4 坑位：Darwin 的 `open()` 返回**非可选 Int32**，不能 `!` 解包。
public final class FileDescriptor: @unchecked Sendable {
    /// 底层文件描述符。
    public let rawValue: Int32

    /// 是否由本对象负责关闭。
    private let ownsHandle: Bool

    /// 保护关闭时机的锁。
    private let lock = NSLock()

    /// 是否已关闭。
    private var closed = false

    /// 构造 fd 包装。
    ///
    /// - Parameters:
    ///   - rawValue: 底层 fd。负数表示无效。
    ///   - ownsHandle: 是否由本对象负责关闭（默认 true）。
    public init(rawValue: Int32, ownsHandle: Bool = true) {
        self.rawValue = rawValue
        self.ownsHandle = ownsHandle
    }

    /// fd 是否有效。
    public var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return rawValue >= 0 && !closed
    }

    /// 显式关闭（重复调用安全）。
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, ownsHandle, rawValue >= 0 else {
            closed = true
            return
        }
        closed = true
        _ = Darwin.close(rawValue)
    }

    deinit {
        close()
    }

    /// 作用域式使用（自动关闭）。
    ///
    /// - Parameter body: 使用 fd 的闭包。
    /// - Returns: 闭包返回值。
    public func withHandle<T>(_ body: (Int32) throws -> T) throws -> T {
        guard isValid else { throw MacCopyError.unknown(underlying: "文件描述符已关闭") }
        return try body(rawValue)
    }
}

/// POSIX 系统调用的辅助工具。
///
/// 铁律（架构 §8.3）：**errno 必须在失败点立即读取**，
/// 且**调用前必须重置 errno** —— 成功的系统调用不会清零 `errno`，
/// 不重置就会读到上一次失败留下的陈旧值（这是本机实测踩过的坑）。
public enum Syscall {
    /// 重置 errno（必须在系统调用**之前**调用）。
    @inline(__always)
    public static func resetErrno() {
        errno = 0
    }

    /// 读取 errno（必须在系统调用**之后**立即调用）。
    @inline(__always)
    public static func currentErrno() -> Int32 {
        errno
    }

    /// 执行一次可能失败的系统调用，返回 (结果码, errno)。
    ///
    /// - Parameter body: 系统调用（必须返回 `Int32`）。
    /// - Returns: 结果码与 errno 元组。
    @inline(__always)
    public static func call(_ body: () -> Int32) -> (result: Int32, errno: Int32) {
        resetErrno()
        let result = body()
        return (result, currentErrno())
    }

    /// 把 errno 转成可读描述。
    ///
    /// - Parameter code: errno 值。
    /// - Returns: `strerror` 文本。
    public static func describe(_ code: Int32) -> String {
        guard code != 0 else { return "" }
        return String(cString: strerror(code))
    }
}
