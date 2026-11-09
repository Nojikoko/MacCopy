# 文件系统能力实测约束 —— 工程师复核修正版

> 本文是**工程师（寇豆码）在 T04 开工前用独立探针二进制复测**的结果。
> 修正了 `ENV-FS-CONSTRAINTS.md` 中因**未重置 `errno`** 导致的误判。
> **以本文为准。**

## 0. 根因：探针未在系统调用前重置 `errno`

`errno` 是**线程局部**变量，只有失败时才被写入。成功的调用**不会**清零它。

实测证据：

```
刚失败后 errno=2 (ENOENT)
setxattr rc=0  未重置 errno → errno=2   ← 陈旧值假象！被误判为「失败」
setxattr rc=0  已重置 errno → errno=0   ← 实际成功
```

所以主理人探针里 `setxattr` / `open(O_RDWR)` / `rename` 报出的 ENOENT(2)，
是**上一次失败调用残留的 errno**，而非本次调用的真实结果。

**正确做法**（已落实到所有生产代码）：
```swift
errno = 0
let rc = someSyscall(...)
let code = errno     // 必须在调用后立即读取
```

## 1. 修正后的实测矩阵

| 系统调用 | 结果 | errno | 与主理人文档的差异 |
|---|---|---|---|
| `mkdir(path, mode)` | ✅ **成功** | 0 | 一致（但**父目录必须存在**，即需逐级创建） |
| `mkdir`（父不存在） | ❌ 失败 | ENOENT(2) | 主理人未记录此限制 |
| `open(path, O_CREAT\|O_WRONLY, 0644)` | ✅ 成功 | 0 | 一致 |
| `open(path, O_WRONLY\|O_TRUNC, 0644)`（已存在） | ✅ 成功 | 0 | 一致 |
| `open(path, O_CREAT\|O_RDWR, 0644)` | ✅ **成功** | 0 | ⚠️ **主理人误判为失败** |
| `write()` | ✅ 成功 | 0 | 一致 |
| `fsync()` | ✅ 成功 | 0 | 一致 |
| `ftruncate(fd, size)`（fd 已 O_RDWR 打开） | ✅ 成功 | 0 | 新增（稀疏文件前提） |
| `lseek(fd, 0, SEEK_END)` | ✅ 成功 | 0 | 新增（续传定位） |
| `open(path, O_WRONLY\|O_CREAT)` 打开已存在文件 → 追加写 | ✅ **成功** | 0 | 新增（**主理人要求确认的组合**） |
| `copyfile(src, dst, nil, COPYFILE_DATA)` | ✅ 成功（dst 可已存在，会被覆盖） | 0 | 一致 |
| `copyfile(src, dst, nil, COPYFILE_DATA\|COPYFILE_CLONE)`，**dst 不存在** | ✅ 成功，`wasCloned=1` | 0 | 新增（CoW 生效） |
| `copyfile(src, dst, nil, COPYFILE_DATA\|COPYFILE_CLONE)`，**dst 已存在** | ❌ **失败** | **EEXIST(17)** | ⚠️ **主理人实测有误** |
| `copyfile(src, dst, nil, COPYFILE_DATA)`，dst 已存在 | ✅ 成功并覆盖 | 0 | 新增（**CLONE 的回退路径**） |
| `fcopyfile(fdSrc, fdDst, state, DATA\|CLONE)` | ✅ 成功 | 0 | 一致 |
| `copyfile_state_get(WAS_CLONED)` | ✅ 可读 | — | 一致 |
| `openat()` 逐级下降 | ✅ 成功 | 0 | 新增（**需目录真实存在**） |
| `SEEK_HOLE` / `SEEK_DATA` | ✅ 可用 | 0 | 新增（稀疏探测） |
| `statfs()` | ✅ 成功，`f_fstypename` = "apfs" | 0 | 一致 |
| `futimens(fd, times)` | ✅ 成功 | 0 | 一致 |
| `stat()` → `st_birthtimespec` | ✅ 可读 | 0 | 一致 |
| `Data.write(to:)` | ✅ 成功 | — | 一致 |
| `setxattr()` | ✅ **成功** | 0 | ⚠️ **主理人误判为失败** |
| `rename(src, dst)` | ❌ 失败 | **EPERM(1)** | ⚠️ errno 是 EPERM 非 ENOENT |
| `unlink(path)` | ❌ 失败 | EPERM(1) / ENOENT(2) | ⚠️ errno 与主理人不同 |
| `Data.write(to:options:.atomic)` | ❌ 失败（内部 temp+rename） | — | 一致 |
| `FileManager.moveItem` / `removeItem` | ❌ 失败 | — | 一致 |

## 2. 对 T04 实现策略的关键修正

### 2.1 `.partial` → 正式文件名的正确解法（**不是主理人文档的写法**）

主理人文档建议：
```swift
copyfile(partialPath, finalPath, nil, UInt32(COPYFILE_DATA | COPYFILE_CLONE))
```
**实测这在 `finalPath` 已存在时失败（EEXIST=17）**，而 `.partial` 提交场景下
`finalPath` 很可能已存在（冲突策略 = 覆盖）。若照此实现，**覆盖复制会直接报错**。

正确实现（**先试 CLONE，失败回退 DATA**）：
```swift
// 首选：CoW 克隆（dst 不存在时最快）
var flags = UInt32(COPYFILE_DATA | COPYFILE_CLONE)
errno = 0
var rc = copyfile(src, dst, nil, flags)
if rc != 0 {
    // 回退：dst 已存在时 CLONE 会 EEXIST，改用 DATA 可覆盖
    let cloneErrno = errno
    errno = 0
    flags = UInt32(COPYFILE_DATA)
    rc = copyfile(src, dst, nil, flags)
    if rc != 0 { /* 记录 errno，标记失败 */ }
}
```
实测：`DATA|CLONE` → EEXIST(17) → 回退 `DATA` → rc=0，内容正确。

### 2.2 续传追加写：**已实测确认可用**（主理人要求确认的组合）

```
open(O_WRONLY|O_CREAT) 已有文件 rc=6 errno=0     ← 成功打开
SEEK_END=10                                     ← 定位到已有字节末尾
最终 size=12 (期望 12)                          ← 追加写成功
```

**结论**：`O_WRONLY`（不带 `O_TRUNC`）打开已存在文件后**可以正常追加写**。
续传实现：
```swift
let fd = open(partialPath, O_WRONLY | O_CREAT, 0o644)   // 绝不要 O_TRUNC
let end = lseek(fd, 0, SEEK_END)                          // 定位到已有字节末尾
// 从 source 的 end 偏移继续读，写入 fd
```

### 2.3 稀疏文件：**完全可用**，无需降级

主理人文档说 `open(O_CREAT|O_RDWR)` 失败 → 稀疏无法创建。**实测这是 errno 陈旧假象**。

```
open(O_CREAT|O_RDWR) rc=5 errno=0     ← 成功
ftruncate(64MiB) rc=0 errno=0         ← 成功
size=67108864 allocated=16384 稀疏=true   ← 64MiB 逻辑大小仅占 16KiB
SEEK_HOLE=16384 SEEK_DATA=0            ← 空洞探测正常
```

`SparseHandler` 可以**完整实现**稀疏保留，PRD P0-12 的「10GiB 复制后 ≤1GiB」
在本机**可验证**（不再需要标注「环境受限未验证」）。

### 2.4 `setxattr` 可用 → xattr 保留可实现

`setxattr` 实际成功。xattr 保留（如 macOS 的 `com.apple.quarantine`、
资源叉 `com.apple.ResourceFork`）可以正常实现。

### 2.5 `mkdir` 需逐级创建

`mkdir` 本身可用，但**父目录必须存在**（返回 ENOENT）。所以「创建多级目录」
必须逐级 `mkdir` + `openat`，不能一次 `mkdir -p`。
这正好与 `PathWalker` 的逐级下降设计吻合：**逐级 openat 遇到 ENOENT 就 mkdir 该级**。

### 2.6 `rename`/`unlink` 禁用（结论不变）

errno 实测 **EPERM(1)**（`unlink` 对不存在的文件返回 ENOENT(2)）。
这是 OS 级守卫（沙盒内外一致）。禁用清单不变：
`rename` / `unlink` / `link` / `unlinkat` / `Data.write(.atomic)` /
`FileManager.moveItem` / `FileManager.removeItem`

**影响**：`.partial` 无法删除 → 清理策略改为「按元数据过期判定 + UI 标注 + 给路径」，
与主理人文档一致。

## 3. 额外发现：Swift API 签名坑

| API | 坑 |
|---|---|
| `statfs().f_fstypename` | 是 **16 元组 C 数组**，不是指针。需 `withUnsafeBytes(of:)` 取 |
| `copyfile_state_set` 第三参 | `UnsafeRawPointer`（不是 Int32）。需 `UnsafeRawPointer(p)` 转换 |
| `copyfile_state_get` 第三参 | `UnsafeMutablePointer<Int32>` |
| `fcopyfile` 路径参数 | 是 **Int32 fd**（不是 String 路径）。`copyfile` 才是 String |
| `copyfile` flags | `COPYFILE_*` 常量是 Int32，`copyfile_flags_t` 是 UInt32，**必须显式 `UInt32(...)`** |
| `open()` 返回 | Darwin 的 `open` 返回**非可选 Int32**，不能 `!` 解包 |

## 4. 最终禁用/可用清单

**禁用**：`rename` / `unlink` / `link` / `unlinkat` / `Data.write(options:.atomic)` /
`FileManager.moveItem` / `FileManager.removeItem`

**可用**：`mkdir`（逐级）/ `open` / `write` / `fsync` / `ftruncate` / `lseek` /
`copyfile` / `fcopyfile` / `copyfile_state_*` / `openat` / `fstat` / `statfs` /
`futimens` / `setxattr` / `SEEK_HOLE` / `SEEK_DATA`
