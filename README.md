<p align="center">
  <img src="MacCopy/Resources/Icon/MacCopyIcon-1024.png" width="180" alt="MacCopy icon">
</p>

# MacCopy

**macOS native file copy manager with verification, resume, and Chinese UI.**

对标 TeraCopy 的 macOS 原生替代品 —— 原生 Swift 6 实现，零第三方依赖。

> 图标设计：白色分叉表达「拷贝」（一分为二），青绿圆形勾表达「校验」。刻意不使用纸张、文件夹等具象物件，只保留动作本身。矢量源见 [`MacCopy/Resources/Icon/MacCopyIcon.svg`](MacCopy/Resources/Icon/MacCopyIcon.svg)，`.icns` 由 `tools/build_icon.sh` 生成。

[![macOS](https://img.shields.io/badge/macOS-13.0%2B-blue)]()
[![Swift](https://img.shields.io/badge/Swift-6-orange)]()
[![License](https://img.shields.io/badge/license-MIT-green)]()
[![Tests](https://img.shields.io/badge/tests-187%20passed-brightgreen)]()

---

## 特性

| 能力 | 说明 |
|---|---|
| **长路径支持** | 自研 `PathWalker` 逐级 `openat` + `mkdirat`，绕过 `PATH_MAX`(1024) 限制（实测 1227 字节路径通过） |
| **APFS 克隆** | 同卷复制走 `copyfile(COPYFILE_CLONE)`，CoW 零拷贝 |
| **5 种校验算法** | CRC32 / MD5 / SHA-1 / SHA-256 / BLAKE3，**全部自研或用 CryptoKit，零第三方依赖** |
| **断点续传** | `.maccopy.partial` 分片 + 签名校验（源变化则重传而非拼接） |
| **稀疏文件** | `SEEK_DATA`/`SEEK_HOLE` 空洞探测，写入时保留稀疏特性 |
| **符号链接保留** | 读取链接目标并重建链接本身 |
| **速率限制** | 令牌桶实现，均速偏差 ≤10% |
| **八语言界面** | 简体中文 / English / 繁體中文 / 日本語 / 한국어 / Français / Deutsch / Español |
| **低内存** | 10 万文件枚举峰值 **2 MiB**（流式分批，不驻留全量） |

## 系统要求

- macOS 13.0 (Ventura) 或更高
- Apple Silicon（也支持 Intel）

## 构建

本项目使用 `swiftc` 直接构建（不依赖 SwiftPM）：

```bash
cd MacCopy
bash build.sh          # 编译库 / CLI / App
bash test.sh           # 运行 187 个测试
bash package_app.sh    # 打包 dist/MacCopy.app
open dist/MacCopy.app
```

> **为什么不用 SwiftPM？** 见 [`docs/BUILD-ENV-NOTES.md`](docs/BUILD-ENV-NOTES.md) —— 记录了构建环境约束与替代方案。

## 项目结构

```
MacCopy/
├── src/
│   ├── MacCopyKit/       # 核心库（Foundation-only，零 UI 依赖）
│   │   ├── Model/        # 数据模型、错误类型、状态机
│   │   ├── Engine/       # 复制引擎、断点续传、校验、限速
│   │   ├── Checksum/     # 5 种校验算法实现
│   │   ├── IO/           # 路径访问、元数据、copyfile 封装
│   │   ├── Persistence/  # SQLite 任务历史、断点元数据、设置
│   │   └── Support/      # 日志、本地化、路径工具
│   ├── MacCopyApp/       # SwiftUI 界面
│   ├── MacCopyService/   # Finder 服务（右键菜单）
│   └── MacCopyCLI/       # 命令行接口
├── Tests/                # 自建测试运行器（不用 XCTest）
├── tools/                # 翻译数据生成器
└── docs/                 # 架构设计、需求、QA 报告
```

## 架构要点

- **单向事件流**：`CopyEngine`(actor) → `AsyncStream<TransferEvent>` → `TransferViewModel`(@MainActor) → SwiftUI
- **分层隔离**：`MacCopyKit` 是 Foundation-only，不 import SwiftUI/AppKit（AD-02）
- **语言状态在共享层**：因为 `.environment(\.locale)` 无法穿透 `Task.detached`，后台 worker 产生的错误文案也必须跟随界面语言
- **双路径准备**：环境能力是「时点快照」而非恒定契约，生产代码为「可用」与「不可用」两种状态都准备路径，且降级必须可观测

## 文档

| 文档 | 内容 |
|---|---|
| [`docs/PRD.md`](docs/PRD.md) | 产品需求文档 |
| [`docs/PRD-I18N.md`](docs/PRD-I18N.md) | 多语言增量需求 |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | 系统架构与任务分解 |
| [`docs/ARCHITECTURE-I18N.md`](docs/ARCHITECTURE-I18N.md) | 多语言增量架构 |
| [`docs/ENV-FS-CONSTRAINTS.md`](docs/ENV-FS-CONSTRAINTS.md) | 文件系统能力实测约束 |
| [`docs/BUG-HUNT-REPORT.md`](docs/BUG-HUNT-REPORT.md) | 自动化测试缺陷挖掘报告 |

## 已知限制

- **翻译质量**：除简体中文外，其余七种语言的译文为**机翻初稿，未经母语审校**，措辞可能不够地道（界面功能与占位符均经过自动化校验，可正常使用）
- **Finder 服务菜单名**跟随系统语言，不受 App 内手动切换影响
- **APFS 克隆快路径在 fd 通道下不生效**，同卷复制走全量拷贝
- 无 Developer ID 签名与公证（当前为 ad-hoc 签名，仅本机可运行）

## License

MIT
