import Foundation
import MacCopyKit

/// 设置迁移 / 向后兼容 / 恢复默认保留语言（PRD-I18N P0-08 / P0-09 / Q7）。
@MainActor
enum SettingsMigrationTests {
    /// 每次用独立 suite，避免污染 `.standard`。
    private static func freshDefaults() -> UserDefaults {
        let name = "com.maccopy.i18ntest.\(UUID().uuidString)"
        guard let d = UserDefaults(suiteName: name) else {
            fatalError("无法创建测试 UserDefaults")
        }
        d.removePersistentDomain(forName: name)
        return d
    }

    static func register() {
        TestRunner.register("设置迁移：新装（无任何键）→ 跟随系统 / manual 为 nil") {
            let d = freshDefaults()
            let s = SettingsStore(defaults: d).load()
            TestRunner.assertTrue(s.languageFollowsSystem)
            TestRunner.assertTrue(s.manualLanguageTag == nil)
            TestRunner.assertFalse(s.didMigrateFromV10)
        }

        TestRunner.register("设置迁移：v1.0 升级用户（有旧引擎键）→ false + zh-Hans + 一次性标记") {
            let d = freshDefaults()
            d.set(4, forKey: SettingsKey.threadCount)     // 模拟 v1.0 已安装的偏好
            let store = SettingsStore(defaults: d)
            let s = store.load()
            TestRunner.assertFalse(s.languageFollowsSystem)
            TestRunner.assertEqual(s.manualLanguageTag, "zh-Hans")
            TestRunner.assertTrue(s.didMigrateFromV10)

            // 迁移只发生一次：新键已写入，再次 load 不带 didMigrate 标记。
            let s2 = store.load()
            TestRunner.assertFalse(s2.didMigrateFromV10)
            TestRunner.assertFalse(s2.languageFollowsSystem)
            TestRunner.assertEqual(s2.manualLanguageTag, "zh-Hans")
        }

        TestRunner.register("设置迁移：13 个旧引擎键逐项向后兼容（P0-08 ①）") {
            let d = freshDefaults()
            let original = AppSettings()
            var expected = original
            expected.threadCount = 3
            expected.bufferSizeMB = 16
            expected.preserveTimestamps = false
            expected.enableClone = false
            expected.sparseMode = .forceKeep
            expected.defaultConflictPolicy = .overwrite
            expected.maxRetries = 2
            expected.defaultAlgorithms = [.sha256, .crc32]
            expected.verificationMode = .both
            expected.generateChecksumFile = true
            expected.checksumFailureAction = .markFailedOnly
            expected.bandwidthLimit = 1024 * 1024
            expected.serviceEnabled = false
            expected.languageFollowsSystem = false
            expected.manualLanguageTag = "ja"

            let store = SettingsStore(defaults: d)
            store.save(expected)
            let loaded = store.load()

            TestRunner.assertEqual(loaded.threadCount, expected.threadCount)
            TestRunner.assertEqual(loaded.bufferSizeMB, expected.bufferSizeMB)
            TestRunner.assertEqual(loaded.preserveTimestamps, expected.preserveTimestamps)
            TestRunner.assertEqual(loaded.enableClone, expected.enableClone)
            TestRunner.assertEqual(loaded.sparseMode, expected.sparseMode)
            TestRunner.assertEqual(loaded.defaultConflictPolicy, expected.defaultConflictPolicy)
            TestRunner.assertEqual(loaded.maxRetries, expected.maxRetries)
            TestRunner.assertEqual(loaded.defaultAlgorithms, expected.defaultAlgorithms)
            TestRunner.assertEqual(loaded.verificationMode, expected.verificationMode)
            TestRunner.assertEqual(loaded.generateChecksumFile, expected.generateChecksumFile)
            TestRunner.assertEqual(loaded.checksumFailureAction, expected.checksumFailureAction)
            TestRunner.assertEqual(loaded.bandwidthLimit, expected.bandwidthLimit)
            TestRunner.assertEqual(loaded.serviceEnabled, expected.serviceEnabled)
            TestRunner.assertEqual(loaded.languageFollowsSystem, false)
            TestRunner.assertEqual(loaded.manualLanguageTag, "ja")
        }

        TestRunner.register("设置迁移：手动值损坏 → 优雅降级为跟随系统（P0-09 ④）") {
            let d = freshDefaults()
            d.set(false, forKey: SettingsKey.languageFollowsSystem)
            d.set("INVALID_TAG", forKey: SettingsKey.manualLanguageTag)
            let s = SettingsStore(defaults: d).load()
            TestRunner.assertTrue(s.languageFollowsSystem)
            TestRunner.assertTrue(s.manualLanguageTag == nil)
        }

        TestRunner.register("设置迁移：manualLanguageTag=nil 用 removeObject，不残留键") {
            let d = freshDefaults()
            let store = SettingsStore(defaults: d)
            var s = AppSettings()
            s.manualLanguageTag = "fr"
            store.save(s)
            TestRunner.assertNotNil(d.string(forKey: SettingsKey.manualLanguageTag))
            s.manualLanguageTag = nil
            store.save(s)
            TestRunner.assertTrue(
                d.object(forKey: SettingsKey.manualLanguageTag) == nil,
                "nil 必须真正移除键，否则 hasNewKey 判定失真"
            )
        }

        TestRunner.register("设置迁移：didMigrateFromV10 是瞬态，save() 不写磁盘") {
            let d = freshDefaults()
            let store = SettingsStore(defaults: d)
            var s = AppSettings()
            s.didMigrateFromV10 = true
            s.languageFollowsSystem = false
            s.manualLanguageTag = "de"
            store.save(s)
            let loaded = store.load()
            TestRunner.assertFalse(loaded.didMigrateFromV10, "重启后标记必须消失")
            TestRunner.assertEqual(loaded.manualLanguageTag, "de")
        }

        TestRunner.register("设置迁移：resetToDefaults(preserving:) 保留语言偏好") {
            let d = freshDefaults()
            let store = SettingsStore(defaults: d)
            var s = AppSettings()
            s.threadCount = 8
            s.languageFollowsSystem = false
            s.manualLanguageTag = "ko"
            store.save(s)
            store.resetToDefaults(preserving: s)
            let loaded = store.load()
            TestRunner.assertEqual(loaded.threadCount, 2, "引擎参数应恢复默认")
            TestRunner.assertFalse(loaded.languageFollowsSystem, "语言不应被重置")
            TestRunner.assertEqual(loaded.manualLanguageTag, "ko")
        }
    }
}
