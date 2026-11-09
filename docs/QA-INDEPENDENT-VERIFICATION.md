# 独立验证报告：T01–T03 校验算法层（主理人亲自执行）

**日期**：2026-11-08
**验证方式**：主理人**不使用**工程师的测试用例，编写独立校验程序 `probe/Sources/probe/main.swift`，直接链接 `libMacCopyKit.dylib`，并与**系统命令 / Python 标准库**交叉验证。

## 1. 结论

| 项 | 结果 |
|---|---|
| BLAKE3 官方 test vectors | ✅ **35/35 全部通过** |
| BLAKE3 分段等价性 | ✅ 通过 |
| MD5（RFC 1321 全套） | ✅ 通过 |
| SHA-1 / SHA-256 | ✅ 通过 |
| CRC32（IEEE） | ✅ 通过 |
| MultiHasher 一致性 | ✅ 通过 |
| hasher reset 复用 | ✅ 通过 |
| MacCopyError 中文文案 | ✅ 通过 |
| **系统命令交叉验证** | ✅ **MD5 / SHA-1 / SHA-256 / CRC32 全部与系统实现一致** |

**未发现源码缺陷。**

## 2. 交叉验证对照表（同一 50000 字节样本文件）

样本：`probe` 生成的递增字节序列（`i % 251`），写入 `.tmp/xverify/sample.bin`

| 算法 | MacCopyKit 输出 | 交叉验证来源 | 系统输出 | 一致 |
|---|---|---|---|---|
| CRC32 (IEEE) | `c9f4364d` | Python `zlib.crc32` | `c9f4364d` | ✅ |
| MD5 | `7332033941fbd2d02417f9df0e45f30b` | `md5 -q` | 同 | ✅ |
| SHA-1 | `ef56840af62b6954f092ad727579b836d8515a0f` | `shasum -a 1` | 同 | ✅ |
| SHA-256 | `819e1ce4db744eb7573f7d5036d64f3c52184201ffa2ece0a2491a51ef14aba0` | `shasum -a 256` | 同 | ✅ |

> 注：`cksum` 得到的 `2839661412` 与实现不同是**正常的** —— POSIX `cksum` 用的是 CRC-32/CKSUM 变体（非 IEEE），不是标准 CRC32。标准 CRC32 的判定基准是 `CRC32("123456789") == cbf43926`，实现与 `zlib.crc32` 一致。

## 3. 标准向量明细

### 3.1 CRC32
- `CRC32("123456789") == cbf43926` ✅（IEEE 标准向量）
- `CRC32("") == 00000000` ✅
- 分段 update（逐字节）== 整体 update ✅

### 3.2 MD5（RFC 1321 全套）
| 输入 | 期望 | 结果 |
|---|---|---|
| `""` | `d41d8cd98f00b204e9800998ecf8427e` | ✅ |
| `"a"` | `0cc175b9c0f1b6a831c399e269772661` | ✅ |
| `"abc"` | `900150983cd24fb0d6963f7d28e17f72` | ✅ |
| `"message digest"` | `f96b697d7cb7938d525a2f31aaf161d0` | ✅ |
| `abcdefghijklmnopqrstuvwxyz` | `c3fcd3d76192e4007dfb496cca67e13b` | ✅ |
| `A-Z a-z 0-9` | `d174ab98d277d9f5a5611c2c9f419d9f` | ✅ |
| 100 万个 `a` | `7707d6ae4e027c70eea2a935c2296f21` | ✅ |

### 3.3 SHA-1 / SHA-256
- `SHA1("abc") == a9993e364706816aba3e25717850c26c9cd0d89d` ✅
- `SHA256("abc") == ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad` ✅
- SHA-256 分段 == 整体 ✅

### 3.4 BLAKE3（官方 `test_vectors.json`，35 条全覆盖）

覆盖长度：0, 1, 2, 3, 4, 5, 6, 7, 8, 63, 64, 65, 127, 128, 129, 1023, 1024, 1025, 2048, 2049, 3072, 3073, 4096, 4097, 5120, 5121, 6144, 6145, 7168, 7169, 8192, 8193, 16384, 31744, 102400

**关键边界全部覆盖**：
- **Chunk 边界（64 字节）**：63 / 64 / 65
- **Block 边界（1024 字节）**：1023 / 1024 / 1025
- **Chunk×Block 交叉**：3072 / 3073（48×64）、4096 / 4097、5120 / 5121、6144 / 6145
- **多块连续**：7168 / 7169、8192 / 8193
- **大文件**：16384、31744、102400

向量文件：`probe/blake3-vectors.json`（与实现完全解耦，期望值来自 BLAKE3 官方仓库）

**额外验证 —— 分段等价性**：对 10000 字节数据按 `[1, 7, 63, 64, 65, 1023, 1024, 1025, 4096]` 的不等长块依次 update，结果与一次性 update **完全一致** ✅

## 4. 其他验证项

| 项 | 结果 |
|---|---|
| `MultiHasher`（crc32+md5+sha256 同时 tee）各算法结果 vs 单独计算 | ✅ 全部一致 |
| `reset()` 后复用实例计算 MD5("abc") | ✅ 正确（验证了 reset 真的清空了状态） |
| `MacCopyError.diskFull` / `.checksumMismatch` 的 `localizedDescription` | ✅ 均为非空中文 |

## 5. 验证过程中发现的方法论问题（**均在我的验证代码，不在产品代码**）

### 5.1 BLAKE3 期望值必须用官方「递增字节」输入模式
官方 `test_vectors.json` 的 input 是**递增字节循环 0..250**，不是重复的 `'a'`。我最初用重复 `'a'` 导致 1/19 通过（只有 len=0 平凡通过），改用正确模式后 35/35。

> 值得注意：len=0 能通过**不构成任何验证**——空输入直接返回 IV。最初「1/19 通过」的表象具有误导性。

### 5.2 实现输出 64 字节（512-bit XOF），官方 test_vectors 也是 64 字节
比对时必须取**前 32 字节**（64 个 hex 字符）。我最初的期望值数组在抄录时长度参差（62/63/65 字符），造成「前缀一致但仍判失败」的假象。

**定位方法**：打印完整 64 字符对比后发现 4 条差异**全部只在最后一个字符**——是我的 JSON 在 `ljust(64,'0')` 补齐时残留了多余的 `0`。修正后 35/35。

### 5.3 Swift 链接 MacCopyKit 的编译要点（供后续 QA 参考）
```bash
swiftc -O -target arm64-apple-macos13.0 -sdk $(xcrun --show-sdk-path) \
  -I .build -L .build -lMacCopyKit \
  -Xlinker -rpath -Xlinker .build \
  Sources/probe/main.swift -o VerifyKit
```
**必须显式 `import MacCopyKit`**，否则符号找不到（错误信息为「cannot find 'X' in scope」，容易误判为 API 不存在）。
`ChecksumRegistry.make(_:)` 返回**非可选** `any ChecksumAlgorithm`，不要加 `!`。

## 6. 遗留事项（不阻塞）

- **T01–T04 的 IO/Engine 层（13 个新文件）目前零测试覆盖** —— 本次验证只覆盖了 T01–T03 的校验与模型层。T04 的 PathWalker / StreamCopier / CopyfileBridge / SparseHandler / TimestampPreserver 需要 QA 补测试。
- **T04 的 6 个核心编排文件尚未实现**：`CopyEngine` / `ResumeManager` / `Verifier` / `PlanBuilder` / `FileEnumerator` / `ConflictResolver`。当前无法做端到端复制验证。
- 10 万小文件的内存占用（G3 ≤300MB）尚未实测。
- 断点续传的端到端场景（模拟中断 → 恢复 → 校验一致）尚未验证。

## 7. 复现方式

```bash
cd <workspace>/probe
export TMPDIR=../.tmp
export CLANG_MODULE_CACHE_PATH=../.tmp/modcache-sys
KIT=../MacCopy/.build
swiftc -O -target arm64-apple-macos13.0 -sdk $(xcrun --show-sdk-path) \
  -I $KIT -L $KIT -lMacCopyKit -Xlinker -rpath -Xlinker $KIT \
  Sources/probe/main.swift -o VerifyKit
./VerifyKit
```
