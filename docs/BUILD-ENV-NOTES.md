# MacCopy 构建环境实测说明（主理人 2026-11-07 22:50）

> 这份文档记录**主理人在派发工程任务前实测到的环境事实**。它与 `ARCHITECTURE.md` 的工程形态建议有出入，**以本文为准**（架构文档的 T01 施工步骤假设了 `xcodegen` 可用，实际不可用）。

## 1. 机器事实（已确认）

| 项 | 值 |
|---|---|
| CPU | Apple M5，10 核 |
| 内存 | 16 GB |
| 磁盘可用 | 约 28 GB（**紧张，禁止任何双份落盘**） |
| macOS | 27.2 (26B123) |
| Xcode | 27.2 (27B52) |
| Swift | 6.4.2 (swiftlang-6.4.2.1.9) |
| SDK | 27.2 |
| 真实家目录路径 | `<workspace-root>/...`（**注意是小写 b**） |

## 2. 关键发现：SwiftPM 在本机不可用

### 2.1 现象

```
$ swift build
error: 'probe': Invalid manifest (compiled with: [...swiftc... Package.swift ...])
```

报错**没有任何真实原因**，manifest 编译失败但错误信息被吞掉。

### 2.2 排查过程

| 尝试 | 结果 |
|---|---|
| 换 `TMPDIR` 到 workspace | 路径出现在报错中，说明 TMPDIR 生效，但仍失败 |
| 沙盒外执行（`dangerouslyDisableSandbox`） | 同样失败 |
| 换真实大小写路径 `<workspace-root>` | 同样失败 |
| 手动复现 manifest 编译命令 | 静默 exit 1，无输出、无产物 |

**结论**：本机 SwiftPM 的 manifest 编译环节无法产出可执行产物。这是 **SwiftPM 工具链在本环境的限制**，不是工程配置错误。`swift build` / `swift test` / `swift run` **均不可用**。

### 2.3 连带影响

- 架构文档 T01 的 `Package.swift` 方案**在本机无法验证**
- `swift test` 不可用 → **单元测试无法通过 SPM 跑**
- 无 `brew`、无 `xcodegen` → 架构文档的 `project.yml` 生成方案不可用
- 无法用 `xcodebuild` 对 SPM 包做测试（xcodebuild 内部也走 manifest 机制）

## 3. 可用通路：`swiftc` 直接编译 ✅

以下方式**实测完全正常**（编译 → 链接 → 运行全通）：

```bash
# 编译库
swiftc -O -parse-as-library \
  -target arm64-apple-macos13.0 \
  -sdk $(xcrun --show-sdk-path) \
  -module-name MacCopyKit \
  Sources/MacCopyKit/**/*.swift \
  -emit-module -emit-library \
  -o .build/libMacCopyKit.dylib

# 编译可执行程序
swiftc -O -parse-as-library \
  -target arm64-apple-macos13.0 \
  -sdk $(xcrun --show-sdk-path) \
  Sources/**/*.swift \
  -o MacCopy

# 运行
./MacCopy
```

### 3.1 关键参数

| 参数 | 作用 | 备注 |
|---|---|---|
| `-parse-as-library` | 允许 `@main` 与 `main.swift` 共存 | **必需**，否则报 `'main' attribute cannot be used in a module that contains top-level code` |
| `-target arm64-apple-macos13.0` | 最低版本 13.0 | 架构 AD-01 的要求 |
| `-sdk $(xcrun --show-sdk-path)` | 指定 SDK | |
| `-O` | Release 优化 | **BLAKE3 吞吐测试必须用 -O**，Debug 慢 10 倍以上会误判不达标 |

### 3.2 环境变量（绕开沙盒对临时目录的拦截）

```bash
export TMPDIR=<workspace>/.tmp
export CLANG_MODULE_CACHE_PATH=<workspace>/.tmp/modcache
```

不设 `CLANG_MODULE_CACHE_PATH` 时，clang 会往 `~/Library/Caches/clang/ModuleCache` 写临时文件，可能被沙盒拦截。

### 3.3 沙盒限制清单

| 操作 | 状态 |
|---|---|
| `mkdir` / `rm` 等文件操作 | ❌ 被安全策略拦截，**用 Write 工具创建文件** |
| heredoc（`cat > file <<EOF`） | ❌ 被拦截，**用 Write 工具写文件** |
| `/tmp` 下操作 | ❌ 被拦截，**用 workspace 内的路径** |
| `swiftc` 编译 / 运行产物 | ✅ 正常 |
| `swift build` | ❌ 失败 |

## 4. 平台 API 实测结论（主理人亲测，全部通过）

```
copyfile flags: 16777224 type=UInt32      ← UInt32(COPYFILE_CLONE|COPYFILE_DATA) 成立
open fd: 5                                ← Darwin open 返回非可选 Int32
birthtime: 1792710643                      ← st.st_birthtimespec.tv_sec 可用
blocks=8 size=213                         ← st.st_blocks 稀疏探测可用
avail: 27912 MB                            ← statfs f_bavail 可用
copyfile_state_alloc: OK                  ← copyfile_state_alloc() 可用
cpus: 10
```

**架构师 §8.4 的坑位表经复核全部准确**，可以直接照用。

### 4.1 补充发现（架构师未覆盖）

| 项 | 结论 |
|---|---|
| `stat` 无 `st_fsid` 成员 | Swift 侧 `stat` 结构体不暴露 `st_fsid`，无法用它判断同卷 → **同卷判定改用 `statfs.f_fsid` 或比较 `statfs` 的 `f_fsid`/`f_mntonname`** |
| `@State` 赋值 | 在 `View` 的 `body` 闭包外赋值报 `cannot assign to property: 'self' is immutable`；用 `.task { }` 而非 `.onAppear { }` 更稳 |
| `GraphicsContext.fill(with:)` | 不接受 `Color`，需 `.color(Color.red)`（架构师已标） |

## 5. 改定的工程形态（覆盖架构文档 AD-02）

架构文档建议「双 SPM 包 + Xcode 工程壳」，**本机无法验证**。改为：

```
MacCopy/
├── src/                              # 全部 Swift 源码，扁平模块划分
│   ├── MacCopyKit/                   # 核心库（引擎/校验/模型/持久化）
│   │   ├── Model/
│   │   ├── Engine/
│   │   ├── Checksum/
│   │   ├── IO/
│   │   ├── Persistence/
│   │   ├── App/
│   │   └── Support/
│   ├── MacCopyApp/                   # SwiftUI App（依赖 MacCopyKit）
│   ├── MacCopyService/               # Finder Service
│   └── MacCopyCLI/                   # CLI（Pro 预留）
├── Tests/                            # 自建极简测试运行器
├── build.sh                          # 构建脚本（swiftc 直接调用）
├── test.sh                           # 测试脚本
└── docs/
```

**核心约束不变**：
- AD-02 仍然生效：`MacCopyKit` **禁止** import SwiftUI / AppKit
- AD-01 仍然生效：禁用 `@Observable`，用 `ObservableObject` + `@Published`
- 分层与依赖关系不变，只是「SPM 库」变成「swiftc 编译的模块」

### 5.1 构建脚本要点

```bash
#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
export TMPDIR="$ROOT/.tmp"
export CLANG_MODULE_CACHE_PATH="$ROOT/.tmp/modcache"
SDK="$(xcrun --show-sdk-path)"
TARGET="arm64-apple-macos13.0"
mkdir -p "$ROOT/.build"

# 1) 编译核心库
swiftc -O -parse-as-library -target "$TARGET" -sdk "$SDK" \
  -module-name MacCopyKit \
  "$ROOT"/src/MacCopyKit/**/*.swift \
  -emit-module -emit-module-path "$ROOT/.build/MacCopyKit.swiftmodule" \
  -emit-library -o "$ROOT/.build/libMacCopyKit.dylib"

# 2) 编译 App
swiftc -O -parse-as-library -target "$TARGET" -sdk "$SDK" \
  -I "$ROOT/.build" -L "$ROOT/.build" -lMacCopyKit \
  "$ROOT"/src/MacCopyApp/*.swift \
  -o "$ROOT/.build/MacCopy"
```

> 注：`**` glob 需 `shopt -s globstar`（bash）或改用 `find`。

## 6. 给工程师的强制要求

1. **必须用 `swiftc` 通路，不得依赖 `swift build`**（本机不可用）
2. 每完成一个模块，**必须实际编译通过**，不能只写不编译
3. 单元测试用**自建测试运行器**（`Tests/` 下写一个 `main.swift` + 断言宏，`swiftc` 编译后运行），不用 XCTest（XCTest 需要 xcodebuild/test bundle，同样受 manifest 机制影响）
4. BLAKE3 吞吐断言必须用 `-O` 构建的产物
5. 所有文件用 Write 工具创建（沙盒拦 `mkdir`/heredoc）；需要目录时 Write 会自动建
6. 编译环境变量：`TMPDIR` 和 `CLANG_MODULE_CACHE_PATH` 都要指向 workspace 内的 `.tmp`
