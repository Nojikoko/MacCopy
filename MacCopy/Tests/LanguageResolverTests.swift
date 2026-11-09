import Foundation
import MacCopyKit

/// 语言回退链 12 组输入（PRD-I18N P0-07 / 架构 T-I05 §1）。
@MainActor
enum LanguageResolverTests {
    static func register() {
        let resolver = LanguageResolver()

        TestRunner.register("语言解析：en-GB → en（两段前缀）") {
            let r = resolver.resolve(systemLocalizations: ["en-GB"], manualTag: nil, followsSystem: true)
            TestRunner.assertEqual(r.language, .en)
            TestRunner.assertFalse(r.isSystemFallback)
        }

        TestRunner.register("语言解析：fr-CA → fr") {
            let r = resolver.resolve(systemLocalizations: ["fr-CA"], manualTag: nil, followsSystem: true)
            TestRunner.assertEqual(r.language, .fr)
        }

        TestRunner.register("语言解析：zh-Hant-TW → zh-Hant（4a 必须早于 4b）") {
            let r = resolver.resolve(systemLocalizations: ["zh-Hant-TW"], manualTag: nil, followsSystem: true)
            TestRunner.assertEqual(r.language, .zhHant)
        }

        TestRunner.register("语言解析：de-AT → de") {
            let r = resolver.resolve(systemLocalizations: ["de-AT"], manualTag: nil, followsSystem: true)
            TestRunner.assertEqual(r.language, .de)
        }

        TestRunner.register("语言解析：es-MX → es") {
            let r = resolver.resolve(systemLocalizations: ["es-MX"], manualTag: nil, followsSystem: true)
            TestRunner.assertEqual(r.language, .es)
        }

        TestRunner.register("语言解析：裸 zh + TW → zh-Hant（区域判简繁）") {
            let r = resolver.resolve(systemLocalizations: ["zh-TW"], manualTag: nil, followsSystem: true)
            TestRunner.assertEqual(r.language, .zhHant)
        }

        TestRunner.register("语言解析：裸 zh + CN → zh-Hans") {
            let r = resolver.resolve(systemLocalizations: ["zh-CN"], manualTag: nil, followsSystem: true)
            TestRunner.assertEqual(r.language, .zhHans)
        }

        TestRunner.register("语言解析：ru / it / pt-BR / ar 全部 → en 且标记回退") {
            for tag in ["ru", "it", "pt-BR", "ar"] {
                let r = resolver.resolve(systemLocalizations: [tag], manualTag: nil, followsSystem: true)
                TestRunner.assertEqual(r.language, .en, tag)
                TestRunner.assertTrue(r.isSystemFallback, tag)
            }
        }

        TestRunner.register("语言解析：系统列表空 → zh-Hans") {
            let r = resolver.resolve(systemLocalizations: [], manualTag: nil, followsSystem: true)
            TestRunner.assertEqual(r.language, .zhHans)
            TestRunner.assertFalse(r.isSystemFallback)
        }

        TestRunner.register("语言解析：手动值损坏 → 按未设置处理，落入系统解析") {
            let r = resolver.resolve(
                systemLocalizations: ["ja-JP"],
                manualTag: "NOT_A_LANGUAGE",
                followsSystem: false
            )
            TestRunner.assertEqual(r.language, .ja)
            TestRunner.assertFalse(r.isSystemFallback)
        }

        TestRunner.register("语言解析：手动值合法时优先于系统") {
            let r = resolver.resolve(
                systemLocalizations: ["ja-JP"],
                manualTag: "de",
                followsSystem: false
            )
            TestRunner.assertEqual(r.language, .de)
            TestRunner.assertFalse(r.isSystemFallback)
        }

        TestRunner.register("语言解析：followsSystem=true 时忽略手动值") {
            let r = resolver.resolve(
                systemLocalizations: ["ko-KR"],
                manualTag: "fr",
                followsSystem: true
            )
            TestRunner.assertEqual(r.language, .ko)
        }

        TestRunner.register("语言清单：8 语顺序锁定且含 es（Q10）") {
            TestRunner.assertEqual(
                SupportedLanguage.allTags,
                ["zh-Hans", "en", "zh-Hant", "ja", "ko", "fr", "de", "es"]
            )
        }
    }
}
