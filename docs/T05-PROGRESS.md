# T05 / T04 遗留 —— 完成记录

> 状态：**✅ 完成**。最后更新：2026-11-08 21:20
> 代码：`<workspace>/MacCopy/`
> 环境约束权威版：**v5**（`docs/ENV-FS-CONSTRAINTS.md`）

## 0. 交付物

| 项 | 值 |
|---|---|
| 可运行 App | `MacCopy/dist/MacCopy.app`（ad-hoc 签名，`open -a MacCopy` 可启动） |
| 窗口 | 已验证：1180×760、layer=0、alpha=1.0（`CGWindowListCopyWindowInfo`） |
| 源文件 | 63 个 .swift / 约 11.6k 行 |
| 测试 | **119/119 全绿**，`bash test.sh` 退出码 0 |
| 构建 | `bash build.sh` 零 error 零 warning（Swift 6 严格并发） |
| 本地化 | String Catalog **180 个 key**，`sync_catalog.py --check` 零缺失 |

## 1. 环境约束定论（v5）

- 守卫是**路径白名单**，策略**从未变过**。在已授权目录内且父目录已存在时，
  `rename` / `unlink` / `symlink` / `createFile` / `.atomic` 全部可用。
- 真正不可用：`link()`（硬链接）、`setxattr()`。
- 架构原则：**环境能力是时点快照而非恒定契约，生产代码必须为「可用」与「不可用」两种状态都准备路径，且降级必须可观测（不能静默）。**

## 2. 本轮完成项

### 2.1 T05 UI 层（新建 8 个文件）

| 文件 | 职责 |
|---|---|
| `MacCopyApp.swift` | `@main` 入口 + 传输菜单 + 设置 Scene |
| `TransferViewModel.swift` | @MainActor ObservableObject，AsyncStream 单向消费事件，源/目标/设置/日志/进度 |
| `Views/RootView.swift` | NavigationSplitView 三栏 |
| `Views/QuickStartView.swift` | 拖放源、选目标、待恢复横幅、fileImporter |
| `Views/ProgressPanel.swift` | 速度曲线 Chart、双口径进度条、统计、降级警示、汇总 |
| `Views/FileListView.swift` | 逐文件状态、校验徽标、中文失败原因、运行日志 |
| `Views/SettingsView.swift` | 引擎/校验/冲突/限速/Pro 锁定态 |
| `Views/InspectorView.swift` | 任务概览、文件详情、校验期望值/实际值、Finder 显示 |
| `Views/QueueHistoryView.swift` | 队列恢复页、SQLite 历史记录页 |

**本机特殊处理**：SwiftUI 的 `@State` 是宏，在 `swiftc` 直编下插件服务器崩
（`external macro 'State()' could not be found`）。全部 UI 暂态改用
`@StateObject` + `ObservableObject`（RootUIState / QuickStartUIState / QueueUIState /
HistoryUIState），不触发宏，且符合 AD-01。

### 2.2 T04 遗留补齐

| 项 | 实现 | 验证 |
|---|---|---|
| **checksum 清单落盘** | `OutcomeCounter` 收集成功文件的目标摘要（按算法分组、路径转相对目标根）；`CopyEngine.run` 收尾时写 `MacCopy.sha256` 到目标目录 | 新增 2 个测试，其中 **用系统 `shasum -c` 真实校验通过** |
| **队列恢复接驳** | `TaskQueueRecovery` 不再是孤儿类：`TransferViewModel.refreshPendingTasks()` 启动时探测待恢复任务数，QuickStartView 显示横幅，QueueView 提供逐个「继续」 | 编译通过 + QueueView 可在 App 内读取 |
| **速率限制** | 工程师已接入 `StreamCopier`（令牌桶）；主理人修复 `TokenBucket` 的类型错误与「超大请求让 tokens 变负」逻辑 bug | 117→119 测试含限速用例 |
| **`verifying` 状态** | `CopyEngine` 的 `onVerifying` 回调发 `.fileStatusChanged(.verifying)` | 已有测试 |
| **`ResumeStore` tmp** | 工程师已改为不删除、复用同名 tmp 覆盖写 | 编译通过 |
| **本地化** | 新增 `sync_catalog.py`，扫描源码所有 `Localization.string/format` 调用自动同步 Catalog | 180 key / 零缺失 / UI 层零裸中文 |

### 2.3 打包

新增 `package_app.sh`：
1. `swiftc` 产物组装成标准 `.app` bundle
2. dylib 放 `Contents/Frameworks`，install name 改 `@rpath`
3. 主程序加 `@executable_path/../Frameworks` rpath
4. `.xcstrings` → `zh-Hans.lproj/Localizable.strings`（180 条中文，保证系统语言非中文时也强制简体中文）
5. ad-hoc 签名 + `codesign --verify`

## 3. 最终合规检查

| 检查 | 结果 |
|---|---|
| `bash build.sh` | 零 error 零 warning |
| `bash test.sh` | 119/119 通过 |
| `sync_catalog.py --check` | 178 个源码 key，Catalog 180 个，缺失 0 |
| AD-01 禁用 `@Observable` | 真实使用 0 |
| AD-02 MacCopyKit 无 UI import | 违规 0 |
| UI 层非 default 的裸中文字面量 | 0 |
| `codesign --verify` | 有效 |
| App 窗口 | 已渲染（1180×760） |

## 4. 已知限制（如实列出）

1. **Finder Service 未安装注册** — `MacCopyService/ServiceDelegate.swift` 仍是骨架，
   且 `.app` 里没有 Service target 产物。用户目前通过 App 内拖放/选择文件使用。
2. **无 Developer ID 签名与公证** — ad-hoc 签名仅本机可运行；分发给他人需
   开发者账号签名 + `notarytool` 公证（PRD Q1 的既定路线）。
3. **暂停语义** — 当前「暂停」实现为取消并保留断点，下次从 `.partial` 续传，
   不是原地把当前传输挂起。
4. **10GiB 级稀疏 / 100GB 端到端吞吐未实测** — 磁盘仅约 28 GB 且禁止双份落盘，
   QA 已明确标注为环境受限项。BLAKE3 ≥1 GB/s 是在内存缓冲下测得。
5. **UI 自动化 / 帧率 / Instruments 长时压测未做** — 无可测自动化环境。
6. **6 个 `XX*` 残留文件** — `perl -pi` 留下的无扩展名文件，不参与构建，删除被守卫拒绝。

## 5. 工程师补充（123/123）

在上面 119 个测试基础上，补了 **4 个正确性回归测试**（`Tests/EngineTests.swift`
`registerCorrectness()`），把验收要求里的 BUG-03 三条断言与 `verifying` 事件流补齐：

| 测试 | 验证点 |
|---|---|
| `正确性：复制后篡改目标 1 字节 → 必须检出不一致` | `Verifier.verifyByReadBack` 从源重新算摘要，目标被改即 `.failed` |
| `正确性：复制后篡改源 1 字节 → 必须检出不一致` | 源侧摘要是权威基准，源被改即 `.failed` |
| `正确性：降级场景必须带明确说明且不标为通过` | `.notVerified` + `isDegraded=true` + `reason != nil` + `isPassed=false` |
| `verifying 迁移：引擎事件流包含 transferring → verifying → 完成` | 事件流真断言 `.transferring` / `.verifying` / `.fileCompleted` |

当前 `bash build.sh` 零 error 零 warning，`bash test.sh` **123/123 通过**。

另外更正了 `docs/T04-PROGRESS.md` 里「禁用 API 命中数 = 0」的不准确表述：
> 目录项操作在路径白名单内可用，生产代码采用「优先原子路径 + 降级路径」双准备；
> `link`（硬链接）与 `setxattr`/`fsetxattr` 真正不可用，且生产代码未使用。

### 待办（下轮）：i18n v1.1 八语言增量

架构师已产出 `docs/ARCHITECTURE-I18N.md`（T-I01~T-I05），PRD-I18N.md 已完成，
但 `Localization` 目前仍是单语言（zh-Hans）实现。实施时必须处理架构师实测的 3 个坑：

1. **`Localization.format` 的 `String(format:)` 占位符签名不一致会 SIGSEGV**
   （`%@` 收到 Int 会把整数当对象指针解引用，进程直接 exit 139）。
   按架构 §3.2 用 `FormatSignature` 提取占位符序列，签名不一致或参数不足时
   **退回中文基准**再 format。签名 `Localization.string/format` 冻结（AD-I03），只改内部实现。
2. **空串 key 不会自动回退中文** —— 值是 `""` 时原样返回，需显式
   `value.isEmpty ? base : value`（PRD P0-06 ②）。
3. **迁移判定放 `SettingsStore.load()` 内** —— Swift 里 `init` 内给 `@Published var`
   赋值不触发 `didSet`，放 `TransferViewModel.init()` 会永远不执行。
   另外「恢复默认设置」（`SettingsView.swift` 的 `vm.settings = AppSettings()` 与
   `SettingsStore.resetToDefaults()`）必须改成保留语言字段，不能全量覆盖。

架构师已裁决 Q2b「不降级、即时生效保持 P0」，冻结区（CopyEngine / Verifier /
ResumeManager / SparseHandler / Checksum / TaskQueue / 报告数据模型）一律不动，
`applyLanguage()` 只改文案状态，保证「复制任务进行中切换语言不中断」。
`logLines[].text` 与 `FileRow.failureReason` 存的是已渲染字符串快照，天然满足
P0-05 ④「历史日志/已落盘失败原因不改写」，**不要**改成存 key 再动态渲染。

## 6. 复现

```bash
cd <workspace>/MacCopy
bash build.sh          # 编译
bash test.sh           # 119 测试
python3 sync_catalog.py --check
bash package_app.sh    # 生成 dist/MacCopy.app
open -a MacCopy        # 启动
```
