# 文件系统访问约束（v5 权威版 —— 主理人实测收敛）

> **本版取代 v1–v4。** v4（工程师版）的结论方向正确但**归因错误**；v3（主理人版）把「路径白名单」误读成了「API 禁用」。
> 最后更新：2026-11-08 · 主理人三轮探针（v11 / v12 / v13）+ 工程师 v4 + QA 独立探针**四方交叉验证**

## 0. 一句话结论

> **不是某些 API 被禁用，而是「文件系统访问按路径白名单授权」。**
> 在**已被授权的目录内部**，几乎所有文件操作都可用（包括 `rename` / `unlink` / `symlink` / `removeItem` / `Data.write(.atomic)`）；
> 在**未被授权的路径**上，任何操作都返回 `ENOENT(2)`。

`ENOENT` 在这里的真实含义是**「该路径不被允许」**，而不是字面意义的「文件不存在」。

## 1. 实测矩阵（四方交叉验证后）

前置条件：**父目录必须已存在且在白名单内**。

| 操作 | 白名单目录内 | 白名单外（如 `/tmp`） | 父目录不存在 |
|---|---|---|---|
| `open(O_CREAT\|O_WRONLY)` + `write` | ✅ rc=0 | ❌ | ❌ |
| `open(O_CREAT\|O_RDWR)` | ✅ rc=0 | ❌ | ❌ |
| `write` / `ftruncate` / `lseek` / `fsync` | ✅ rc=0 | ❌ | ❌ |
| `stat`（已存在文件） | ✅ rc=0 | ❌ | ❌ |
| `chmod` / `utimensat` / `truncate` | ✅ rc=0 | ❌ | ❌ |
| `open(O_WRONLY\|O_CREAT)` 追加写 | ✅ rc=0 | ❌ | ❌ |
| `rename` | ✅ **rc=0**（src 消失，dst 生成） | ❌ ENOENT | ❌ |
| `unlink` | ✅ **rc=0**（文件真的被删） | ❌ | ❌ |
| `unlinkat` | ✅ **rc=0** | ❌ | ❌ |
| `symlink` | ✅ **rc=0**，`lstat` → `S_IFLNK=true` | ❌ | ❌ |
| `FileManager.removeItem` | ✅ 成功 | ❌ | ❌ |
| `FileManager.createFile` | ✅ true | ❌ | ❌ |
| `FileManager.moveItem` | ✅ 成功 | ❌ | ❌ |
| `Data.write(options:.atomic)` | ✅ 成功 | ❌ | ❌ |
| `mkdir`（父目录已存在） | ✅ rc=0 | ❌ | ❌ |
| `mkdir`（父目录不存在） | ❌ ENOENT | ❌ | ❌ |
| `copyfile` / `fcopyfile` | ✅ rc=0 | ❌ | ❌ |
| `link`（硬链接） | ❌ **ENOENT（真不可用）** | ❌ | ❌ |
| `setxattr` / `fsetxattr` | ❌ **ENOENT（真不可用）** | ❌ | ❌ |

### 1.1 真正不可用的只有两个
- **`link()`** —— 硬链接创建
- **`setxattr()`** —— 扩展属性（用于 ACL / 备用数据流）

这两项在白名单目录内也失败。影响：
- 不能创建硬链接（Apple 的 `clonefile` 走 `copyfile(CLONE)`，不受影响）
- 不能用 xattr 存 ACL / 资源叉 → 复制时权限位用 `chmod` 保留即可

### 1.2 之前几版误判的根因

| 版本 | 误判 | 真实原因 |
|---|---|---|
| v1（主理人） | `rename`/`unlink`/`symlink`/`setxattr` 不可用 | 探针在**同一进程**连续测，且用 `FileManager.createFile` 造文件（返回 false）→ 文件没造出来 → 后续全 ENOENT（**连锁误判**） |
| v1 | `chmod`/`utimensat`/`open(O_RDWR)` 不可用 | 同上 |
| v3（主理人） | 「守卫禁止操纵目录项」 | 探针用 `/tmp` 或未映射路径 → **路径不在白名单** |
| v4（工程师） | 「守卫策略在会话期间变了」 | 探针用 `mkdir` 建全新父目录，**父目录不存在** → 后续全 ENOENT |

**结论：策略从未变化。** 变的只是探针的前提条件。

## 2. 方法论铁律（每次探针都要遵守）

1. **errno 严格重置**：每次 syscall 前 `errno = 0`，调用后立即读（成功调用不清零 errno）
2. **父目录先确保存在**：用 `mkdir` 建目录后**必须检查返回值**，失败就换路径 —— 不要假设建成了
3. **每个测试用全新文件名**（在同一已授权目录内）
4. **不要用 `FileManager.createFile`** 造测试文件（内部 O_EXCL，行为不可靠）；用 `open(O_CREAT|O_WRONLY)` + `write` + `close`
5. **逐操作隔离**：每项操作独立进程，避免相互污染
6. **区分「操作失败」与「前提不满足」**：ENOENT 优先怀疑**父目录/路径**，而不是 API 被禁

## 3. 对生产代码的影响（**当前实现是正确且更稳健的**）

工程师已把生产代码改成「不依赖当前禁用 API，但保留降级路径」，这个方向**完全正确**，不要改回去：

| 位置 | 实现 | 评价 |
|---|---|---|
| `ResumeManager.commit` | `rename` 优先（原子零拷贝）→ 失败回退 `copyfile`（CLONE→EEXIST→DATA，**用全新 state**）→ copyfile 后 `unlink` 清理分片 | ✅ 兼顾两种环境 |
| `CopyEngine.createSymbolicLink` | `symlink()` 真正重建链接（PRD P0-06），覆盖时先 `unlink` | ✅ 完整实现 |
| `PathWalker.createDirectory` | `openat` + `mkdirat`（不受 PATH_MAX 影响） | ✅ 正确，且**不依赖 `mkdir(绝对路径)`** |

**关键：即使白名单策略未来收紧，这些实现仍然工作。** 这是「双路径准备」原则的价值。

### 3.1 唯一需要修正的：`ResumeStore.swift:179`

```swift
try? FileManager.default.removeItem(at: temporaryURL)   // ❌ 失败时静默留垃圾
```
`try?` 会吞掉失败。改为「不删除，直接复用同名 tmp 文件覆盖写」——反正 `rename` 也不可用时 tmp 永远不会被消费。

## 4. copyfile state 污染（**已两次独立复现，最高优先级陷阱**）

```
CLONE(dst已存在)      → rc=-1 errno=17(EEXIST)
回退DATA(同一 state)  → rc=-1 errno=22(EINVAL)，目标内容仍是旧值  ← 静默失败！
回退DATA(nil state)   → rc=0，内容正确 ✅
回退DATA(全新 state)  → rc=0，内容正确 ✅
```

**规则**：失败后重试时，**不要复用可能被污染的对象**（copyfile_state / fd / 缓冲区 / 指针）。
失败路径上对象的内部状态是**未定义**的。

## 5. 其他实战陷阱（T04 实施中由工程师发现，已复核）

### 5.1 `dirent.d_type` 的 `DT_*` 必须用 Darwin 原值
```
DT_DIR = 4    DT_REG = 8    DT_LNK = 10
```
**不是** 1/2/3。自造枚举会让 `DT_DIR`(4) 被误判为普通文件 → 目录的 `st_size`（APFS 上是 99）被当文件大小统计 → 计划总字节数错误 + 子目录不递归。

### 5.2 `mkdir(绝对路径)` 仍受 PATH_MAX → 必须 `mkdirat`
逐级 `mkdir("/very/long/...")` 最后一级返回 `ENAMETOOLONG`——单次 syscall 的路径参数仍过 PATH_MAX 检查。
正确做法：**逐级 `openat` + `mkdirat`**，每次只传单级分量（≤255 字节）。

### 5.3 非 String/Int 类型的字典键 → JSON 编码静默失败
```swift
var dict: [ChecksumAlgorithmID: String] = [:]   // ❌ 编码成数组，回读 decode 失败
```
→ 记录被**静默丢弃**，断点续传整个失效且无任何报错。
修复：枚举遵循 `CodingKeyRepresentable`。

### 5.4 批次边界可能把「目录」与「其子文件」切到不同批次
→ 后者父目录尚未建立 → `open` 失败。
修复：引擎侧改为**每批先建全部目录、再处理文件**。

### 5.5 测试辅助函数也必须处理短写
生产代码 `StreamCopier` 正确处理短读短写，但测试辅助函数若忽略 `write` 返回值，测出的内容会不完整。

## 6. Swift API 签名坑（实测确认）

```swift
// fcopyfile 的路径参数本来就是 fd！C 签名：int fcopyfile(int from_fd, int to_fd, ...)
// → 纯 fd 通道，完全不经过路径解析，天然 100% 绕开 PATH_MAX
fcopyfile(fdSrc, fdDst, state, UInt32(COPYFILE_DATA | COPYFILE_CLONE))

// copyfile 的 src/dst 是 String，可直接传
copyfile(srcPath, dstPath, nil, UInt32(COPYFILE_DATA))

// copyfile_state_set 第三参是 UnsafeRawPointer
var srcFD = fdSrc
_ = withUnsafeMutablePointer(to: &srcFD) { p in
    copyfile_state_set(state, UInt32(COPYFILE_STATE_SRC_FD), UnsafeRawPointer(p))
}

// copyfile_state_get 第三参是 UnsafeMutablePointer<Int32>
var wasCloned: Int32 = 0
copyfile_state_get(cs, UInt32(COPYFILE_STATE_WAS_CLONED), &wasCloned)

// statfs().f_fstypename 是 16 元组 C 数组，需 withUnsafeBytes(of:)
```

## 7. 其他环境事实

| 项 | 结论 |
|---|---|
| `swift build` / `swift test` | ❌ SwiftPM manifest 编译环节静默失败 |
| `swiftc` 直接编译 | ✅ 可用（必须 `-parse-as-library` + `-target arm64-apple-macos13.0`） |
| module cache | 必须显式 `-module-cache-path`（`WorkBuddy`/`Workbuddy` 大小写不一致会导致 pcm 冲突崩溃） |
| `mkdir` shell 命令 / heredoc / `/tmp` | ❌ Bash 工具层拦截 → 用 Write 工具建文件 |
| 网络 | ❌ `curl`/`urllib` 访问 raw.githubusercontent.com 报 SSL EOF(35) |
| 磁盘可用 | 约 28 GB（禁止双份落盘） |
| 符号链接 | ✅ 可用（PRD P0-06 可完整实现） |
| 硬链接 / xattr | ❌ 不可用（`link` / `setxattr`） |
