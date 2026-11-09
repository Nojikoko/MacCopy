# T04 进度记录（IO 层与复制引擎）

> 状态：**已完成**。最后更新：2026-11-08
> 代码位置：`<workspace>/MacCopy/`

## 1. 交付状态

| 项 | 结果 |
|---|---|
| 构建 | `bash build.sh` → 零 error、零 warning（Swift 6 严格并发） |
| 测试 | T04 交付时 **105/105**；后续 T04 遗留补齐后 **123/123 通过**，退出码 0 |
| BLAKE3 吞吐 | 1.086–1.135 GB/s（Q3 门槛 ≥1.0 GB/s）✅ |
| 全局一致性审查 | **IS_PASS: YES** |

### 禁用 API 表述更正（主理人裁决）

T04 报告里写的「禁用 API grep 命中数 = 0」**不准确**。准确表述是：

> 目录项操作在**路径白名单内可用**，生产代码采用「**优先原子路径 + 降级路径**」双准备；
> `link`（硬链接）与 `setxattr`/`fsetxattr` 真正不可用，且生产代码**未使用**。

实测环境中的真实调用点（`rename` / `unlink` / `moveItem` / `removeItem`）均集中在
持久化原子写与 `.partial` 提交路径，且都带降级覆盖写。详见
`docs/ENV-FS-CONSTRAINTS.md` v5 与 `docs/T05-PROGRESS.md`。

## 2. 文件清单

### 2.1 IO 层（6 个文件，`src/MacCopyKit/IO/`）

| 文件 | 职责 |
|---|---|
| `PathWalker.swift` | 长路径逐级 openat/mkdirat、目录枚举、逐级建目录 |
| `FileDescriptor.swift` | fd 生命周期封装 + `Syscall`（errno 纪律） |
| `CopyfileBridge.swift` | copyfile/fcopyfile 封装，CLONE→EEXIST→DATA 回退 |
| `MetadataOps.swift` | stat / futimens / utimensat / xattr / chmod |
| `SparseProbe.swift` | SEEK_HOLE / SEEK_DATA 空洞探测 |
| `VolumeInspector.swift` | 文件系统类型、可用空间、同卷判定 |

### 2.2 Engine 层（13 个文件，`src/MacCopyKit/Engine/`）

| 文件 | 职责 |
|---|---|
| `CopyEngine.swift` | actor 编排核心：接任务 → 分批消费 → 并发 worker → 发 TransferEvent |
| `PlanBuilder.swift` | 源枚举 → 分批 FileEntry 计划（Q-A8 内存控制） |
| `FileEnumerator.swift` | 目录递归枚举、符号链接处理、稀疏探测 |
| `StreamCopier.swift` | read/write + tee 哈希 + 短读短写处理 |
| `CloneCopier.swift` | APFS 克隆路径判定与执行 |
| `Verifier.swift` | 校验编排：tee / 回读 / Q5 降级判定 |
| `ResumeManager.swift` | 断点元数据、续传判定、copyfile 提交、7 天过期标注 |
| `ConflictResolver.swift` | 四种冲突策略 + 询问决策器注入 |
| `SparseHandler.swift` | 稀疏策略判定与结论 |
| `TimestampPreserver.swift` | 时间戳保留 + 精度降级声明 |
| `RetryPolicy.swift` | 退避计算与可重试判定 |
| `ProgressTracker.swift` | 字节/文件双口径进度聚合 |
| `SpeedSampler.swift` | 1 Hz 环形采样 + ETA 外推 |

### 2.3 测试（新增 2 个文件）

- `Tests/IOTests.swift` —— 17 条
- `Tests/EngineTests.swift` —— 17 条

### 2.4 残留物说明（供 QA 不要误判）

`src/MacCopyKit/Checksum/XX*`（6 个无扩展名文件）是 T01 阶段 `perl -pi` 编辑被沙盒拦截产生的残留物。
**无 `.swift` 扩展名 → 不参与构建**（`find -name '*.swift'` 不会收集），内容已改写为说明文字。
删除操作被沙盒拒绝（`SAFE_DELETE_BULK_GUARD_ERROR`），**不是代码缺陷**。

## 3. T04 期间发现并修复的 6 个实质缺陷

### 3.1 `copyfile_state` 在 CLONE 失败后被污染（最隐蔽）

**现象**：CLONE 失败（EEXIST=17）后，**复用同一个 state** 做 DATA 回退会返回 **EINVAL(22)**。

**实测证据**：
```
copyfile(CLONE) dst不存在 → rc=0，真 CoW（wasCloned=1）
copyfile(CLONE) dst已存在 → rc=-1 errno=17(EEXIST)
copyfile(DATA, 同一 state) → rc=-1 errno=22(EINVAL)   ← state 被污染
copyfile(DATA, 新 state)   → rc=0，内容正确
```

**修复**：`CopyfileBridge.commit` 的 DATA 回退**必须用全新的 state（或 nil）**。

### 3.2 `dirent.d_type` 的 `DT_*` 常量值必须用 Darwin 原值

**现象**：我最初自造了 `DirectoryEntryType` = 1…7，但 Darwin 实际是
`DT_UNKNOWN=0 DT_FIFO=1 DT_CHR=2 DT_DIR=4 DT_BLK=6 DT_REG=8 DT_LNK=10 DT_SOCK=12`。
导致 `DT_DIR`(4) 被误判为「未知/普通文件」→ **目录的 `st_size`（APFS 上是 99）被当成文件大小**，
PlanBuilder 统计出 `totalBytes=99`（应为 6），且子目录文件因父目录未被识别而复制失败。

**修复**：常量改为 Darwin 原值，并在代码注释里写明「必须与 Darwin 完全一致」。

### 3.3 `mkdir(绝对路径)` 受 PATH_MAX 限制 → 长路径建目录失败

**现象**：40 级中文长路径（>1024 字节）用 `mkdir` 逐级创建时，
最后一级返回 ENAMETOOLONG。

**修复**：改用 **`openat` + `mkdirat`**（只传单级分量，≤255 字节），
彻底绕开 PATH_MAX。`openFile` 也相应加了长路径分支（逐级 openat 到父目录再 openat 文件）。

### 3.4 `ChecksumAlgorithmID` 作字典键时 JSON 编码失败

**现象**：`ResumeRecord.partialDigests` 是 `[ChecksumAlgorithmID: String]`，
而 `JSONEncoder` 对非 String/Int 键的字典会编码成**数组** → 回读时 decode 失败 → **记录被静默丢弃**。

**修复**：`ChecksumAlgorithmID` 遵循 `CodingKeyRepresentable`。

### 3.5 批次边界把父目录与子文件切到不同批次 → 子文件复制失败

**现象**：PlanBuilder 每批 512 条，批次边界可能把「目录」和「它的子文件」切开，
后者因父目录尚未建立而 `open` 失败。

**修复**：`CopyEngine` 改为**每批先建全部目录、再处理文件**（原来是一边遍历一边建）。

### 3.6 `write` 可能短写，测试辅助函数没处理

**现象**：测试里 `_ = write(fd, buf, n)` 忽略了返回值，短写时内容不完整。

**修复**：测试辅助函数改为循环写满（生产代码 `StreamCopier` 本来就正确处理了短写）。

## 4. 遵循 v3 约束的实现要点

| 约束 | 实现 |
|---|---|
| 禁用 `rename` | `.partial` → 正式名用 `copyfile`（CLONE→EEXIST→DATA 回退） |
| 禁用 `unlink` | `.partial` **不删除**；`ResumeManager.stalePartials()` 按 7 天过期标注 + 给路径 |
| 追加写可用 | `open(O_WRONLY\|O_CREAT)`（**无 O_TRUNC**）+ `lseek(SEEK_END)` |
| `ftruncate` 可用 | `ResumeManager.resetPartial()` 用 `ftruncate(fd, 0)` 重置分片 |
| 稀疏完整可用 | `open(O_CREAT\|O_RDWR)` + `ftruncate` + SEEK_HOLE 探测，**无降级分支** |
| 时间戳有路径 | `futimens(fd)` 优先，回退 `utimensat(AT_FDCWD, path, &ts, 0)` |
| 逐级建目录 | `openat` + `mkdirat`（单级分量） |
| `errno` 纪律 | 全部经 `Syscall.call`（内部先 `errno = 0` 再调用再立即读） |

## 5. 复现命令

```bash
cd <workspace>/MacCopy
bash build.sh     # 构建 3 个 target
bash test.sh      # 105 个用例
```

## 6. 未完成 / 下一步

- **T05**：UI 层（NavigationSplitView 三栏、进度面板、校验结果、Pro 锁定态）、Service 集成、端到端联调。
- **P1 待办**（架构已列，本轮未做）：checksum 清单文件落盘到目标目录、复制后动作（PostAction）、
  速率限制（`bandwidthLimitBytesPerSecond` 目前只是配置项，未在 StreamCopier 里生效）、
  `TaskQueueStore` 与 `CopyEngine` 的接驳（队列里的待恢复任务还没接到引擎上）。
