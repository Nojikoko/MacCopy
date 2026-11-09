# QA T04 独立验证报告（严过关 / Yan）· 最终版 v2.1

**日期**：2026-11-08
**范围**：MacCopy T04 —— IO 层（6 文件）与 Engine 层（13 文件，含验证期间新增的 `CopyEngine.swift` / `Verifier.swift`）
**方式**：不使用工程师的测试用例；自写独立验证程序链接 `libMacCopyKit.dylib`，并与系统命令 / 原始 POSIX 调用交叉验证。
**验证程序**：`probe/t04/*.swift`（约 20 个文件），编译产物 `.tmp/VerifyT04`

> **v2 更新（最终回归）**：工程师已修复第 2 轮报的 BUG-03 / 04 / 05 / 06，我复跑后
> **独立探针 270/270 全绿，6 个缺陷全部关闭**。最终路由由 `Engineer` 改为 **`NoOne`**。
> 详见第 10 节。第 3 节的缺陷描述保留作为历史记录，状态已标注「已修复」。

---

## 1. 真实输出（亲自跑）

### build.sh（最终）
```
构建模式：Release
源文件数：56
编译 MacCopyKit …
构建完成：<workspace>/MacCopy/.build/libMacCopyKit.dylib
编译 MacCopyCLI …  构建完成
编译 MacCopyApp …  构建完成
BUILD_EXIT=0
```
> 期间两次因工程师并发修改 `Verifier.swift` / `FileEnumerator.swift` / `ThroughputTests.swift`
> 报 `input file ... was modified during the build` 或编译期错误；等待源码稳定后重跑即通过。

### test.sh（最终，源码稳定后单次运行）
```
TEST_EXIT=0
=== 汇总 ===
通过：178  失败：0  总计：178
结果：全部通过 ✅
✅ 测试全部通过
=== 静态合规扫描 ===
  ✅ AD-01：无 @Observable 真实使用
  ✅ AD-02：MacCopyKit Foundation-only
  ✅ 术语规范：「八种语言」表述，无「国家」量词
  ✅ 源码本地化 key 全部登记（188 个）
✅ 静态合规扫描通过
=== 真实 .app i18n 验收 ===
  ✅ en 叠加 / ko.lproj 物理缺失 / 坏占位符 / 空串 / 漏 key 全部通过（未崩溃）
```
> 测试数随迭代：69 → 107 → 108 → 123 → **178**。
> 新含 `Tests/QABugRegressionTests.swift` 的 6 个 BUG 回归用例与 i18n .app 宿主验收。

### 独立验证程序（最终）
```
./.tmp/VerifyT04 all
通过：270  失败：0      ← 原 264/6，修复后全绿
```

### 关于 `test.sh` 退出码的更正（重要，避免误导）
我一度报「`test.sh` 失败时仍退出 0」，**该结论是我测量方法有误，已撤回**：
当时用 `bash test.sh | tail` 取 `$?`（取到的是 `tail` 的退出码），且循环里每次跑了两次
`test.sh`（一次取计数、一次取退出码），两者并非同一次运行。

用「单次调用同时捕获输出与退出码」重测 4 次：
```
RUN 1 EXIT=1   （编译期失败，见下）
RUN 2 EXIT=1   （编译期失败）
RUN 3 EXIT=1   （编译期失败）
RUN 4 EXIT=0   通过：178 失败：0 结果：全部通过 ✅
```
`test.sh` **在测试失败时确实正确返回 1**（`set -euo pipefail` + 测试二进制自身 `exit 1`）。
RUN 1–3 的失败不是断言失败，而是工程师当时正在编辑 `Tests/ThroughputTests.swift`，
编译期报 `class method 'sleep' is unavailable from asynchronous contexts`（第 90 行）。
等待源码稳定后单次运行即为 178/178 / EXIT=0。**这是并发编辑导致的时序问题，不是产品缺陷。**

> **⚠️ 吞吐项在并发构建下不稳定（QA-1 独立印证，供后来人避免误读）**
> `ThroughputTests.swift` 的 `BLAKE3 ≥ 1.0 GB/s` 是时序硬门槛，并发跑 `build.sh` 抢 CPU 时会误报：
> QA-1 实测 4 次落在 **0.561–0.983 GB/s**，其独立探针同时段为 0.610–0.876，空闲时为 1.075–1.166。
> **根因是 CPU 争用，不是算法回归**（BLAKE3 官方 vectors 35/35 仍全过，见
> `docs/QA-INDEPENDENT-VERIFICATION.md`）。我这边也曾观察到一次 0.694 GB/s 的失败。
> 因此本报告引用「`test.sh` 全绿」仅作为**构建/回归能跑通**的背景事实，
> **不作为吞吐性能达标的证据**，也不作为任何 P0 验收结论。
> 主理人已定测量口径：高优先级专用线程 8 次取最优、记录全部采样值、门槛 1.0 GB/s 不放宽、
> 无 skip/xfail，8 次全低于才判真实回归。译文破坏性测试的同类并发残留亦已由工程师
> 加 `ensureHealthyTranslations()` 前置检查 + `.atomic` 立即恢复解决。

---

## 2. A–I 验证结果表（最终状态）

| 项 | 内容 | 结果 |
|---|---|---|
| **A** | PathWalker 长路径 | ✅ **通过** |
| A1 | 40 级嵌套 + 中文长文件名，内容逐字节一致 | ✅ 路径 **1227 字节 > PATH_MAX**，`openat` 慢路径生效 |
| A2 | 总路径 > 1024 字节绕过 PATH_MAX | ✅ `openDirectory`/`openChild`/`openFile`/`createDirectory` 全部成功 |
| A3 | 逐级创建目录（父不存在） | ✅ |
| A4 | 符号链接：复制本身、不递归、linkDestination | ✅ BUG-01/02 修复后通过；`CopyEngine` 真正重建链接 |
| A5 | 10 种边界字符名（空格/emoji/换行/引号/tab/反斜杠等） | ✅ 创建 + 枚举 + 读回一致 |
| **B** | StreamCopier tee 哈希 | ✅ **18/18** |
| B1 | tee 哈希 == 源文件独立哈希（SHA-256 + CRC32） | ✅ 并与系统 `shasum -a 256` 交叉验证一致 |
| B2 | bufferSize = 1/3/7/8/63/64/65/4096 | ✅ 8 种摘要与内容全部一致 |
| B3 | 短读短写（空文件 / 尾块 / 5000 次单字节写 / 无 O_TRUNC） | ✅ |
| B4 | `Task.cancel()` → `MacCopyError.cancelled` | ✅ |
| B5 | 管道（不可寻址源）+ startOffset>0 → 退回从头复制 | ✅ effectiveStart=0、seekable=false、5000 字节完整 |
| **C** | CopyfileBridge | ⚠️ **通过，有设计缺口 Q1** |
| C1 | `commit` 的 CLONE → EEXIST → DATA 回退 | ✅ dst 已存在 EEXIST(17) → DATA 覆盖成功 |
| C1' | 覆盖内容正确（不追加、不截断、大旧文件无残留尾巴） | ✅ |
| C2 | `WAS_CLONED` 检测 | ⚠️ 路径通道准确；fd 通道恒 0（Q1，返回值诚实不误报） |
| C3 | 克隆后源与目标相互独立 | ✅ 双向修改互不影响 |
| **D** | SparseHandler / SparseProbe | ✅ **通过（BUG-03 已修）** |
| D1 | 稀疏创建：64 MiB 逻辑 / **32 KiB** 占用 | ✅ |
| D2 | `SparseProbe.holes` | ✅ 修复后报告 2 段，offset `16384`/`33570816`，与原始 lseek 推算一致 |
| D3 | 稀疏复制后仍稀疏、内容逐字节一致 | ✅ 修复后目标 **32 KiB**（原 32 MiB），内容一致 |
| D4 | 策略与降级标注 | ✅ 8/8 |
| D5 | VolumeInspector | ✅ 5/5 |
| **E** | TimestampPreserver | ✅ **全部通过**，mtime/birthtime 差 **0.0 秒** |
| **F** | ResumeManager | ✅ **30/30**；中断→续传内容一致、签名变化不拼接、7 天标注、rename→copyfile 两级提交 |
| **G** | ConflictResolver | ✅ **20/20** |
| **H** | PlanBuilder 内存（PRD G3） | ✅ **2 MiB / 6 MiB**，196 批，单批 ≤512 |
| **I** | 架构约束 | ✅ AD-01/02/04、§8.3 errno 13 项、§8.2 Sendable 全过；§8.8 见 Q3 |
| **J** | 端到端 CopyEngine + Verifier | ✅ **60/60**；篡改 1 字节 100% 检出 |
| **K** | ProgressTracker / SpeedSampler / RetryPolicy / FileDescriptor / MetadataOps | ✅ **通过（BUG-04/05/06 已修）** |

---

## 3. 缺陷清单（历史记录，全部已关闭）

### ✅ BUG-01（严重，已修复并回归）
`IO/PathWalker.swift` `DirectoryEntryType` 常量与 Darwin `DT_*` 不符 → 目录判为 `fifo`、符号链接/普通文件判为 `unknown`，`FileEnumerator` 不递归。工程师已改真值（0/1/2/4/6/8/10/12）。`./.tmp/VerifyT04 dtype` 3/3 通过。

### ✅ BUG-02（严重，已修复并回归）
`Engine/FileEnumerator.swift:195` `readlink(path, &buffer, ...)` 传数组对象而非元素指针 → `linkDestination` 恒 nil。已改 `withUnsafeMutableBytes`。`symlink` 通过。

### ✅ BUG-03（严重 / 数据损坏，已修复并回归）
`IO/SparseProbe.swift:70-71` 把 `SEEK_DATA`~`SEEK_HOLE` 之间的**数据段**当成空洞返回。
修复前：报告空洞总 33,570,816 字节，真实 67,076,096；下游 `SparseHandler` 据此跳过真实数据、把空洞写 0 → 目标占用 32 MiB（源 32 KiB）、内容不一致。
工程师重写 `holes(in:size:)`：维护 `cursor` = 上一段数据终点，`[cursor, dataOffset)` 才是空洞，`SEEK_HOLE` 后 `cursor = holeOffset`，ENXIO 补尾洞。
**回归**：`sparsediag` 4/4；`D2.3`/`D3.3`/`D3.4` 全绿；稀疏复制目标占用从 32 MiB 降到 **32 KiB**、内容逐字节一致。

### ✅ BUG-04（高，已修复并回归）
`Engine/SpeedSampler.swift:42-45` `defer { lastTime = now }` 在采样被跳过时也执行 → 快速复制时采样点恒为 1、速度恒 0、ETA 恒 nil。
工程师把 `lastTime/lastBytes` 更新移出 `defer`，只在 `samples.append` 后执行。
**回归**：`samplerdiag` 4/4；0.2s×20 次能记录采样点、`instantaneous > 0`、`bytesPerSecond > 0`、ETA 非 nil；`K1.5` 转绿。

### ✅ BUG-05（中，已修复并回归）
`IO/MetadataOps.swift:234` `withUnsafeBytes(of: names[offset...])` 取的是 `ArraySlice` 结构体本身而非元素 → 属性名乱码、`getxattr` 全失败、xattr 全丢。
工程师改为 `names.withUnsafeBytes { raw in ... }` 在整个缓冲上按 offset 取子串。
**回归**：`xattrdiag` 3/3；`K5.9`/`K5.10` 转绿，目标端 `getxattr` 读回正确值。

### ✅ BUG-06（中，已修复并回归）
`Engine/CopyEngine.swift:642-645` 从不调用 `tracker.completeFile()/failFile()/skipFile()` → UI「已完成/失败/跳过」与文件进度条不动（`fileFraction=0.0`）。
工程师在批次循环按 `outcome.status` 调三个计数方法，并在汇总前补 `progress = tracker.snapshot()`（工程师自己发现：只调计数不刷新快照，UI 读到的仍是 0）。
**回归**：`progdiag` 6/6；`progress.completedFiles == 5`、`fileFraction == 1.0`。

**遗留缺陷：0 个。**

---

## 4. 待确认事项（**v2.1 更新：三项均已由主理人 / PM 闭环关闭**，非缺陷）

### Q1：`fcopyfile` 通道在本机不触发 APFS CoW 克隆
`IO/CopyfileBridge.swift:25-61`，稠密 64 MiB 实测（`./.tmp/VerifyT04 clonevar2`）：

| 变体 | rc | WAS_CLONED | 磁盘净变化 | 结论 |
|---|---|---|---|---|
| `fcopyfile(fd,fd, DATA\|CLONE)` | 0 | **0** | 64 MiB | 全量拷贝 |
| `fcopyfile(fd,fd, CLONE only)` | 0 | 0 | 0 | 真克隆但 dst 为空 |
| `fcopyfile` + set SRC_FD/DST_FD | **-1** | 0 | 0 | 直接失败 |
| `copyfile(path,path, DATA\|CLONE)` | 0 | **1** | **0** | 真克隆 ✅ |

`copyWithClone` 返回 false 与实际行为一致，不误报；但「APFS 克隆快路径」收益为 0。

> **✅ Q1 已关闭（主理人裁决 A，v2.1）**：v1.1 **保持现状不动冻结区** —— `copyWithClone()` 返回 false 是诚实行为、不是缺陷。
> 按路径长度分流的技术方案已裁决为架构 **AD-13**：路径 ≤1000 且同卷 APFS 且源可 seek →
> `copyfile(path,path,DATA|CLONE)` 真 CoW；长路径保留 `fcopyfile` 绕 PATH_MAX 但**不传 CLONE**。
> 改动范围单独立项 **v1.2**，本轮不动代码。
> 附带根因补充（架构师实测）：`COPYFILE_STATE_WAS_CLONED` 的 dst 是 `bool*`（1 字节），
> 用 `Int32 = -1` 接收会读出 -256/-255 导致恒 false；文档示例已修正为 `UInt8`，代码侧一并归入 v1.2。
> 我认可的方向与 AD-13 一致，**无需再改代码，我不介入 v1.2**。

### Q2：`maxDepth` 语义（已澄清、已补文档，非 bug）
`Engine/FileEnumerator.swift:100` 的 `depth > maxDepth` 即「最大递归深度」（0=不限），与我修正后的断言一致。

> **✅ Q2 已关闭（PM，v2.1）**：`docs/PRD.md` 新增**附录 A「文件枚举参数语义澄清（QA-2 的 Q2）」**，
> 按 `FileEnumerator.swift:61/100/158-163` 实际行为定义：
> - `maxDepth` 默认 `0` = 不限（不是「只枚举根目录」）
> - 源根**直接子项为 depth 0**，每进一层子目录 `depth + 1`
> - 判定在 `walk` 入口 `if maxDepth > 0, depth > maxDepth { return }`，**先判定再枚举当前层**
> - 故 `maxDepth = N > 0` 枚举 depth 0…N；`N+1` 及更深不展开 —— 与我的实测完全一致
> - 负数等同不限但调用方**不得传**；`maxDepth` 是逻辑层级限制，与 PATH_MAX / 40 级嵌套无关
> - **P0-11 长路径验收必须 `maxDepth = 0`**；10 万小文件专项亦须显式确认，否则样本被截断会假通过/假失败
>
> 附录 A.2 列全 `Options` 四个参数默认值与语义。代码不改。

### Q3：§8.8 中文字面量口径
排除注释后 `MacCopyKit` 内 104 条中文字符串字面量，多数是 `Localization.format(default:)` 中文兜底（`Localization.swift` 明确允许）与 `Log.*` 日志文案；少数 `displayName` / `Outcome.note` 等用户可见文案未走 Catalog。架构自检脚本只查 `Text("`（T05 范围）。

> **✅ Q3 已关闭（主理人，v2.1）**：按我的建议**记录为 P1 待明确项，本轮不判失败、不阻塞发版**。
> 若后续需要调整 PRD 措辞，PM 表示可直接找他。

### 附：i18n 中文基准（非我范围）
工程师本轮一并修了 QA-1 报的 `Localization.baseline()` 缺失问题，并写 `tools/i18n_app_acceptance.sh` 接入 `test.sh`。最终 `test.sh` 输出显示真实 `.app` + `-AppleLanguages "(en)"` 的 7 项断言 + 物理删 `ko.lproj` 的 2 项断言全过、无 SIGSEGV。我未独立复跑该部分（由 QA-1 负责第 2 轮回归），仅记录 `test.sh` 输出。

---

## 5. 10 万文件内存实测数字（PRD G3 硬指标）

样本：100 子目录 × 1000 小文件（每个 4 字节），共 **100000 文件 / 100100 条目**，约 6 秒。

| 指标 | 实测 | 门槛 | 结论 |
|---|---|---|---|
| `PlanBuilder.build` 峰值 `phys_footprint` | **2 MiB** | ≤ 300 MiB | ✅ 余量约 150× |
| `PlanBuilder.build` 峰值 RSS (`ru_maxrss`) | **6 MiB** | ≤ 300 MiB | ✅ |
| 枚举前基线 | 1 MiB | — | — |
| 批次数 | 196 | > 1 | ✅ 确实分批 |
| 单批最大条目数 | 512 | ≤ 512 | ✅ |
| 条目总数 | 100100 | 100100 | ✅ |
| `statistics` 结束前后 | 2 → 2 MiB | 不暴涨 | ✅ 不驻留全量 |
| `FileEnumerator` 直接流式枚举峰值 | **2 MiB** | ≤ 300 MiB | ✅ |

**G3 大幅达标。**

---

## 6. 环境受限 / 未验证（明确列出，不伪装通过）

| 项 | 状态 | 说明 |
|---|---|---|
| 10 GiB 稀疏文件原始规模（PRD P0-12 验收标准原文） | ⚠️ 未按原始规模 | 磁盘 ~26 GB 禁止双份落盘；用 **64 MiB 稀疏样本按比例验证**（1/4 阈值）。修复后目标占用 32 KiB / 逻辑 64 MiB，比例远优于 1/10 |
| 100 GiB 克隆 ≤ 5 s（架构 T04 ⑦） | ⚠️ 未验证 | 用 64 MiB 稠密样本验证 `WAS_CLONED` 与磁盘净变化 |
| 外置卷 / exFAT / FAT32 / SMB 目标 | ❌ 环境受限 | 本机只有 `apfs` 单卷；仅验证 `SparseHandler.outcome`、`TimestampPreserver.precision` 的逻辑分支 |
| 真机 kill 进程重启 App 续传 | ⚠️ 等价模拟 | 用「写一半→记录→重新执行→续传→校验」，F4 通过 |
| i18n 真实 `.app` + 多系统语言 | ❌ 不在本轮范围 | 由 QA-1 负责；我未把 `test.sh` 通过当作 P0-06 证据 |

---

## 7. 环境事实（实测，供 v4 文档核对）

我的独立探针同样显示 `symlink` / `rename` / `unlink` 全部 rc=0，**v4 结论正确**，v3 禁用清单已过期。

| 操作 | 实测 |
|---|---|
| `symlink` / `rename` / `unlink` | rc=0 ✅ |
| `mkdir`（父不存在） | ENOENT(2)，需逐级 |
| `mkdirat` 逐级 | ✅ |
| `copyfile(DATA\|CLONE)` dst 已存在 | **EEXIST(17)** |
| `copyfile(DATA)` dst 已存在 | rc=0 可覆盖 ✅ |
| `utimensat` / `ftruncate` / `open(O_CREAT\|O_RDWR)` | ✅ |
| 文件系统 | `apfs` |

「固定文件名残留」坑我这边也踩过（第二轮 `symlink` EEXIST(17)），已在探针加 `unlink()` 前置清理 + 每轮 `rm -rf .tmp/test-scratch`，结论不变。

---

## 8. 最终路由判定：**NoOne**（全部通过）

- `build.sh` → 0；`test.sh` → 178/178，EXIT=0（含静态合规扫描 + 真实 `.app` i18n 验收）
- 独立探针 `./.tmp/VerifyT04 all` → **270 通过 / 0 失败**
- 8 个专项诊断全部 0 失败：`sparsediag 4/4`、`samplerdiag 4/4`、`xattrdiag 3/3`、`progdiag 6/6`、`enginenew 14/14`、`dtype 3/3`、`symlink 1/1`、`clonevar2 1/1`
- **BUG-01 ~ BUG-06 全部关闭，遗留缺陷 0 个**
- **Q1/Q2/Q3 亦已全部闭环**（主理人裁决 A / PM 补 PRD 附录 A / 记录为 P1 待明确项），无未决事项
- 主理人已确认采信最终回归 270/270 + 178/178 与路由 `NoOne`，T04 线收尾

按「最多 2 轮」规则：第 1 轮发现 BUG-01/02 → 修复；第 2 轮发现 BUG-03~06 → 修复并回归全绿。未在修复后开展第 3 轮扩大测试，仅做一次有界的复跑验证，到此收尾。

---

## 9. 复现方式

```bash
cd <workspace>
swiftc -O -target arm64-apple-macos13.0 -sdk $(xcrun --show-sdk-path) \
  -module-cache-path "$PWD/.tmp/modcache-t04" \
  -I MacCopy/.build -L MacCopy/.build -lMacCopyKit \
  -Xlinker -rpath -Xlinker "$PWD/MacCopy/.build" \
  probe/t04/*.swift -o .tmp/VerifyT04

rm -rf .tmp/test-scratch
./.tmp/VerifyT04 all          # 270 通过 / 0 失败
./.tmp/VerifyT04 sparsediag   # BUG-03 回归 4/4
./.tmp/VerifyT04 samplerdiag  # BUG-04 回归 4/4
./.tmp/VerifyT04 xattrdiag    # BUG-05 回归 3/3
./.tmp/VerifyT04 progdiag     # BUG-06 回归 6/6
./.tmp/VerifyT04 dtype        # BUG-01 回归 3/3
./.tmp/VerifyT04 symlink      # BUG-02 回归 1/1
./.tmp/VerifyT04 enginenew    # 新增改动回归 14/14
./.tmp/VerifyT04 clonevar2    # Q1 平台行为记录
```

---

## 10. 最终回归记录（v2 新增）

工程师修复 BUG-03~06 后，我按「一次有界复跑」执行：

| 项目 | 修复前 | 修复后 |
|---|---|---|
| 独立探针 `all` | 264 通过 / 6 失败 | **270 通过 / 0 失败** |
| `SparseProbe` 空洞 | 3 段（错），总 33,570,816 | **2 段（对），总 67,076,096** |
| 稀疏复制目标占用 | 32 MiB，内容不一致 | **32 KiB，内容逐字节一致** |
| `SpeedSampler` 0.2s×20 次 | 1 个采样点，速度 0.0 | **采样点 ≥3，速度 >0，ETA 非 nil** |
| `copyExtendedAttributes` | 返回 0，xattr 全丢 | **复制成功，目标端读回正确值** |
| `progress.completedFiles` | 0，`fileFraction=0.0` | **5，`fileFraction=1.0`** |
| `test.sh` | 123/123（未覆盖上述缺陷） | **178/178**（新增 6 个 BUG 回归 + i18n 验收） |

未修改 `src/` 下任何源码。
