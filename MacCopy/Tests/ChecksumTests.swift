import Foundation
import MacCopyKit

/// 校验算法测试（CRC32 / MD5 / SHA-1 / SHA-256 / BLAKE3）。
@MainActor
enum ChecksumTests {
    /// 注册全部用例。
    static func register() {
        registerCRC32()
        registerMD5()
        registerSHA()
        registerBLAKE3()
        registerRegistry()
        registerChecksumFileWriter()
    }

    // MARK: - CRC32

    private static func registerCRC32() {
        TestRunner.register("CRC32 标准向量（123456789 → cbf43926）") {
            TestRunner.assertEqual(
                CRC32Hasher.hexDigest(of: Array("123456789".utf8)),
                "cbf43926"
            )
        }

        TestRunner.register("CRC32 空输入") {
            TestRunner.assertEqual(CRC32Hasher.hexDigest(of: []), "00000000")
        }

        TestRunner.register("CRC32 单字节 'a'（e8b7be43）") {
            TestRunner.assertEqual(
                CRC32Hasher.hexDigest(of: Array("a".utf8)),
                "e8b7be43"
            )
        }

        TestRunner.register("CRC32 大端序输出字节") {
            var hasher = CRC32Hasher()
            hasher.update(bytes: Array("123456789".utf8))
            let digest = hasher.finalize()
            TestRunner.assertEqual(digest.count, 4)
            TestRunner.assertEqual(digest[0], 0xCB)
            TestRunner.assertEqual(digest[1], 0xF4)
            TestRunner.assertEqual(digest[2], 0x39)
            TestRunner.assertEqual(digest[3], 0x26)
        }

        TestRunner.register("CRC32 分段更新等价一次性更新") {
            let payload = Array("The quick brown fox jumps over the lazy dog".utf8)
            var oneShot = CRC32Hasher()
            oneShot.update(bytes: payload)

            var chunked = CRC32Hasher()
            chunked.update(bytes: Array(payload[0..<7]))
            chunked.update(bytes: Array(payload[7..<20]))
            chunked.update(bytes: Array(payload[20...]))

            TestRunner.assertEqual(
                Bytes.hexString(oneShot.finalize()),
                Bytes.hexString(chunked.finalize())
            )
        }

        TestRunner.register("CRC32 reset 后可复用") {
            var hasher = CRC32Hasher()
            hasher.update(bytes: Array("123456789".utf8))
            _ = hasher.finalize()
            hasher.reset()
            hasher.update(bytes: Array("123456789".utf8))
            TestRunner.assertEqual(Bytes.hexString(hasher.finalize()), "cbf43926")
        }
    }

    // MARK: - MD5

    private static func registerMD5() {
        TestRunner.register("MD5 RFC 1321 空输入") {
            TestRunner.assertEqual(
                MD5Hasher.hexDigest(of: []),
                "d41d8cd98f00b204e9800998ecf8427e"
            )
        }

        TestRunner.register("MD5 RFC 1321 'a'") {
            TestRunner.assertEqual(
                MD5Hasher.hexDigest(of: Array("a".utf8)),
                "0cc175b9c0f1b6a831c399e269772661"
            )
        }

        TestRunner.register("MD5 RFC 1321 'abc'") {
            TestRunner.assertEqual(
                MD5Hasher.hexDigest(of: Array("abc".utf8)),
                "900150983cd24fb0d6963f7d28e17f72"
            )
        }

        TestRunner.register("MD5 RFC 1321 'message digest'") {
            TestRunner.assertEqual(
                MD5Hasher.hexDigest(of: Array("message digest".utf8)),
                "f96b697d7cb7938d525a2f31aaf161d0"
            )
        }

        TestRunner.register("MD5 RFC 1321 字母表") {
            TestRunner.assertEqual(
                MD5Hasher.hexDigest(of: Array("abcdefghijklmnopqrstuvwxyz".utf8)),
                "c3fcd3d76192e4007dfb496cca67e13b"
            )
        }

        TestRunner.register("MD5 RFC 1321 数字字母混合") {
            TestRunner.assertEqual(
                MD5Hasher.hexDigest(of: Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".utf8)),
                "d174ab98d277d9f5a5611c2c9f419d9f"
            )
        }

        TestRunner.register("MD5 RFC 1321 100 万个 'a'") {
            let payload = [UInt8](repeating: 0x61, count: 1_000_000)
            TestRunner.assertEqual(
                MD5Hasher.hexDigest(of: payload),
                "7707d6ae4e027c70eea2a935c2296f21"
            )
        }

        TestRunner.register("MD5 分段更新等价一次性更新") {
            let payload = Array("The quick brown fox jumps over the lazy dog".utf8)
            var oneShot = MD5Hasher()
            oneShot.update(bytes: payload)

            var chunked = MD5Hasher()
            chunked.update(bytes: Array(payload[0..<3]))
            chunked.update(bytes: Array(payload[3..<17]))
            chunked.update(bytes: Array(payload[17...]))

            TestRunner.assertEqual(
                Bytes.hexString(oneShot.finalize()),
                Bytes.hexString(chunked.finalize())
            )
        }
    }

    // MARK: - SHA

    private static func registerSHA() {
        TestRunner.register("SHA-1 空输入") {
            TestRunner.assertEqual(
                SHA1Hasher.hexDigest(of: []),
                "da39a3ee5e6b4b0d3255bfef95601890afd80709"
            )
        }

        TestRunner.register("SHA-1 'abc'") {
            TestRunner.assertEqual(
                SHA1Hasher.hexDigest(of: Array("abc".utf8)),
                "a9993e364706816aba3e25717850c26c9cd0d89d"
            )
        }

        TestRunner.register("SHA-1 长消息（56 字节边界）") {
            let payload = Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)
            TestRunner.assertEqual(
                SHA1Hasher.hexDigest(of: payload),
                "84983e441c3bd26ebaae4aa1f95129e5e54670f1"
            )
        }

        TestRunner.register("SHA-1 100 万个 'a'") {
            let payload = [UInt8](repeating: 0x61, count: 1_000_000)
            TestRunner.assertEqual(
                SHA1Hasher.hexDigest(of: payload),
                "34aa973cd4c4daa4f61eeb2bdbad27316534016f"
            )
        }

        TestRunner.register("SHA-1 纯 Swift fallback 与 CryptoKit 一致") {
            let payload = Array("The quick brown fox jumps over the lazy dog".utf8)
            var crypto = SHA1Hasher()
            crypto.update(bytes: payload)
            var pure = SHA1PureSwift()
            pure.update(bytes: payload)
            TestRunner.assertEqual(
                Bytes.hexString(crypto.finalize()),
                Bytes.hexString(pure.finalize())
            )
        }

        TestRunner.register("SHA-256 空输入") {
            TestRunner.assertEqual(
                SHA256Hasher.hexDigest(of: []),
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
            )
        }

        TestRunner.register("SHA-256 'abc'") {
            TestRunner.assertEqual(
                SHA256Hasher.hexDigest(of: Array("abc".utf8)),
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
            )
        }

        TestRunner.register("SHA-256 长消息（56 字节边界）") {
            let payload = Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)
            TestRunner.assertEqual(
                SHA256Hasher.hexDigest(of: payload),
                "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
            )
        }

        TestRunner.register("SHA-256 100 万个 'a'") {
            let payload = [UInt8](repeating: 0x61, count: 1_000_000)
            TestRunner.assertEqual(
                SHA256Hasher.hexDigest(of: payload),
                "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
            )
        }

        TestRunner.register("SHA-256 纯 Swift fallback 与 CryptoKit 一致") {
            let payload = Array("The quick brown fox jumps over the lazy dog".utf8)
            var crypto = SHA256Hasher()
            crypto.update(bytes: payload)
            var pure = SHA256PureSwift()
            pure.update(bytes: payload)
            TestRunner.assertEqual(
                Bytes.hexString(crypto.finalize()),
                Bytes.hexString(pure.finalize())
            )
        }

        TestRunner.register("SHA-256 分段更新等价一次性更新") {
            let payload = Array("The quick brown fox jumps over the lazy dog".utf8)
            var oneShot = SHA256Hasher()
            oneShot.update(bytes: payload)

            var chunked = SHA256Hasher()
            chunked.update(bytes: Array(payload[0..<5]))
            chunked.update(bytes: Array(payload[5..<29]))
            chunked.update(bytes: Array(payload[29...]))

            TestRunner.assertEqual(
                Bytes.hexString(oneShot.finalize()),
                Bytes.hexString(chunked.finalize())
            )
        }
    }

    // MARK: - BLAKE3

    private static func registerBLAKE3() {
        TestRunner.register("BLAKE3 官方 test vectors 全量比对（\(BLAKE3TestVectors.vectors.count) 条）") {
            for vector in BLAKE3TestVectors.vectors {
                let input = BLAKE3TestVectors.input(length: vector.inputLength)
                var hasher = BLAKE3Hasher()
                hasher.update(bytes: input)
                let actual = Bytes.hexString(hasher.finalize())
                TestRunner.assertEqual(
                    actual,
                    vector.hash,
                    "输入长度 \(vector.inputLength)"
                )
            }
        }

        TestRunner.register("BLAKE3 分段更新等价一次性更新（跨 Chunk 边界）") {
            let input = BLAKE3TestVectors.input(length: 2049)
            var oneShot = BLAKE3Hasher()
            oneShot.update(bytes: input)

            var chunked = BLAKE3Hasher()
            chunked.update(bytes: Array(input[0..<1]))
            chunked.update(bytes: Array(input[1..<1024]))
            chunked.update(bytes: Array(input[1024..<1025]))
            chunked.update(bytes: Array(input[1025...]))

            TestRunner.assertEqual(
                Bytes.hexString(oneShot.finalize()),
                Bytes.hexString(chunked.finalize())
            )
        }

        TestRunner.register("BLAKE3 恰好 Chunk 边界（1024 字节）") {
            let input = BLAKE3TestVectors.input(length: 1024)
            var hasher = BLAKE3Hasher()
            hasher.update(bytes: input)
            let vector = BLAKE3TestVectors.vectors.first { $0.inputLength == 1024 }
            TestRunner.assertEqual(Bytes.hexString(hasher.finalize()), vector?.hash ?? "")
        }

        TestRunner.register("BLAKE3 reset 后可复用") {
            var hasher = BLAKE3Hasher()
            hasher.update(bytes: BLAKE3TestVectors.input(length: 1025))
            _ = hasher.finalize()
            hasher.reset()
            hasher.update(bytes: BLAKE3TestVectors.input(length: 1025))
            let vector = BLAKE3TestVectors.vectors.first { $0.inputLength == 1025 }
            TestRunner.assertEqual(Bytes.hexString(hasher.finalize()), vector?.hash ?? "")
        }

        TestRunner.register("BLAKE3 摘要长度为 32 字节") {
            var hasher = BLAKE3Hasher()
            hasher.update(bytes: Array("abc".utf8))
            TestRunner.assertEqual(hasher.finalize().count, 32)
        }
    }

    // MARK: - 注册表

    private static func registerRegistry() {
        TestRunner.register("注册表内置 5 种算法") {
            let registry = ChecksumRegistry()
            TestRunner.assertEqual(registry.available.count, 5)
            TestRunner.assertTrue(registry.available.contains(.crc32))
            TestRunner.assertTrue(registry.available.contains(.md5))
            TestRunner.assertTrue(registry.available.contains(.sha1))
            TestRunner.assertTrue(registry.available.contains(.sha256))
            TestRunner.assertTrue(registry.available.contains(.blake3))
        }

        TestRunner.register("注册表可创建全部算法实例") {
            let registry = ChecksumRegistry()
            for id in registry.available {
                let algorithm = registry.make(id)
                TestRunner.assertEqual(algorithm.id, id)
                TestRunner.assertEqual(algorithm.digestLength, id.digestLength)
            }
        }

        TestRunner.register("MultiHasher 多算法一致性") {
            let payload = Array("The quick brown fox jumps over the lazy dog".utf8)
            let algorithms: [ChecksumAlgorithmID] = [.crc32, .md5, .sha1, .sha256, .blake3]
            var multi = MultiHasher(algorithms: algorithms)
            multi.update(bytes: payload)
            let digests = multi.finalizeHex()

            for id in algorithms {
                var single = ChecksumRegistry.shared.make(id)
                single.update(buffer: payload.withUnsafeBytes { UnsafeRawBufferPointer($0) })
                TestRunner.assertEqual(digests[id], Bytes.hexString(single.finalize()), id.rawValue)
            }
        }

        TestRunner.register("Hasher 封装与直接使用一致") {
            var hasher = Hasher(.sha256)
            hasher.update(bytes: Array("abc".utf8))
            var direct = SHA256Hasher()
            direct.update(bytes: Array("abc".utf8))
            TestRunner.assertEqual(hasher.finalizeHex(), Bytes.hexString(direct.finalize()))
        }
    }

    // MARK: - 清单生成

    private static func registerChecksumFileWriter() {
        TestRunner.register("checksum 清单格式（shasum -c 兼容：两个空格）") {
            let content = ChecksumFileWriter.content(for: [
                (relativePath: "a.txt", digest: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
                (relativePath: "子目录/b.txt", digest: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            ])
            TestRunner.assertTrue(content.hasPrefix("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  a.txt\n"))
            TestRunner.assertTrue(content.contains("  子目录/b.txt\n"))
            TestRunner.assertTrue(content.hasSuffix("\n"))
        }

        TestRunner.register("checksum 清单转义反斜杠") {
            let content = ChecksumFileWriter.content(for: [
                (relativePath: "we\\ird.txt", digest: "00"),
            ])
            TestRunner.assertEqual(content, "00  we\\\\ird.txt\n")
        }

        TestRunner.register("checksum 清单文件扩展名") {
            TestRunner.assertEqual(ChecksumFileWriter.fileExtension(for: .sha256), "sha256")
            TestRunner.assertEqual(ChecksumFileWriter.fileExtension(for: .md5), "md5")
        }
    }
}
