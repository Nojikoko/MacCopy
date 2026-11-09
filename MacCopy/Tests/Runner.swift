import Foundation

/// 自建极简测试运行器。
///
/// 为什么不用 XCTest：XCTest 需要 `xcodebuild` 的 test bundle 机制，
/// 而本机的 SwiftPM manifest 编译环节不可用（见 BUILD-ENV-NOTES §2），
/// 因此自建一个轻量运行器，用 `swiftc` 直接编译 + 运行。
///
/// 用法：
/// ```swift
/// TestRunner.register("CRC32 标准向量") {
///     TestRunner.assertEqual(CRC32Hasher.hexDigest(of: Array("123456789".utf8)), "cbf43926")
/// }
/// ```
///
/// 并发说明：`@MainActor` 隔离全部可变全局状态，满足 Swift 6 严格并发检查。
@MainActor
public enum TestRunner {
    /// 单个测试用例。
    public struct TestCase {
        /// 用例名称。
        public let name: String
        /// 用例体。
        public let body: () async throws -> Void
    }

    /// 全部注册用例。
    private static var cases: [TestCase] = []

    /// 失败计数。
    private static var failureCount = 0
    /// 通过计数。
    private static var passCount = 0

    /// 注册一个测试用例。
    ///
    /// - Parameters:
    ///   - name: 用例名称。
    ///   - body: 用例体。抛错或断言失败即视为失败。
    public static func register(_ name: String, _ body: @escaping () async throws -> Void) {
        cases.append(TestCase(name: name, body: body))
    }

    /// 断言两个值相等。
    ///
    /// - Parameters:
    ///   - actual: 实际值。
    ///   - expected: 期望值。
    ///   - message: 失败时的附加说明。
    public static func assertEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ message: String = ""
    ) {
        if actual != expected {
            fail("期望 \(expected)，实际 \(actual)\(message.isEmpty ? "" : " —— \(message)")")
        }
    }

    /// 断言条件为真。
    ///
    /// - Parameters:
    ///   - condition: 条件。
    ///   - message: 失败时的说明。
    public static func assertTrue(_ condition: Bool, _ message: String = "") {
        if !condition {
            fail("断言为假\(message.isEmpty ? "" : " —— \(message)")")
        }
    }

    /// 断言条件为假。
    ///
    /// - Parameters:
    ///   - condition: 条件。
    ///   - message: 失败时的说明。
    public static func assertFalse(_ condition: Bool, _ message: String = "") {
        if condition {
            fail("断言为真\(message.isEmpty ? "" : " —— \(message)")")
        }
    }

    /// 断言值非 nil。
    ///
    /// - Parameter value: 可选值。
    /// - Returns: 解包后的值。
    @discardableResult
    public static func assertNotNil<T>(_ value: T?, _ message: String = "") -> T? {
        if value == nil {
            fail("期望非 nil\(message.isEmpty ? "" : " —— \(message)")")
        }
        return value
    }

    /// 记录一次失败。
    ///
    /// - Parameter message: 失败原因。
    public static func fail(_ message: String) {
        failureCount += 1
        let file = currentFile()
        let line = currentLine()
        print("  ✗ FAIL  \(message)")
        print("        at \(file):\(line)")
    }

    /// 运行全部用例并输出汇总。
    ///
    /// - Returns: 进程退出码（0 表示全部通过）。
    public static func runAll() async -> Int32 {
        print("=== MacCopy 测试运行器 ===")
        print("共 \(cases.count) 个用例\n")

        for testCase in cases {
            let before = failureCount
            do {
                try await testCase.body()
            } catch {
                fail("抛出异常：\(error)")
            }
            if failureCount == before {
                passCount += 1
                print("  ✓ PASS  \(testCase.name)")
            }
        }

        print("\n=== 汇总 ===")
        print("通过：\(passCount)")
        print("失败：\(failureCount)")
        print("总计：\(cases.count)")
        if failureCount == 0 {
            print("结果：全部通过 ✅")
            return 0
        }
        print("结果：存在失败 ❌")
        return 1
    }

    /// 当前源码文件名（从调用栈获取）。
    private static func currentFile() -> String {
        let stack = Thread.callStackSymbols
        // 栈帧形如：<file>.<func> ... +<offset>
        for frame in stack.dropFirst() {
            let parts = frame.split(separator: " ").first.map(String.init) ?? frame
            if parts.hasPrefix("/") || parts.contains(".swift") {
                return parts
            }
        }
        return "<unknown>"
    }

    /// 当前源码行号。
    private static func currentLine() -> Int {
        let stack = Thread.callStackSymbols
        for frame in stack.dropFirst() {
            let parts = frame.split(separator: " ").first.map(String.init) ?? frame
            if parts.contains(".swift") {
                // 形如 "file.swift:123"
                if let colonIndex = parts.lastIndex(of: ":") {
                    let number = parts[parts.index(after: colonIndex)...]
                    if let line = Int(number) { return line }
                }
            }
        }
        return 0
    }
}
