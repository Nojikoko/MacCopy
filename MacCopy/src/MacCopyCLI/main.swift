import Foundation
import MacCopyKit

/// MacCopy CLI 入口（Pro 预留 CLI，v1 仅 `--version` / `--help` + 引擎冒烟测试）。
///
/// 架构 §3.2.5：本 CLI 与 GUI 共用同一引擎，无逻辑分叉。
/// T01 阶段只做骨架 + 跨模块集成验证；真正的复制命令在 T04 引擎完成后接入。
@main
struct MacCopyCLIMain {
    /// 应用版本号。
    static let version = "0.1.0"

    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())

        if arguments.contains("--version") || arguments.contains("-v") {
            print("MacCopy \(version)")
            exit(0)
        }

        if arguments.isEmpty || arguments.contains("--help") || arguments.contains("-h") {
            printUsage()
            exit(arguments.isEmpty ? 1 : 0)
        }

        // 冒烟测试：验证 MacCopyKit 的核心能力可用（Feature Flag + 校验算法）。
        let registry = ChecksumRegistry.shared
        let algorithms = registry.available.map(\.displayName).joined(separator: ", ")
        print("MacCopy \(version)")
        print("可用校验算法：\(algorithms)")
        print("Pro 功能：\(FeatureFlags.proFeaturesEnabled ? "已启用" : "未启用")")
        print("有效线程数上限：\(FeatureFlags.freeTierMaxThreads)")
        exit(0)
    }

    /// 打印用法。
    static func printUsage() {
        print("""
            MacCopy \(version) — macOS 原生文件复制管理工具（命令行版）

            用法：
              macopy --version     显示版本号
              macopy --help        显示本帮助

            完整复制功能将在后续版本提供（当前为 Pro 预留骨架）。
            """)
    }
}
