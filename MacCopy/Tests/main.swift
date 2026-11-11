import Foundation
import MacCopyKit

/// 测试入口。
///
/// 自建测试运行器（不用 XCTest，原因见 `Runner.swift` 顶部注释）。
@main
struct TestMain {
    static func main() async {
        ChecksumTests.register()
        ModelTests.register()
        ThroughputTests.register()
        IOTests.register()
        EngineTests.register()
        SourceRootTests.register()
        ChecksumFileTests.register()
        LanguageResolverTests.register()
        LocalizationFallbackTests.register()
        SettingsMigrationTests.register()
        LanguageSwitchTests.register()
        TranslationIntegrityTests.register()
        QABugRegressionTests.register()
        DestinationPickerTests.register()
        let exitCode = await TestRunner.runAll()
        exit(exitCode)
    }
}
