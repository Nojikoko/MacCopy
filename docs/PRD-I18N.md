# PRD-I18N：MacCopy 八种语言支持（v1.1 增量 PRD）

| 项目 | 内容 |
|---|---|
| 文档类型 | **增量 PRD**（仅描述相对 `docs/PRD.md` v1.0 的变更，不重写完整 PRD） |
| 基线版本 | MacCopy v1.0（`MacCopy/dist/MacCopy.app`；63 Swift 文件 / ~11.6k 行）。**测试基线以施工时 `bash test.sh` 实际输出为准，不写具体数字**——测试数量随每次施工递增，任何硬编码都会立刻过期（历史数字仅保留在 §10 修订记录中作沿革） |
| 目标版本 | MacCopy v1.1 |
| 文档版本 | **v1.12 定稿**（v1.0 初版 → … → v1.11 撤销合规范例 → **v1.12 记录第 ⑤ 项成功日志文案滞后 + 独立承重证据 + v1.2 文案待办**，修订记录见 §10） |
| 变更主题 | 由「强制简体中文」升级为「八种语言 + 跟随系统 / 手动覆盖」 |
| 对齐文档 | `docs/PRD.md`（基线）、`docs/ARCHITECTURE-I18N.md` **v1.2**（任务编号 T-I01~T-I05）。**按「版本号 + 任务编号」定位，不写行数**——架构每补一轮实测论证行数就会变，硬编码永远追不上；§10 修订记录中的行数是当时对齐版本的历史快照，仅供参考 |
| 裁决状态 | §7 全部 12 问 + Q2b + Q5 **已由主理人裁决完毕**，无开放待确认项；另追加 1 条硬要求（翻译数据与代码分离，见 §2 / P0-17） |
| 技术栈约束 | Swift 6.4.2 / SwiftUI / macOS 13.0+ / arm64 / **零第三方依赖** |
| 架构约束 | AD-01 禁用 `@Observable`（沿用 `ObservableObject` + `@Published`）；AD-02 MacCopyKit 禁止 import SwiftUI/AppKit |
| 文档日期 | 2026-11-08 |

---

## 术语规范（强制）

> **全文及后续设计/代码/发版说明统一使用「八种语言」，禁止任何以「国家」为量词的表述。**
> 理由：`zh-Hans` 与 `zh-Hant` 是同一语言的两种文字变体，不是两个国家；`en` / `es` / `fr` 亦跨国使用。
> 该规则同样适用于设置页文案、Release Notes 与对外宣传；验收时对仓库做字面扫描，命中的违规量词数应为 0。

---

## 一、变更摘要与对原 PRD 的覆盖

| 原 PRD 条目 | 原内容 | 本增量决策 | 状态 |
|---|---|---|---|
| 目标 G5 | 界面 100% 简体中文；系统语言为英文时仍强制中文 | **覆盖**：改为「八种语言全部可用，默认跟随系统，可手动覆盖」 | 已覆盖 |
| Q12 | v1.0 强制简体中文，v1.1 加英文 | **关闭**：v1.1 直接上八种语言，不止英文 | 已关闭 |
| P0-10 | 简体中文界面 | **扩展**：由单语言改为八语言，简体中文仍为基准语言 | 已扩展 |
| 「零英文裸露字符串」验收 | 全量字符串零英文裸露 | **修订为**：全量字符串零「未本地化字面量」裸露，且八语言各 100% 覆盖 | 已修订 |
| 其余 P0-01~09、11~12 / P1 / P2 | 不变 | **不变**，本增量不得改变任何复制/校验/队列行为 | 冻结 |

**范围边界**：本次只改「文案解析与语言选择」，不改复制引擎、校验算法、断点续传、任务队列、报告数据模型（仅增加语言标注字段，见 P1-07）。引擎层的参数语义澄清（如 `FileEnumerator.maxDepth`）与性能类验收测量口径均不属于本增量，已分别补在 **`docs/PRD.md` 附录 A / 附录 B**，避免文档职责混淆。

---

## 二、八种语言清单（决策：确认主理人推荐清单，不调整）

| # | 语言标签（`.lproj` 名） | 设置页显示名（endonym） | 角色 | 入选理由 |
|---|---|---|---|---|
| 1 | `zh-Hans` | 简体中文 | **基准语言 / sourceLanguage** | 立项原点；`defaultValue` 内联中文；已有 180 key 全量翻译 |
| 2 | `en` | English | 国际通用语 / 兜底语言 | TeraCopy 主要用户语言；macOS 开发者与跨区用户默认；也是「系统语言未覆盖」时的回退目标 |
| 3 | `zh-Hant` | 繁體中文 | 繁体市场 | 台/港/澳 Mac 占有率高；与简中同源，翻译成本最低、术语收益最高 |
| 4 | `ja` | 日本語 | 东亚 | 日本 Mac 份额显著高于全球均值；素材/影像工作者密集，高度契合目标画像 |
| 5 | `ko` | 한국어 | 东亚 | 韩国 Mac 用户增长快；与 ja 同批做便于 CJK 字体/换行统一验收 |
| 6 | `fr` | Français | 欧洲 | 法语区 Mac 装机量居欧盟前列；`fr-CA` 可复用 |
| 7 | `de` | Deutsch | 欧洲 | 德国为欧盟最大 Mac 市场；德语长串是 UI 布局压力测试的关键样本 |
| 8 | `es` | Español | 欧洲 + 拉美 | 单一 `es` 可覆盖西班牙与拉美，覆盖人口最广，单位翻译成本最低 |

### 未入选语言的取舍（附理由）

| 备选 | 结论 | 理由 |
|---|---|---|
| 俄语 `ru` | **本次不纳入，列为 P2-01 第一顺位扩展** | Mac 装机基数小于上述八种；西里尔字母会引入额外字体与换行验收面；TeraCopy 虽有俄语，但本项目优先覆盖「中文用户 + Mac 高渗透市场」 |
| 葡语（巴西）`pt-BR` | **本次不纳入，列为 P2-01 第二顺位** | 巴西 Mac 份额偏低；与 `es` 同属罗曼语族、可复用翻译流程，作为扩展比作为首发更划算 |
| 意大利语 `it` | **本次不纳入，列为 P2-01 第三顺位** | 市场规模小于 de/fr/es，且三者已覆盖欧盟主要 Mac 用户 |
| `en-GB` / `zh-Hant-TW` / `zh-Hant-HK` / `fr-CA` 等区域变体 | **本次不单列** | 由语言标签前缀匹配统一归并（见 §3.3）；避免语言数从 8 膨胀到 12+ 倍增翻译与测试成本 |

> ✅ **Q10 已由主理人裁决（v1.2）**：八种语言清单**锁定**，`es` **保留，不换 `pt-BR`**，其余 7 种不动。`ru` / `pt-BR` / `it` 仍仅作为 P2-01 的后续扩展顺位，不参与本次替换讨论。原 v1.0/v1.1 中「若坚持对齐 TeraCopy 语种则 es → pt-BR」的备选表述**作废**。

### 语言资源形态决策（v1.2 追加硬要求：翻译数据与代码分离）

主理人追加硬要求：**译文必须存放于独立数据文件，不得与代码/Catalog 混写**。理由：`K ≈ 190`，7 种新语言约 1300 条译文，单一 `.xcstrings` 体积 200 KB+，长文本生成易中断且无法续写，QA 也无法逐语种独立校验。

```
【数据层 · 译文唯一事实源，每语种独立可编辑/可单独校验】
src/MacCopyApp/Localization/translations/
    zh-Hans.json   ← 180 条冻结基准 + N 条新 key（中文）
    en.json / zh-Hant.json / ja.json / ko.json / fr.json / de.json / es.json
                   ← 各 K 条 { "key": "译文" }，机翻初稿（口径见 §9）

【构建层 · sync_catalog.py 三子命令】
    --sync                 扫描源码 Localization.string/format 调用 → 补新 key 到各 JSON（值为空，待译）
    --merge-translations   读 8 份 JSON → 生成单一 Localization/Localizable.xcstrings
    --check-languages      逐语种五项硬校验（见下）+ 中文基准快照逐字比对 → 失败非零退出、阻断打包

【产物层】
    Localization/Localizable.xcstrings（单一 Catalog，sourceLanguage=zh-Hans，生成物）
        └─ package_app.sh ──▶ dist/MacCopy.app/Contents/Resources/<lang>.lproj/Localizable.strings × 8
```

- **单一 String Catalog** 仍是运行时/打包的唯一产物，但**降为「生成物」**：`src/MacCopyApp/Localization/Localizable.xcstrings`（由现路径 `Localization/zh-Hans.lproj/Localizable.xcstrings` 上移一层）；`sourceLanguage` 保持 `zh-Hans`。**脚本不得反向写 `translations/*.json`**。
- **`--check-languages` 五项硬校验**（任一失败 `return 1`；v1.10 依 `sync_catalog.py:10-11,159-254` 实现对齐）：① 逐语种零缺失且与 `zh-Hans.json` 键集合完全一致（含**多余 key** 检查）；② 占位符数量与类型（覆盖 `%@ %d %lld %1$@ %zu %%`）；③ **空串/全空白检测**（对应运行期空串兜底，双层保障第一道）；④ **`zh-Hant` 简体字扫描**（读 `docs/i18n/simplified-chars.txt`，仅收简繁异体字对中的简体侧专用字，不含「文/件/中/大」等共用字以免误报）；⑤ **基准占位符签名未漂移**（读 `docs/i18n/baseline-placeholders.json`，比对 `zh-Hans.json` 每个 key 的占位符序列与冻结快照一致，并拦截新增未登记占位符；防止「中文基准自身被改坏」导致运行期 `FormatSignature` 比对基准漂移，对应 P0-10）。
  - **另有独立的中文基准快照比对**（P0-03）：`docs/i18n/baseline-v1.0-zh-Hans.json` 的 180 条与 `zh-Hans.json` 逐字一致，快照缺失或条数 ≠180 亦失败。**该项不计入「五项」，是并列的比对步骤**。
  - `ensureHealthyTranslations()` 只从冻结快照 + TSV 重建损坏的译文文件，**上述五项 + 基准快照比对在重建后仍逐条全跑**，不得绕过。
  - **⚠️ 已知文案滞后（v1.12 记录，不阻塞、不改代码）**：`sync_catalog.py:252-253` 的**成功输出行**仍只列四项（「逐语种零缺失 / 占位符数量与类型一致 / 无空串 / zh-Hant 简体字 0 命中」+「中文基准快照 180 条逐字一致」），**未打印第 ⑤ 项**。文件头 docstring 与实现均为五项，**校验行为完全正常**——QA 已在临时副本做独立负向验证：只篡改 `docs/i18n/baseline-placeholders.json` 的冻结签名、译文与 180 条快照均不动，即得到 `EXIT=1` 且失败项恰好 1 条（`[基准占位符] zh-Hans / error.checksumMismatch / 期望 … 实际 …`），证明第 ⑤ 项**独立承重**，不是被 180 条逐字比对顺带覆盖。**结论：日志里看不到「第五道通过」属纯文案滞后，不得据此判定第 ⑤ 项未生效**；已登记为 v1.2 一行打印文案待办（`docs/PRD.md` 附录 C.1.1），v1.1 代码冻结不动脚本。
- **打包产物**：`Contents/Resources/{zh-Hans,en,zh-Hant,ja,ko,fr,de,es}.lproj/Localizable.strings` 共 8 份，由 `package_app.sh` 从 Catalog 生成。
- **基准快照**：`docs/i18n/baseline-v1.0-zh-Hans.json`（冻结 v1.0 的 180 个 key → 中文取值），**必须在写任何译文之前导出**；`--check-languages` 比对 `zh-Hans.json` 中这 180 条与快照逐字节一致。

> **术语消歧：两个不同的「baseline」（v1.3 补，避免施工/验收时混淆）**
>
> | 名称 | 是什么 | 归属 | 用途 |
> |---|---|---|---|
> | **冻结基准快照** `docs/i18n/baseline-v1.0-zh-Hans.json` | 一个 **JSON 数据文件**，平铺存放 v1.0 的 180 条中文原文 | **T-I01**，构建期数据 | P0-03 的比对基准；`--check-languages` 校验 `zh-Hans.json` 中这 180 条逐字节不变；**必须在写任何译文之前导出** |
> | **运行期基准函数** `Localization.baseline(_:_:)` | 一个 **Swift 私有函数**，用不存在的 `table:` 名强制回退编译期 `defaultValue` | **T-I02**，MacCopyKit 运行期代码 | `string` 判空回退、`FormatSignature` 比对、防护「退回中文基准」三处的中文来源；见 §3.4 / §3.5 约束 5 |
>
> 两者**互不依赖、不互相读取**：前者是磁盘上的静态数据，后者是运行期取字符串的函数。文档与代码注释中请勿混用「导出快照」与「取中文基准」两种说法。
- **繁中配套**：`docs/i18n/glossary-zh-Hant.md`（≥20 术语）+ `docs/i18n/simplified-chars.txt`，二者配套维护。

---

## 三、语言切换机制（核心决策）

### 3.1 三方案评估

| 方案 | 机制 | 优点 | 缺点 | 结论 |
|---|---|---|---|---|
| **A** 仅跟随系统 | `CFBundleLocalizations` + 系统设置语言 | 零实现成本；完全符合 macOS 惯例 | 用户无法在中文系统上临时切英文（跨国协作/截图/排障高频）；无法覆盖系统语言不在八种内的中文用户 | ❌ 不采用 |
| **B** 仅 App 内手动切换 | 设置页下拉，写 `AppleLanguages` + 重启 | 用户完全可控 | **必须重启**（实测 `AppleLanguages` 对已构造的 `Bundle` 不生效）；首次启动在错误语言时体验差；违背「零学习成本」 | ❌ 不采用 |
| **C** **默认跟随系统 + App 内手动覆盖** | 共享 `Localization` 层持有语言专用 `Bundle`，SwiftUI 侧强制视图树重建 | 新用户零配置即正确；高级用户可覆盖；**即时生效、无需重启**；零第三方依赖；Foundation-only 实现可用于 MacCopyKit | 需新增约 2 个设置字段 + 1 个语言解析器 + 视图树重建钩子 | ✅ **采用** |

### 3.2 决策 C 的具体定义（可直接交付架构师）

| 决策点 | 结论 |
|---|---|
| **默认模式** | `跟随系统语言 = true`（`languageFollowsSystem` 默认 `true`）。用户未做任何选择时完全按 A 行为运行 |
| **手动覆盖** | 设置页可关闭「跟随系统语言」，并从 8 种语言中选择一种；持久化到 `UserDefaults` |
| **优先级** | 手动覆盖 > 系统解析 > 兜底 `en`。任何时刻手动值都优先；重新打开「跟随系统」即清空手动值并回到系统解析 |
| **是否立即生效** | **是，立即生效，不需要重启、不需要重新登录、不需要退出设置页** |
| **生效范围** | 主窗口、设置页、进度窗口、Inspector、菜单栏自定义菜单、窗口标题、Alert、通知文案；**包括 MacCopyKit 产生的错误消息与模型 displayName** |
| **进行中的任务** | 切换语言**不得**中断/重启复制任务、不得丢失进度、不得重写已产生的历史日志与已落盘的失败原因文本；仅新渲染的文本使用新语言 |
| **生效时延** | 用户在设置页选择后 ≤ 200 ms 内完成全部可见界面的刷新 |

### 3.3 语言解析与回退链（确定性规则，按顺序执行）

```
1. 若 languageFollowsSystem == false 且 preferredLanguage ∈ 8 种有效标签
       → 使用该语言，结束
2. 若 preferredLanguage 非法/损坏（如手工改了 plist）→ 视为未设置，进入 3，并写一条诊断日志
3. 取 Bundle.main.preferredLocalizations（系统语言列表，按用户偏好顺序），逐项匹配：
   3a. 精确命中 8 种标签之一                        → 使用，结束
   3b. 按「-」取语言前缀命中（en-GB→en, fr-CA→fr,
       zh-Hant-TW→zh-Hant, de-AT→de, es-MX→es,
       ja-JP→ja, ko-KR→ko, zh-Hans-SG→zh-Hans）   → 使用，结束
   3c. 系统给的是裸 `zh`（无脚本）：
       - 区域为 TW/HK/MO            → zh-Hant
       - 其余（含 CN/SG/无区域）    → zh-Hans
   3d. 系统给的是 `zh-Hant-*`      → zh-Hant（在 3b 已覆盖）
4. 系统语言列表全部不在八种内（如 ru / it / pt-BR / ar / hi）
       → 回退到 en，结束
5. 兜底：任何异常（Bundle 构造失败、资源缺失）→ zh-Hans（基准语言）
```

**为什么回退到 `en` 而不是 `zh-Hans`（Q1）**：
简体中文是**产品基准语言**（sourceLanguage / defaultValue 来源），不是**用户兜底语言**。对一位俄语或葡语系统用户显示中文，与 v1.0 的「强制中文」一样不可读；`en` 是跨平台通用语，也是 TeraCopy 国际用户的基线，可理解率最高。

**旧用户迁移（避免静默回归）**：
检测到 `com.maccopy.*` 已有旧偏好、且不存在新增的 `languageFollowsSystem` 键时，判为 v1.0 升级安装 → 首次加载写入 `languageFollowsSystem = false, preferredLanguage = "zh-Hans"`，并在设置页语言分组显示一条一次性提示「已从旧版本保留简体中文，可切换为跟随系统语言」。
理由：v1.0 用户在任何系统语言下看到的都是中文，升级后不应被静默改成英文；新装用户不受影响，仍走「跟随系统」默认值。

### 3.4 漏翻译兜底（P0 硬要求）

| 情形 | 行为 | 是否由系统自动提供 |
|---|---|---|
| 某语言某 key 缺失 | 返回该 key 在源码中的 `defaultValue`（**中文**），绝不返回 key 本身、绝不返回空串、绝不显示占位符 | ✅ 是（原生 API 行为） |
| 某语言某 key **值为空字符串** | **视同缺失，回退到中文 `defaultValue`** | ❌ **否，必须显式实现**：实测 `String(localized:defaultValue:bundle:)` 对空串 key **原样返回 `""`**。`Localization.string` 内必须补 `value.isEmpty ? 中文基准 : value` |
| 某语言整个 `.lproj` 缺失/损坏 | 整体回退到 `zh-Hans`，且不崩溃 | ❌ 否，需显式实现 |
| 占位符不匹配（`%@`/`%d` 数量或类型不一致） | **构建期**由 `sync_catalog.py --check-languages` 判定为失败（非零退出码，阻断打包）；**运行期**由 `Localization.format` 的 `FormatSignature` 校验兜底：签名不一致或参数数量不足时**退回中文基准格式串**再格式化，并写诊断日志 | ❌ **否，必须显式实现且为防崩溃硬要求** |
| **中文基准（`defaultValue`）的取法**（v1.3 新增） | `Localization` 内私有 `baseline(_:_:)` **必须**通过传入**一个永不存在的 `table:` 名**（如 `"__MacCopyBaseline__"`）强制系统回退到编译期 `defaultValue` 取得中文原文；`string` 判空回退、`format` 的 `FormatSignature` 比对基准、「退回中文基准」三处的 `base` **一律来自 `baseline()`**。**严禁**使用无 `bundle:` 参数的 `String(localized:defaultValue:)`，也**严禁**显式传 `bundle: nil` | ❌ **否，必须显式实现**：无 `bundle:` 的重载默认查 `Bundle.main`，正式 `.app` 内含 8 个 `.lproj`，系统语言为英语时「中文基准」实际拿到英文资源值（架构 V-B1~V-B4 实测） |
| Debug 构建 | 每次回退写一条诊断日志（含语言 + key），便于校对；Release 静默 | ❌ 否 |

> **v1.1 修订（架构补充探针 + 产品独立复现，见 §3.5）**：上表后几行**不是原生 API 免费提供的**。
> 尤其占位符类型不匹配：基准为 `%d` 而译文误写 `%@` 时，`String(format:pattern, 5)` 会把 `Int` 当对象指针解引用，**进程直接 SIGSEGV（exit 139）**，不是显示 `%!` 乱码。
> 因此「运行期安全兜底」从「一句期望」升级为 **P0 强制实现项**：`Localization.string` 判空 + `Localization.format` 的 `FormatSignature` 守卫，二者缺一不可。

> **v1.3 修订（架构 V-B1~V-B4，中文基准被 `Bundle.main` 劫持）**：`defaultValue` 作为编译期中文原件的角色**绝对不变**，它是三重锚点——运行期兜底值、`FormatSignature` 比对基准、构建期 `--check-languages` 校验基准。但**取它的方式有坑**：架构构造带 `en.lproj`/`ja.lproj` 的模拟 `.app` 实测，`String(localized:key, defaultValue:dv)` 返回 `TOTAL %d ITEMS`（英文）而非中文；`bundle: nil` 等价默认 `Bundle.main`，同样被劫持；`String(localized: dv)` 在「中文原文恰为某 key」时会被注入的 `"共 %d 项"="HIJACKED"` 劫持；**只有传不存在的 `table:` 名稳定返回中文且不受注入影响**。
>
> 若沿用 `base = String(localized:key, defaultValue:dv)`，会产生**四个**连锁失效点（v1.4 依 QA 的 V-B5/V-B6 由三处升级）：
> ① 空串回退到系统语言译文而非中文 → 违反 P0-06 ②；
> ② `FormatSignature` 基准随系统语言漂移 → 占位符防护判定失真；
> ③ 防护触发时「退回中文基准」实际退回系统语言串 → P0-06 的中文兜底失效；
> ④ **`guard let bundle else { return base }` 分支**（整份 `.lproj` 被物理删除时 `bundle == nil`）直接返回被劫持的 `base` → **英文串**，违反 P0-06 ③（V-B6）。
>
> **⚠️ V-B5（QA 实测，最严重）：基准被劫持不只是「退回错语言」，而是让双层防护整体失效并崩溃**。QA 用真实 `.app`（8 个 `.lproj`、`CFBundleDevelopmentRegion=en`、注入空串与坏占位符、`-AppleLanguages "(en)"` 启动）复现：`base` 与 `candidate` **同时**被劫持成 `TOTAL %@ ITEMS` → `FormatSignature` 判定 `["@"] == ["@"]` **相等** → 防崩溃守卫**根本不触发** → `String(format:"TOTAL %@ ITEMS", 5)` → **exit 139 / SIGSEGV**。即「构建期校验 + 运行期守卫」双层防护在基准被污染时形同虚设，后果是进程崩溃而非显示错误文案。
> **产品侧独立复现（v1.3，Swift 6 / macOS 13.0 / 绝对路径模块缓存）**：构造带 `en.lproj` 的模拟 bundle 并注入 `"共 %d 项" = "HIJACKED"`，实测：
> ```
> preferred=["en", "en"]
> String(localized:"k", defaultValue:dv, bundle:<带 en 资源的 Bundle>) : TOTAL %d ITEMS   ← 被劫持
> bundle: nil                                                          : 共 %d 项（裸 CLI 进程，Bundle.main 无资源）
> table: "__不存在的表名__"                                             : 共 %d 项           ← 唯一可靠
> String(localized: dv, bundle:<带 en 资源的 Bundle>)                    : HIJACKED           ← 注入劫持
> ```
> **一处精确化**：架构 V-B2 记「`bundle: nil` 返回英文」，产品侧在**裸命令行进程**中复现为返回中文 `defaultValue`——因为该进程 `Bundle.main` 内没有 `.lproj` 资源。二者不矛盾，反而说明**无 `bundle:` / `bundle: nil` 的返回值取决于 `Bundle.main` 里有没有资源，是非确定的**；正式 `.app` 里必然有 8 个 `.lproj`，故实际行为就是架构记录的「被劫持」。结论不变：**只有「不存在的 `table:` 名」是纯参数控制、不依赖目录/Bundle 对象的可靠取法**。
>
> **验收含义（v1.4 升级，v1.6 补第 4 条；任一缺失即假通过）**：
> 1. P0-06 的空串/崩溃兜底测试**必须在 `Bundle.main` 内确实存在目标语言资源（模拟真实 `.app`）的环境下执行**；只在无资源的裸测试进程里测不出这个坑（反而会误判为「正常」）。
> 2. **坏译文注入必须与「系统语言 = 该译文语言」叠加**：向 `en.lproj` 注入坏串时，须以 `-AppleLanguages "(en)"` 启动。QA 实测 **zh-Hans 系统语言下该场景返回「共 5 项」不崩，只有 en 才崩**（V-B5 的触发条件）；不叠加就是第二次假通过，并须有 zh-Hans 反证。
> 3. **必须包含 `ko.lproj` 物理删除变体**：真删目录（非模拟 `bundle:nil`）并硬校验，`-AppleLanguages "(ko)"` 启动，覆盖 `bundle == nil` 分支（V-B6），断言结果仍为**中文**而非英文串。
> 4. **（v1.6 / QA A6）必须显式断言「双劫持前置条件成立」**：单独探测并断言无 `bundle:` 的 `base` 与显式语言 Bundle 的 `candidate` **逐字同为 `TOTAL %@ ITEMS`**。若注入失效、只有一边被劫持，第 2 条的防崩溃用例会**静默变成平凡通过**——这是第三类假通过，先证伪再验收。
>
> QA 的 A/B 矩阵（当前实现 vs `baseline()` 修正算法）：空串 ❌ 返回空串 → ✅ 中文兜底；`%@` 误收 `Int` ❌ exit 139 → ✅「共 5 项」EXIT=0；删 `ko.lproj` ❌ 英文 → ✅ 中文。

**构建期与运行期是双层保障**：P0-02 要求「零缺失」，构建即失败；P0-06 要求即使有人手改资源也不出现 key/空白/**崩溃**；且所有「中文兜底/基准」必须真正是中文（v1.3 新增）。两层都要有，且运行期一层必须自行编码实现，不能依赖 Foundation 默认行为。

### 3.5 技术可行性结论（产品实测 + 架构补充探针，均已独立复现）

已在目标环境（`swiftc` Swift 6 / `-target arm64-apple-macos13.0` / Xcode 27.2 SDK）编译 + 运行验证。前 6 行为产品侧实测；后 3 行（标注「补充」）由 software-architect 提出，其中 2 项产品侧独立复现、1 项由架构编译验证并直接采信（详见表下注）：

| 验证项 | 结果 |
|---|---|
| `String(localized: "k", defaultValue: "中文", bundle: b)` 可编译 | ✅ 通过（该重载存在，含 `table:` / `locale:` / `comment:` 变体均可编译） |
| `Bundle(path: "<Resources>/<lang>.lproj")` + 上述 API 返回目标语言文案 | ✅ `en` → `Start Copy`，`zh-Hans` → `开始复制` |
| 该 Bundle 内**缺失 key** 时返回值 | ✅ 返回传入的 `defaultValue`/`value`（中文兜底），不返回 key、不为空 |
| `UserDefaults` 写 `AppleLanguages` 对已构造 `Bundle` 的影响 | ❌ 不生效 → **方案 B 必须重启，故不采用** |
| `ByteCountFormatter` 是否可设置 `locale` | ❌ **无 `locale` 属性**（实测 `responds(to: Selector("locale")) == false`），隐式跟随系统区域设置，**无法按 App 内语言覆盖** → 见 Q3 |
| `Localization.string` 的调用方分布 | ⚠️ **不只 SwiftUI**：`MacCopyKit`（`MacCopyError` / `ConflictPolicy` / `TransferState` / `Verifier` / `ResumeManager` / `SparseHandler` 等）也在调用 |
| **补充：key 存在但值为空串** | ⚠️ 原样返回 `""`，**不会**回退中文 → 需 `Localization.string` 显式判空（架构探针 + 产品独立复现一致） |
| **补充：译文占位符类型错误（`%@` 收到 `Int`）** | ⚠️ **`String(format:)` 触发 SIGSEGV / exit 139**，不是乱码 → 需 `Localization.format` 增加 `FormatSignature` 守卫，签名不符时退回中文基准（架构探针 + 产品独立复现一致） |
| **补充：`.commands` 菜单标题重建** | ✅ 架构实跑 SwiftUI App 探针零 error 编译；主路径（`body` 内观察依赖 + `.id()` + `.commands` 文字读 VM `@Published`）+ **主理人指定兜底 `MenuBarLocalizer`（`NSApp.mainMenu` 手动更新菜单项标题，`@MainActor`，幂等总调用）** 双保险，任一成立即可 → **Q2b 降级前提不成立、降级路径作废** |
| **补充 V-B1~V-B4：中文基准被 `Bundle.main` 劫持**（产品侧独立复现） | ⚠️ 带 `en` 资源的 Bundle 下 `String(localized:key, defaultValue:dv, bundle:b)` → `TOTAL %d ITEMS`（**英文**）；`String(localized: dv, bundle:b)` → `HIJACKED`（注入劫持）；**不存在的 `table:` 名 → 中文，唯一可靠**。`bundle: nil` 在裸 CLI 进程返回中文但**环境相关、不可依赖**（正式 `.app` 内 `Bundle.main` 有 8 个 `.lproj`，实为被劫持）→ 中文基准必须经 `Localization.baseline(_:_:)` 用不存在的 `table:` 名获取 |
| **补充 V-B5：基准污染导致双层防护整体失效 + SIGSEGV**（QA 真实 `.app` 实测，v1.4 新增） | ⚠️ `CFBundleDevelopmentRegion=en` + 注入空串/坏占位符 + `-AppleLanguages "(en)"` 启动：`base` 与 `candidate` **同时**被劫持成 `TOTAL %@ ITEMS` → `FormatSignature` 判定 `["@"] == ["@"]` **相等** → 守卫**根本不触发** → `String(format:"TOTAL %@ ITEMS", 5)` **exit 139 / SIGSEGV**。**不再是「退回错语言」，而是双层保障形同虚设并崩溃**；且 zh-Hans 系统语言下不崩（返回「共 5 项」），**必须叠加系统语言才能复现** |
| **补充 V-B6：`bundle == nil` 分支返回被劫持 base**（QA 实测，v1.4 新增） | ⚠️ 物理删除整个 `ko.lproj` + `-AppleLanguages "(ko)"` → `guard let bundle else { return base }` 直接返回被劫持的 `base` → **英文串**，P0-06 ③ 一并失效。修法：该分支必须返回 `baseline()` 而非 `base` |

> 补充项由 software-architect 提出：**空串与 SIGSEGV 两项产品侧已用独立探针复现**（Swift 6 / macOS 13.0 / 绝对路径模块缓存 `/tmp/mc-pm-cache`）：空串 key → `[]`（需判空）；`共 %@ 项` + `Int(5)` → **exit 139**；正常 `共 %d 项` → `共 5 项` / exit 0。**菜单重建项由架构编译验证**（V-A9 主路径 / V-M1 `NSApp.mainMenu` 兜底，均零 error / 零警告），产品侧未重复跑探针，直接采信。**V-B1~V-B4 产品侧已独立复现**（详见 §3.4 v1.3 说明块）：带 `en` 资源的 Bundle 下无 `table:` 写法返回 `TOTAL %d ITEMS`、`String(localized: dv)` 被 `HIJACKED` 劫持、不存在的 `table:` 名稳定返回中文；`bundle: nil` 在裸 CLI 进程返回中文（因 `Bundle.main` 无资源），但该结果**环境相关、不可依赖**。架构已据此修正自身实现并新增 AD-I12。**V-B5 / V-B6 由 QA 用真实 `.app` A/B 矩阵实测**（当前实现 ❌ → `baseline()` 修正算法 ✅），产品侧直接采信、未重复跑探针；架构已新增 AD-I13 / AD-I14 与 T-I02 / T-I05 叠加条件。

**由此得出的六条实现约束（不可协商）**：
1. **必须在共享的 `Localization`（MacCopyKit，Foundation-only）层完成语言切换**，不能只靠 SwiftUI 的 `.environment(\.locale)` —— 后者对 MacCopyKit 中 `String(localized:)` 调用完全无效。
2. 语言状态是跨线程共享的可变全局（引擎后台线程会取错误消息），Swift 6 严格并发下不能用裸 `static var`；需线程安全持有者（如 `NSLock` 保护的 `@unchecked Sendable` 容器，macOS 13 无 `Synchronization.Mutex`）。AD-02 仍满足（只用 Foundation）。架构已实测该方案跨 `Task.detached` 读写正常。
3. **`Localization.string` 必须显式判空**（`value.isEmpty` → 中文基准）；**`Localization.format` 必须实现 `FormatSignature` 守卫**（覆盖 `%@ %d %lld %1$@ %zu %%`，签名或参数数量不符 → 退回中文基准格式串）。二者是 P0-06 / P0-10 的通过前提，且是**防进程崩溃**要求。
4. **P0-08 迁移判定必须放在 `SettingsStore.load()` 内部**，不能放在 `TransferViewModel`：`TransferViewModel.init()` 中 `self.settings = store.load()` 是直接赋值，**Swift init 内赋值不触发 `didSet`**，放 ViewModel 会永远不执行。
5. **中文基准必须绕开 `Bundle.main`**（v1.3 / V-B1~V-B4）：`Localization` 内私有 `baseline(_:_:)` 用**永不存在的 `table:` 名**强制回退编译期 `defaultValue`；`string` 的判空回退、`format` 的 `FormatSignature` 比对基准、防护触发时「退回中文基准」三处的 `base` **一律来自 `baseline()`**。**严禁** `String(localized:key, defaultValue:dv)`（无 `bundle:`）与 `bundle: nil`——正式 `.app` 内含 8 个 `.lproj`，系统语言非中文时会把「中文基准」劫持成该语言译文，导致 §3.4 所列的**四个**连锁失效点（v1.4 升级；其中 V-B5 会让双层防护整体失效并 SIGSEGV）。
6. **`guard let bundle else` 分支必须返回 `baseline()`，不得 `return base`**（v1.4 / V-B6）：整份 `.lproj` 被物理删除时 `bundle == nil`，若 `base` 已被劫持则该分支直接吐出英文串，P0-06 ③ 失效。同时 `FormatSignature` 的比对逻辑**不得只做「两边签名相等即通过」**（V-B5）：当 `base` 与 `candidate` 都被污染时签名会假相等，守卫必须能识别基准本身是否来自 `baseline()`，否则 `%@` 收到 `Int` 仍会 exit 139。

**SwiftUI 即时生效机制（Q2b 已由主理人裁决，按此执行）**：

- **主路径（保留）**：在 `TransferViewModel`（已是 `@MainActor ObservableObject`）增加 `@Published var languageRevision: Int` 与 3 个 `@Published` 菜单文案属性（`menuTransferTitle` / `menuStartTitle` / `menuCancelTitle`）；`MacCopyApp.body` 内**显式读取一次 `languageRevision`** 建立观察依赖，否则 `.commands` 不会重算；各 Scene 根视图加 `.id(vm.languageRevision)` 强制重建；`CommandMenu` 与 `Button` 文字读 VM 的 `@Published` 属性，在 `applyLanguage()` 中与 `languageRevision += 1` 一并重算。
- **兜底（主理人 Q2b 裁决指定，必须实现）**：新增 `src/MacCopyApp/MenuBarLocalizer.swift`，在 `.commands` 经 `body` 重算后仍未刷新时，通过 **`NSApp.mainMenu` 手动更新菜单项标题**。`NSApp` / `NSApplication.mainMenu` 为 `@MainActor` 隔离，该类型必须标注 `@MainActor`，且刷新需**幂等、总调用**（不管当次是否真的变化）。架构已编译验证零警告（V-M1），无窗口服务器下安全返回。
- **隔离约束**：`NSApp.mainMenu` 属 AppKit，**只允许出现在 App target 的 `MenuBarLocalizer` 内，严禁进入 MacCopyKit**（AD-02）。MacCopyKit 仍 Foundation-only。
- 两条保险互不依赖，任一成立即可；成本为一次 `App.body` 重算 + 一次菜单遍历。**这是实现细节，不是降级理由**；整体即时生效为 P0，禁止方案 B'（重启生效），禁止「部分即时 / 部分需重启」混合态。

---

## 四、UI 变更

### 4.1 设置页新增「语言」分组

| 项 | 决策 |
|---|---|
| **位置** | `SettingsView` 的 **第一个 Section，置于「复制引擎」之前**。理由：当用户看不懂当前界面语言时，语言入口必须是最容易被找到的位置；放在末页会导致「读不懂 → 找不到切换入口」的死锁 |
| **图标** | Section 行/标题使用 SF Symbol `globe`（不使用 emoji） |
| **分组标题 key** | `ui.settings.language`（新增） |
| **控件 1** | `Toggle("跟随系统语言", isOn: $vm.settings.languageFollowsSystem)`，默认开 |
| **控件 2** | `Picker("界面语言", selection: $vm.settings.preferredLanguage)`，`跟随系统` 开启时 `.disabled(true)` 并降低不透明度；8 个选项**一律用 endonym 显示**（简体中文 / English / 繁體中文 / 日本語 / 한국어 / Français / Deutsch / Español），保证任何当前语言下都能认出自己的语言 |
| **选项顺序** | 固定为 §2 表格顺序（中文组 → en → 日韩 → 欧洲），**不按当前语言字母序重排**，避免用户切换后选项位置跳动 |
| **当前生效行** | 静态文本：「当前生效：English（跟随系统）」/「当前生效：日本語（手动）」，随语言切换即时更新 |
| **提示行** | 「切换后立即生效，无需重启。」（caption / secondary 样式） |
| **辅助按钮** | 「恢复跟随系统」（仅手动模式下可见），一键清掉手动值 |
| **与「恢复默认设置」的关系** | **语言设置不随「恢复默认设置」重置**。语言属于用户身份偏好，不是引擎参数；用户点了「恢复默认设置」却突然变成另一种语言是错误的。单独用「恢复跟随系统」承载。<br>⚠️ **v1.1 修订**：现状 `SettingsView.swift:113` 是 `vm.settings = AppSettings()`、`SettingsStore.resetToDefaults()` 是 `save(AppSettings())` 全量覆盖，加了语言字段后会**连带重置语言**。必须改为 `vm.resetEngineSettings()`（构造新 `AppSettings()` 后把两个语言字段拷回再赋值），`resetToDefaults()` 改为保留语言或标注「仅供新装初始化」。对应 P0-16 |
| **Section 数量** | 由 v1.0 的 6 个 Section 变为 **7 个**（语言 + 引擎 + 校验 + 冲突 + 限速 + Pro + 重置） |

### 4.2 首次启动语言引导

**决策：不做模态/独立引导页。**
理由：默认「跟随系统」，八种语言用户在首次启动即自动看到自己的语言，引导页纯属多余且增加一次点击；对系统语言不在八种内的用户，v1.0 本来给中文、v1.1 给英文，也不构成需要引导的认知负担。
**替代（P1-02）**：仅当系统语言解析结果为「回退到 en」时，在设置页语言分组内显示一条**非阻塞**提示：「当前系统语言暂未支持，已使用 English。可在下方手动选择。」并提供跳转；不弹窗、不遮挡主窗口。

### 4.3 菜单栏 / 窗口标题

| 元素 | 决策 | 说明 |
|---|---|---|
| **窗口标题**（`RootView` 的 `app.title`） | **不翻译，八语言统一显示 `MacCopy`** | 品牌名；避免商标变形与标题栏布局问题；`app.title` 这个 key 仍保留在 Catalog 中（值恒为 `MacCopy`）以便将来调整 |
| **App 自定义菜单**（`CommandMenu("传输")` 及「开始复制」「取消传输」） | **随语言即时变化** | 由 §3.5 的 `MacCopyApp.body` 观察依赖保证 |
| **系统标准菜单**（文件/编辑/窗口/帮助等） | 由 macOS 依据 `CFBundleLocalizations` 自动本地化，**无需开发** | 要求 `Info.plist` 的 8 个声明齐全，否则系统菜单可能仍为中文 |
| **Dock / Finder 中 App 显示名**（`CFBundleDisplayName`） | 保持 `MacCopy`，不本地化 | `InfoPlist.strings` 本地化显示名列为 P2-03 |
| **Finder 服务菜单项名称**（`ServiceInfo.plist`） | **本次范围外（P1-09）**，跟随系统语言 | 该文案由 macOS 从 Service 自身 bundle 渲染，App 内手动切换**不影响**它；需与主理人确认是否接受此不一致（Q11）。当前 `NSMessage` 用了中文作内部消息名，建议同批改为稳定英文标识符，仅本地化 `NSMenuItem` 显示名 |
| **系统通知文案** | 随语言即时变化 | 由共享 `Localization` 层保证 |
| **布局压力** | 需通过德语/法语长串验收（P1-03） | 德语常比中文长 30–40%，设置页 Section 标题、按钮文字、Picker 行不得截断/重叠 |

---

## 五、需求池

> 编号 `I18N-Px-NN`。P0 = v1.1 发版必须；P1 = v1.1.x；P2 = 后续版本。
> **K 的定义**：`K = 180（v1.0 冻结基准 key） + N（本次新增的语言 UI key，预计 10–14 个）`。发版时以 `sync_catalog.py --check-languages` 实际统计的 K 为准，两套数字都必须在验收报告中列出。

### 5.1 P0 — 必须有

| 编号 | 需求描述 | 优先级 | 验收标准（可验证） |
|---|---|---|---|
| I18N-P0-01 | **八种语言资源与声明齐全** | P0 | ① `dist/MacCopy.app/Contents/Resources/` 下存在且仅存在 8 个 `.lproj`，各自含非空 `Localizable.strings`；② `Info.plist` 的 `CFBundleLocalizations` 恰为 8 项且标签与 `.lproj` 名逐字一致；③ `CFBundleDevelopmentRegion` 保持 `zh-Hans`；④ 8 份 `.strings` 均通过 `plutil -lint`；⑤ `Bundle.main.localizations` 返回 8 个标签 |
| I18N-P0-02 | **每种语言零 key 缺失** | P0 | ① 对最终 key 集合 K，8 种语言各含恰好 K 个条目，缺失数为 0；② `python3 sync_catalog.py --check-languages` 退出码为 0；③ 人为删掉任一语言任一条目后，该命令退出码非 0 并打印「语言 / key / 缺失」三元组；④ 打包脚本在 `--check-languages` 失败时中止，不产出 .app |
| I18N-P0-03 | **简体中文基准不回退** | P0 | ① 冻结快照 `docs/i18n/baseline-v1.0-zh-Hans.json` 中 180 个 key 的取值，与新版 `zh-Hans` 逐字节比对，diff 为空；② 源码中全部 `default:` 参数仍为中文，且未被改写为英文；③ 简体中文模式下对 v1.0 随机抽 20 个界面文案做逐字比对，100% 一致；④ `sourceLanguage` 仍为 `zh-Hans` |
| I18N-P0-04 | **切换机制 C：默认跟随系统 + 手动覆盖** | P0 | ① 全新安装（清空 UserDefaults）默认 `languageFollowsSystem == true`，系统设为 `ja` 时首启即为日语；② 关闭跟随并选 `fr` 后为法语；③ 重新打开跟随后立即回到系统语言；④ 手动值在 App 重启后保持；⑤ 优先级「手动 > 系统」有单测覆盖 |
| I18N-P0-05 | **切换即时生效、无需重启**（Q2b 已裁决，验收标准不降级） | P0 | ① 在设置页切换语言后 ≤ 200 ms 内，主窗口、设置页、进度窗口、Inspector、自定义菜单、窗口标题、Alert 文案全部刷新为新语言（8 种语言 × 逐项人工/截图核验）；② 全程不出现重启提示、不闪退、不白屏；③ **复制任务进行中切换语言**：任务不中断、进度数字连续、速度曲线不断点、无重复传输；④ 已产生的历史日志与已落盘失败原因不被改写（**天然满足**：`LogLine.text` 与 `FileRow.failureReason` 存的是已渲染字符串快照而非 key，禁止改成存 key 再动态渲染）；⑤ 菜单标题刷新双保险均落地：主路径（`MacCopyApp.body` 内有显式 `languageRevision` 观察依赖 + `CommandMenu`/`Button` 文字读 VM `@Published` 属性）与 **`MenuBarLocalizer` 的 `NSApp.mainMenu` 手动刷新兜底**（`@MainActor`、幂等、总调用）均存在；`NSApp.mainMenu` 仅出现在 App target，MacCopyKit 内出现次数为 0；有 grep 或单测固化，防止后续开发者删掉观察依赖 |
| I18N-P0-06 | **漏翻译兜底（含防崩溃）** | P0 | ① 人为从 `de.lproj/Localizable.strings` 删除 3 个 key（含 1 个带 `%@` 的格式串）后启动 App，对应 3 处显示**中文 defaultValue**，不显示 key、不显示空白、不崩溃；② **人为把某 key 置为空串**：必须显示中文兜底（原生 API 会原样返回 `""`，需 `Localization.string` 显式判空，此项为独立验收点）；③ 人为**物理删除整个 `ko.lproj`** 并以 `-AppleLanguages "(ko)"` 启动（V-B6：`bundle == nil` 分支）——App 必须回退到**简体中文**且可正常使用，**不得返回英文串**（该分支若直接 `return base` 且 `base` 被劫持就会返回英文）；④ 以上均在 Release 构建下验证，Debug 下有诊断日志；⑤ **人为把某语言带参译文的 `%d` 改成 `%@` 并触发该文案**：App **不得崩溃**（不得出现 exit 139 / SIGSEGV），应显示中文基准格式化结果并写诊断日志；⑥ **中文基准真实性（v1.3 / V-B1~V-B4，v1.4 依 V-B5/V-B6 加强）**：①②④⑤ 的全部兜底测试**必须在 `Bundle.main` 内确实存在目标语言资源（模拟真实 `.app` 的 `en.lproj`/`ja.lproj`）的环境下执行**，并断言回退结果逐字为**中文**（不得出现 `TOTAL %d ITEMS` 等目标语言串）；实现上 `base` 必须来自 `Localization.baseline(_:_:)`（不存在的 `table:` 名），代码中 `String(localized:key, defaultValue:)` 无 `bundle:` 的写法出现次数为 0。仅在无资源的裸测试进程里验证不算通过；⑦ **叠加条件（v1.4 / V-B5，防第二次假通过）**：⑤ 的坏译文注入**必须与「系统语言 = 该译文语言」叠加**——向 `en.lproj` 注入 `%@` 坏串时须以 `-AppleLanguages "(en)"` 启动；QA 实测 zh-Hans 系统语言下该场景返回「共 5 项」不崩，**只有 en 才触发 `base`/`candidate` 同时被劫持 → `FormatSignature` 判等 → 守卫不触发 → exit 139**。必须断言 EXIT=0 且输出「共 5 项」；⑧ ③ 的 `ko.lproj` 物理删除变体同样纳入本专项（V-B6） |
| I18N-P0-07 | **回退链完整正确** | P0 | 对下列输入逐一有单测并通过：系统 `en-GB`→en、`fr-CA`→fr、`zh-Hant-TW`→zh-Hant、`de-AT`→de、`es-MX`→es、`zh`+区域 TW→zh-Hant、`zh`+区域 CN→zh-Hans、`ru`→en、`it`→en、`pt-BR`→en、`ar`→en；系统语言列表全空→zh-Hans；手动值损坏→按未设置处理并记日志 |
| I18N-P0-08 | **v1.0 升级迁移不回归** | P0 | ① 构造「有旧设置键、无 `languageFollowsSystem` 键」的 UserDefaults，加载后得到 `false + zh-Hans`，且其余 13 项旧设置值与构造值逐项一致；② 全新 UserDefaults 不受迁移规则影响，仍为 `true`；③ 迁移只发生一次（写键后重启不再重复提示）；④ 设置页显示一次性提示文案；⑤ **迁移判定必须位于 `SettingsStore.load()` 内部**——`TransferViewModel.init()` 中 `self.settings = store.load()` 在 Swift init 内赋值**不触发 `didSet`**，放 ViewModel 会永远不执行；需有单测直接调 `SettingsStore.load()` 验证（不经过 ViewModel） |
| I18N-P0-09 | **设置持久化向后兼容** | P0 | ① `AppSettings` 新增 `languageFollowsSystem: Bool = true` 与 `preferredLanguage: String? = nil`；② `SettingsStore.load()` 用 `object(forKey:) != nil` 守卫，旧偏好文件读取不丢任何既有字段；③ `save()` 写入两个新键；④ 手动值非法（如 `xx-YY`）时优雅回退，不崩溃；⑤ 不引入 `Codable` 全量替换（现状是逐键 UserDefaults，改动最小） |
| I18N-P0-10 | **格式串占位符一致性（双层防护）** | P0 | ① `sync_catalog.py --check-languages` 对每种语言的每个 key 校验 `%@`/`%d`/`%lld`/`%1$@`/`%zu`/`%%` 占位符的**数量与类型**与 zh-Hans 基准一致；② 人为把某语言 `%d` 改成 `%@` 时构建检查失败并指出 key（第一层）；③ 所有 8 语言中随机抽 10 个带参文案，运行时参数正确代入；④ **第二层**：`Localization.format` 实现 `FormatSignature` 守卫，绕过构建检查直接注入坏译文时，签名不符/参数不足会**退回中文基准格式串**再格式化，进程不崩溃（原生 `String(format:)` 会 SIGSEGV），结果正确且写诊断日志；⑤ 两层各有独立单测，缺一不通过；⑥ **`FormatSignature` 的比对基准必须取自 `Localization.baseline(_:_:)`**（不存在的 `table:` 名），不得用 `Bundle.main` 解析出的当前语言串——否则基准随系统语言漂移、防护判定失真（V-B1）；需有单测在 `Bundle.main` 含 `en.lproj` 时断言基准仍为中文；⑦ **（v1.4 / V-B5，v1.6 补前置断言）基准污染会让双层防护整体失效**：须有**用例**构造「`base` 与 `candidate` 同时被劫持为 `TOTAL %@ ITEMS`」的场景，断言 `FormatSignature` **不会**因两边签名相等而放过、`String(format:)` 不崩溃、EXIT=0；该用例必须以 `-AppleLanguages "(en)"` 启动叠加系统语言，否则 zh-Hans 下假通过。⑧ **（v1.6 / QA A6，v1.7 定稿覆盖方式）必须先断言「双劫持前置条件确实成立」**：在同一环境下单独探测无 `bundle:` 的 `base` 与显式语言 Bundle 的 `candidate`，断言两者逐字同为 `TOTAL %@ ITEMS`（如 `TOTAL %@ ITEMS|TOTAL %@ ITEMS`）。**若注入失效、只有一边被劫持，⑦ 的用例会静默变成平凡通过**——第三类假通过，必须先证伪再验收。✅ **⑦⑧ 均由 `proqa/i18n_acceptance.sh` 的 `badformat` / `--case=double_hijack` 覆盖（A6 PASS，9/9），不要求 `src/` 内再有同名单测**（主理人定稿） |
| I18N-P0-11 | **共享层切换覆盖 MacCopyKit** | P0 | ① `Localization.string/format` 的实现改为使用语言专用 `Bundle`，且 `Localization` 仍只依赖 Foundation（AD-02 静态扫描：MacCopyKit 内 `import SwiftUI`/`import AppKit` 出现次数为 0）；② 切换到英语后，新产生的 `MacCopyError` 描述、`ConflictPolicy.displayName`、`TaskState` 文案、Verifier 失败原因均为英语；③ 切换后 CLI/报告新生成文本使用新语言（已落盘历史文本不改写） |
| I18N-P0-12 | **既有测试零回归**（数量以 `bash test.sh` 实际输出为准，不写具体数字） | P0 | ① 施工前基线测试全部通过，无 skip、无 xfail、无超时，**数量与结果以 `bash test.sh` 实际输出为准（全绿，不写具体数字）**；② `swiftc` 编译零 error、零新增 warning（Swift 6 严格并发下无 data race 告警）；③ 新增语言专项测试 ≥ 8 个（每语言 1 组覆盖 + 回退链 + 漏译兜底 + 切换 + 迁移），全部通过；④ 复制引擎/校验/断点续传相关测试的断言值一个都不许改；⑤ 本报告/PRD 中凡出现「基线测试数量」均以该命令输出为准，不再硬编码数字 |
| I18N-P0-13 | **零第三方依赖与架构约束** | P0 | ① 未新增任何 SwiftPM/Package/Carthage/CocoaPods 依赖，`build.sh` 源文件清单中不出现新外部模块（**AppKit 是系统框架，仅用于 App target 的 `MenuBarLocalizer`，不计第三方依赖**）；② 未使用 `@Observable`（AD-01 扫描为 0）；③ 语言切换不引入网络请求、不下载翻译包、机翻初稿离线产出；④ 打包后 `.app` 体积增量 ≤ 200 KiB（8 份纯文本 strings 的合理上限） |
| I18N-P0-14 | **打包链路产出八语言** | P0 | ① `package_app.sh` 从单一 `.xcstrings` 生成 8 份 `.lproj/Localizable.strings`，日志逐语言打印条目数；② 每份条目数 = K；③ `sync_catalog.py` 与 `package_app.sh` 的 Catalog 路径随 §2「上移一层」同步更新且脚本可独立运行；④ 重复执行 `package_app.sh` 幂等（不累加、不残留旧 `zh-Hans.lproj/Localizable.xcstrings`） |
| I18N-P0-15 | **繁体中文不得简繁机械转换** | P0 | 提交 `docs/i18n/glossary-zh-Hant.md`，至少覆盖 20 个术语（文件/檔案、复制/複製、校验/校驗、缓冲区/緩衝區、线程/執行緒、断点续传/斷點續傳、稀疏文件/稀疏檔案、队列/佇列、探针/探針、吞吐量/輸送量 等）；`zh-Hant` 译文不得出现简体特有字词，由 `sync_catalog.py --check-languages` 读 `docs/i18n/simplified-chars.txt` 逐条扫描，命中即失败并打印「key / 命中字」；**禁止简繁机械转换**，须按术语表人工校正（此项 ≠ 全量母语审校，口径见 §9） |
| I18N-P0-16 | **「恢复默认设置」不重置语言**（Q7 落地） | P0 | ① `SettingsView` 的「恢复默认设置」改为调用 `vm.resetEngineSettings()`，不得再是 `vm.settings = AppSettings()`；② 构造「手动日语 + 非默认引擎参数」状态点击该按钮后：全部引擎参数回到默认值，而 `languageFollowsSystem == false` 且 `preferredLanguage == "ja"` 保持不变，界面仍为日语；③ `SettingsStore.resetToDefaults()` 保留语言字段或明确标注「仅供新装初始化」；④ 有单测覆盖；⑤ 「恢复跟随系统」按钮独立可用，点击后语言回到系统解析结果 |

| I18N-P0-17 | **翻译数据与代码分离**（主理人追加硬要求） | P0 | ① `src/MacCopyApp/Localization/translations/` 下存在且仅存在 8 份 `<lang>.json`，格式 `{"key": "译文"}`，是**译文唯一事实源**；② `sync_catalog.py --merge-translations` 从 8 份 JSON 生成单一 `.xcstrings`，**脚本不得反向写 JSON**；③ `--sync` 能从源码扫出新 key 并补进各 JSON（值为空、待译），不覆盖已有译文；④ `--check-languages` **五项**硬校验齐全：逐语种零缺失（键集合与 `zh-Hans.json` 完全一致、含多余 key 检查）、占位符数量与类型、空串/全空白、**`zh-Hant` 简体字扫描**、**基准占位符签名未漂移**（`baseline-placeholders.json`）；并与中文基准快照 180 条逐字比对；⑤ 人为把 `de.json` 某条置空或删 key 时检查非零退出并打印「语言 / key / 原因」，打包中止；⑥ `docs/i18n/simplified-chars.txt` 只含简体侧专用字，对「文/件/中/大」等共用字不误报（有单测或样例验证）；⑦ 后续替换任一语言译文只需改对应 JSON，不改任何 Swift 代码 |
| I18N-P0-18 | **已知限制与对外口径统一**（Q5 裁决落地） | P0 | ① 设计文档、交付说明、Release Notes、发版说明、对外宣传统一采用 §9 的交付说明原文口径；② 仓库字面扫描**仅**「专业本地化」「母语级翻译」「人工审校通过」**三个禁用短语**，命中数为 0。**「母语审校」四字刻意不纳入扫描**（主理人定稿：§7 / §9 与架构 §9 都需用它描述「无该资源」与 P1-04 后续计划，纳入会自相矛盾），不改成范围化规则；③ 明确说明「除简体中文外其余七种语言为机翻初稿、未经母语审校」；④ 明确标注 Q11 的 Finder 服务菜单语言不一致；⑤ 繁中按术语表人工校正 **不得**被表述为全量母语审校；⑥ **发版说明须同时并列披露架构裁决 A 的已知限制**（§9「其他须写入发版说明的已知限制」原话），与 Q5 / Q11 三条并列，不得只披露其中一条 |

> **P0 计数变更**：v1.0 为 15 条 → v1.1 为 **16 条**（新增 P0-16）→ **v1.2 为 18 条**（新增 P0-17 翻译数据分离、P0-18 已知限制口径；P0-05/06/10/15 验收标准加强，条目数不变）。

### 5.2 P1 — 应该有（v1.1.x）

| 编号 | 需求描述 | 优先级 | 验收标准 |
|---|---|---|---|
| I18N-P1-01 | 语言选项行显示 endonym + 当前语言的对应名称（如「Deutsch（德语）」） | P1 | 8 个选项在任一界面语言下均可辨认，行高不变、不截断 |
| I18N-P1-02 | 系统语言未支持时，设置页内非阻塞提示 + 一键切到可用语言 | P1 | 系统设为 `ru` 时提示出现，不弹窗、不遮挡；点击后 200ms 内切换 |
| I18N-P1-03 | 八语言 UI 布局压力验收 | P1 | 对 8 种语言各截主窗口/设置页/进度窗/校验结果 4 张图共 32 张；德语/法语最长串无截断、无重叠、无文字溢出；表单控件不被挤压 |
| I18N-P1-04 | 八语言术语表与**后续**母语审校流程（Q5 裁决：**保持 P1、待资源**，v1.1 不执行） | P1 | `docs/i18n/glossary.md` 覆盖 8 语言 × 核心 30 术语；给出「若后续获得审校资源」时的执行流程（只替换 `translations/<lang>.json`，不改代码）；**v1.1 交付文档中不得声称已审校**，未审校语言在 §9 已知限制中显式标注 |
| I18N-P1-05 | 「数字与日期格式跟随界面语言」可选开关 | P1 | 开启后，字节/日期/时长中的小数分隔符、日期顺序按所选语言渲染；关闭时保持系统区域设置（默认关）。见 Q3 |
| I18N-P1-06 | 关于页「帮助改进翻译」入口 | P1 | 点击打开项目反馈页/说明，不联网自动上传任何数据 |
| I18N-P1-07 | 导出报告头部标注界面语言 | P1 | CSV/HTML 报告含 `Language: <tag>` 字段；不影响既有数据列与 `shasum -c` 兼容的 checksum 文件 |
| I18N-P1-08 | CLI 与 Service 语言一致性 | P1 | CLI 输出语言与 App 手动设置一致（或支持 `MACCOPY_LANG` 环境变量覆盖）；不一致场景有文档说明 |
| I18N-P1-09 | Finder 服务菜单名称本地化 | P1 | Service bundle 内 8 份 `InfoPlist.strings`；`NSMessage` 改为稳定英文标识符，仅 `NSMenuItem` 显示名本地化；8 语言下 Finder 右键服务名正确 |
| I18N-P1-10 | `zh-Hant` 区域细分（`zh-Hant-TW` / `zh-Hant-HK`） | P1 | 可按需覆盖术语差异，回退到通用 `zh-Hant` |

### 5.3 P2 — 锦上添花 / 长期

| 编号 | 需求描述 | 优先级 | 验收标准 |
|---|---|---|---|
| I18N-P2-01 | 扩展语言：俄语 `ru`、葡语（巴西）`pt-BR`、意大利语 `it`（按此顺序） | P2 | 新增语言只加 `.lproj` + Catalog 条目 + 清单注册，不改引擎代码（插件式扩展验证） |
| I18N-P2-02 | RTL 语言（阿拉伯语 / 希伯来语）支持 | P2 | **明确本次范围外**：八种语言均非 RTL，v1.1 不做镜像布局；未来作为独立项目（需全量 UI 镜像审查） |
| I18N-P2-03 | `InfoPlist.strings` 本地化 App 显示名 | P2 | Finder/Dock 显示名按语言变化（品牌名一致性需重新评估） |
| I18N-P2-04 | 语言偏好 iCloud 同步（Pro） | P2 | 多设备一致 |

### 5.4 明确不做（避免架构师误设计）

- ❌ **不做**应用内翻译编辑器 / 在线翻译热更新（零第三方依赖 + 不联网约束下不成立）。
- ❌ **不做**「按内容自动识别语言」或「混合语言界面」。
- ❌ **不做**重启生效方案（方案 B）——已验证可即时生效，且重启会打断复制任务，与 P0-05 直接冲突。
- ❌ **不改** `CFBundleDevelopmentRegion`（保持 `zh-Hans`）以维持中文兜底语义。

---

## 六、给架构师的变更点清单（实现范围，逐项可派工）

| # | 文件 / 位置 | 变更 | 约束 |
|---|---|---|---|
| C1 | `src/MacCopyApp/Localization/Localizable.xcstrings` | 从 `zh-Hans.lproj/` **上移一层**；每个 key 由 1 个 `localizations.zh-Hans` 扩为 8 个语言条目；`sourceLanguage` 保持 `zh-Hans`；新增语言 UI 的 N 个 key。**v1.2：降为由 `translations/*.json` 经 `--merge-translations` 生成的产物，不再手工编辑** | 单 Catalog（生成物）；`state` 统一 `translated`；**脚本不得反向写 JSON** |
| C2 | `src/MacCopyKit/Support/Localization.swift` | 增加语言专用 `Bundle` 解析与线程安全持有者；`string`/`format` 改用 `String(localized:defaultValue:bundle:)`；保留现有函数签名（**调用方 0 改动**）；**`string` 补 `value.isEmpty` 判空回退；`format` 补 `FormatSignature` 守卫，签名不符/参数不足时退回中文基准**；**v1.3：先实现私有 `baseline(_:_:)`，用永不存在的 `table:` 名取中文基准，`string`/`format` 内所有 `base` 一律来自它，严禁无 `bundle:` 的 `String(localized:defaultValue:)` 与 `bundle: nil`（V-B1~V-B4 / AD-I12）** | Foundation-only；Swift 6 严格并发安全（NSLock + `@unchecked Sendable`）；AD-02；**判空与守卫是防 SIGSEGV 的 P0 硬要求，不可省** |
| C3 | 新增 `src/MacCopyKit/Support/LanguageResolver.swift`（建议） | §3.3 回退链、8 语言标签常量表、endonym 表、系统语言解析 | Foundation-only，纯函数、可单测 |
| C4 | `src/MacCopyKit/Persistence/SettingsStore.swift` | `AppSettings` 加 2 字段；`SettingsKey` 加 2 常量；`load()`/`save()` 加守卫；**P0-08 迁移判定必须写在 `load()` 内部**（`ViewModel.init()` 直接赋值不触发 `didSet`）；`resetToDefaults()` 保留语言字段或标注「仅供新装初始化」 | 逐键 UserDefaults，不换 Codable；旧偏好兼容 |
| C5 | `src/MacCopyApp/TransferViewModel.swift` | 加 `@Published var languageRevision` + 3 个 `@Published` 菜单文案属性；`applyLanguage()` 中一并重算并 `+1`；新增 `resetEngineSettings()`（构造新 `AppSettings()` 后拷回两个语言字段） | `@MainActor` / `ObservableObject`，AD-01 |
| C6 | `src/MacCopyApp/MacCopyApp.swift` | `body` 内显式读取 `languageRevision` 建立观察依赖；各 Scene 根视图加 `.id(vm.languageRevision)`；`CommandMenu`/`Button` 文字读 VM 的 `@Published` 属性（主路径） | 保证 `.commands` 重算；Q2b 已裁决不降级 |
| C15 | **新增** `src/MacCopyApp/MenuBarLocalizer.swift` | **主理人 Q2b 裁决指定的兜底实现**：`NSApp.mainMenu` 手动更新菜单项标题；`applyLanguage()` 中总调用、幂等 | 必须标 `@MainActor`（`NSApp.mainMenu` 为 `@MainActor` 隔离，否则 Swift 6 告警）；**AppKit 仅此层，严禁进入 MacCopyKit**（AD-02）；无窗口服务器下安全返回 |
| C7 | `src/MacCopyApp/Views/SettingsView.swift` | 首位新增「语言」Section（§4.1）；**「恢复默认设置」按钮改调 `vm.resetEngineSettings()`，不得再是 `vm.settings = AppSettings()`** | 全部文案走 `Localization.string/format`，零裸字面量；P0-16 |
| C8 | `src/MacCopyApp/Info.plist` | `CFBundleLocalizations` 扩为 8 项；`CFBundleDevelopmentRegion` 不变 | 标签与 `.lproj` 名一致 |
| C9 | `sync_catalog.py` | **v1.2 改为三子命令**：`--sync`（扫源码补新 key 到各 JSON，值为空待译，不覆盖已有译文）、`--merge-translations`（8 份 JSON → 单一 `.xcstrings`）、`--check-languages`（**五项硬校验**：逐语种零缺失且键集合一致（含多余 key）/ 占位符数量与类型 / 空串全空白 / `zh-Hant` 简体字扫描 / **基准占位符签名未漂移**；并与中文基准快照 180 条逐字比对）；失败非零退出码阻断打包 | Python 3 标准库，零依赖；`CATALOG` 路径上移一层；**不得反向写 `translations/*.json`** |
| C10 | `package_app.sh` | 输入路径更新；`install -d` 创建 8 个 `.lproj`；从 Catalog 的 8 个 `localizations` 各生成一份 `.strings`；先跑 `--check-languages` 再打包 | `install -d`（沙盒下 mkdir 被拦）；幂等 |
| C11 | `docs/i18n/` 与 `translations/` | 新增：`baseline-v1.0-zh-Hans.json`（**写任何译文之前导出**）、`glossary-zh-Hant.md`（≥20 术语）、`simplified-chars.txt`（仅简体侧专用字）、`src/MacCopyApp/Localization/translations/<lang>.json` × 8 | 随仓库提交；译文唯一事实源是 8 份 JSON |
| C16 | 交付说明 / Release Notes / 发版说明 / 对外宣传 | 采用 §9 的统一口径原文；显式标注机翻初稿与 Q11 不一致 | **禁用**「专业本地化」「母语级翻译」「人工审校通过」等表述；仓库字面扫描命中数 0（P0-18） |
| C12 | `src/MacCopyService/ServiceInfo.plist` | 本次**不改**（P1-09 再动） | 记录为已知不一致，见 Q11 |
| C13 | 测试 | 新增 `LanguageResolver` / `Localization` / `SettingsStore` 迁移 / 8 语言覆盖 等专项测试 ≥ 8 个；既有基线测试一个不改（数量以 `bash test.sh` 实际输出为准，不写具体数字）；**额外覆盖：空串 key 回退、坏占位符不崩溃、`resetEngineSettings` 保留语言、`SettingsStore.load()` 直接调用触发迁移、菜单观察依赖存在性 grep** | 全绿。**新增测试若用独立 `swiftc`，模块缓存必须用绝对路径**（如 `/tmp/mc-arch-cache`）；相对路径 `.tmp/modcache` 曾因 `Workbuddy` vs `WorkBuddy` 大小写不一致触发 `_DarwinFoundation1` 重复定义 + signal 11。`build.sh`/`test.sh` 现有方式不受影响 |
| C14 | `LogLine.text` / `FileRow.failureReason` | **本次不改**：二者存的是已渲染字符串快照而非 key，P0-05 ④ 天然满足 | 明确禁止「改成存 key 再动态渲染」的画蛇添足式重构（架构 AD-I06 已确认） |

---

## 七、待确认问题（✅ 已全部裁决，无开放项）

> **状态说明（v1.7 · 主理人最终定稿）**：PRD §7 的 Q1–Q12 全部 12 问 + Q2b + Q5 **已由主理人裁决完毕并二次确认关闭**，架构 `docs/ARCHITECTURE-I18N.md` §0 / §11 确认「无阻塞性待明确项」。Q5 的关闭结论在 v1.7 再次明确为「无母语审校资源、按推荐执行」，P1-04 保持 P1、v1.1 不执行且不得声称已审校；P0-18 禁用词扫描范围维持三个短语、不改成范围化规则。
> - **Q1 / Q2 / Q3 / Q4 / Q6 / Q7 / Q8 / Q9 / Q11 / Q12**：全部按本表推荐执行，主理人无异议。
> - **Q2b**：否决降级路径，**降级路径整行作废**；兜底实现指定为 `NSApp.mainMenu` 手动更新（`MenuBarLocalizer`）。
> - **Q5**：**无母语审校资源**，机翻质量为已知限制（见 §9），P1-04 保持 P1、不提前到 P0。
> - **Q10**：八语清单锁定，`es` 保留，**不换 `pt-BR`**。
> - **追加硬要求**：翻译数据与代码分离（§2 / P0-17）。

| # | 问题 | 推荐选项 | 理由 |
|---|---|---|---|
| **Q1** | 系统语言不在八种内时回退到英语还是简体中文？ | **回退到 `en`，并为 v1.0 升级用户保留简体中文（§3.3 迁移规则）** | 中文是基准语言不是用户兜底语言；对 ru/it/pt-BR 用户显示中文与强制中文一样不可读；迁移规则避免老用户静默回归 |
| **Q2** | 是否接受「立即生效、无需重启」作为 P0 硬指标？ | **接受，且必须 P0**；已实测 `String(localized:defaultValue:bundle:)` + `.lproj` Bundle 可即时切换且漏 key 自动回退中文，实现成本可控 | 重启会中断正在进行的复制任务，与 PRD G3/G4 冲突；方案 B 已因 `AppleLanguages` 对已构造 Bundle 无效被排除 |
| **Q2b** | 若架构评审发现 `.commands` 菜单标题重建成本超预期，允许降级吗？ | ✅ **已关闭 · 架构评审已裁决：降级路径不启用，P0-05 验收标准一个字不改**。✅ **主理人追加裁决：降级路径整行作废、禁止方案 B'（重启生效）、禁止混合态**；`.commands` 兜底指定实现为 **`NSApp.mainMenu` 手动更新菜单项标题**（`MenuBarLocalizer`，`@MainActor`、幂等总调用），**不是** `@Published` 菜单文字（后者仍属主路径的一部分） | 架构用项目真实编译参数实跑 SwiftUI App 探针零 error（V-M1 亦已编译验证 `NSApp.mainMenu` 方案零警告），主路径 + `NSApp.mainMenu` 兜底双保险任一成立即可，「成本超预期」前提不成立；反过来降级到重启会直接违反 P0-05 ③（复制中切换不中断），破坏 G3/G4。**该兜底是实现细节，不是降级理由**。架构已用 T-I04 的 grep 验收 + 单测固化「开发者忘建观察依赖」这一真正的风险 |
| **Q3** | 数字 / 日期 / 字节单位是否需要随界面语言本地化？ | **v1.1 保持现状（跟随系统区域设置），P1-05 再加可选开关** | 实测 `ByteCountFormatter` **没有 `locale` 属性**，隐式用 `Locale.current`，零依赖下无法按 App 语言覆盖（除非改用 `NumberFormatter` 自行拼单位，成本高且会与 Finder 显示不一致）；`KB/MB/GB/TB` 与 `s/m/h` 为国际单位，八语言用户均可理解；风险是法语/德语用户手动切语言后仍看到 `1.5 GB` 而非 `1,5 Go`，需在 Q3 确认可接受 |
| **Q4** | RTL 语言是否在范围内？ | **明确范围外（P2-02 仅为占位）** | 八种语言全部 LTR；RTL 需全量 UI 镜像审查，是独立项目，不应混入本次增量 |
| **Q5** | 翻译质量由谁校对？是否有机翻/母语审校资源？ | ✅ **已裁决：没有母语审校资源**。执行「机翻初稿 + 构建期自动校验（占位符/空串/`zh-Hant` 简体字/零缺失） + 每语种抽查 20 条」；**翻译质量属机翻水平，必须作为已知限制写进设计与交付说明，不得表述为专业本地化**；**P1-04 保持 P1，不提前到 P0**。`zh-Hant` 术语表（≥20 条）+ 禁简繁机械转换仍为 P0-15，但按表人工校正 ≠ 全量母语审校。统一口径见 §9 / P0-18 | 主理人裁决，架构不介入（只影响翻译流程、不影响架构）。若后续获得审校资源，只需替换 `translations/<lang>.json`，不改任何代码与架构（这也是 P0-17 数据分离的直接收益） |
| **Q6** | `zh-Hant` 是否拆分 TW / HK 地区变体？ | **v1.1 只做单一 `zh-Hant`，用通用术语避免地区差异；细分列 P1-10** | 拆分会让语言数从 8 变 9–10 且翻译量翻倍；`zh-Hant-TW` 系统语言按前缀归并到 `zh-Hant` 已够用 |
| **Q7** | 「恢复默认设置」是否重置语言？ | **不重置**，单独提供「恢复跟随系统」按钮。⚠️ **v1.1 修订：已升级为 P0-16 硬验收项** | 语言是身份偏好不是引擎参数；点「恢复默认」却突然换语言是明显的产品错误。架构扫描发现现状 `SettingsView.swift:113` 是 `vm.settings = AppSettings()`、`SettingsStore.resetToDefaults()` 是 `save(AppSettings())` 全量覆盖，**加了语言字段后会连带重置**，必须改为 `vm.resetEngineSettings()` 保留两个语言字段 |
| **Q8** | 首次启动是否做语言引导？ | **不做模态引导页**，仅 P1-02 在设置页内对未支持系统语言给非阻塞提示 | 跟随系统已让八语言用户零配置正确；引导页只增加一次点击 |
| **Q9** | 品牌名 / 窗口标题是否翻译？ | **不翻译**，八语言统一 `MacCopy` | 商标一致性、避免标题栏布局问题；菜单栏自定义项与系统菜单仍随语言变化 |
| **Q10** | 八种语言清单是否锁定？是否用 `ru`/`pt-BR`/`it` 替换 `es`？ | ✅ **已裁决：八种语言清单锁定，`es` 保留，不换 `pt-BR`**，其余 7 种不动；`ru`/`pt-BR`/`it` 仅保留为 P2-01 后续扩展顺位 | 主理人裁决；§2 原「若坚持对齐 TeraCopy 语种则 es → pt-BR」的备选表述**作废** |
| **Q11** | Finder 服务菜单项（由 Service bundle 渲染、跟随系统语言）与 App 内手动语言不一致，是否接受？ | **v1.1 接受此不一致**（P1-09 再统一）；但建议在架构文档与发版说明中显式标注 | 服务菜单名由 macOS 从 Service 自身 bundle 读取，无法读取主 App 的 UserDefaults（沙盒/进程隔离），统一需要跨进程共享偏好，成本超出本次增量 |
| **Q12** | 手动语言设置是否要同步给 CLI / Service？ | **v1.1 不同步**：CLI 使用系统语言或 `MACCOPY_LANG` 环境变量；P1-08 统一 | 避免本次改动扩散到 3 个 target；CLI 主要面向自动化，语言由运行环境决定更合理 |

---

## 八、发版验收清单

- [ ] I18N-P0-01 ~ **P0-18** 全部通过，每条有测试或可复现脚本佐证
- [ ] 8 种语言各 K 个 key 零缺失；`K` 与 `180 + N` 两个数字在验收报告中明确列出
- [ ] 中文基准 180 key 与冻结快照 diff 为空；`defaultValue` 全为中文；**冻结快照在写任何译文之前导出**
- [ ] **译文数据分离（P0-17）**：8 份 `translations/<lang>.json` 为唯一事实源；`--sync` / `--merge-translations` / `--check-languages` 三子命令齐全；脚本不反向写 JSON；人为把 `de.json` 某条置空或删 key 时打包中止
- [ ] **`--check-languages` 五项硬校验**全部生效：零缺失且键集合一致（含多余 key）/ 占位符数量与类型 / 空串全空白 / `zh-Hant` 简体字扫描（共用字不误报）/ **基准占位符签名未漂移**；并与中文基准快照 180 条逐字比对（P0-03）；`ensureHealthyTranslations()` 重建译文后五项仍逐条全跑。**第 ⑤ 项独立承重证据**：QA 在临时副本 `proqa/.check5`（已清理）只篡改冻结签名、译文与 180 条快照不动 → `EXIT=1` 且失败项恰好 1 条；清理后真实文件未动、真实 `--check-languages` `EXIT=0`。**成功打印行只列四项属已知文案滞后（§2），不得据此判第 ⑤ 项未生效**
- [ ] 回退链 12 组输入、漏译 **5** 种破坏场景（删 key / **空串** / 删整份 `.lproj` / **坏占位符** / 非法手动值）、迁移 5 项，全部有单测
- [ ] **防崩溃专项**：注入 `%@` 误收 `Int` 的坏译文后，App 不出现 exit 139 / SIGSEGV，退回中文基准且结果正确
- [ ] **中文基准真实性专项（v1.3 / V-B1~V-B4，v1.4 依 V-B5/V-B6 加强）**：在 `Bundle.main` 含 `en.lproj`/`ja.lproj` 资源的环境下复跑空串回退、漏 key 回退、坏占位符防护，断言结果逐字为**中文**（非 `TOTAL %d ITEMS`）；`Localization.baseline(_:_:)` 用不存在的 `table:` 名；源码中无 `bundle:` 的 `String(localized:defaultValue:)` 出现次数为 0；含 HIJACKED 注入场景不被劫持
- [ ] **v1.4 两条叠加条件 + v1.6 前置断言（每一条缺失都会造成假通过，QA 单条验收命令须同时覆盖）**：① 坏译文注入时**系统语言 = 该译文语言**（`en.lproj` 注入坏串须 `-AppleLanguages "(en)"` 启动；zh-Hans 下 V-B5 不触发、会假通过），断言 `base`/`candidate` 双劫持场景下 `FormatSignature` 不放过、EXIT=0、输出「共 5 项」；② **`ko.lproj` 物理删除 + `-AppleLanguages "(ko)"` 变体**（V-B6，`bundle == nil` 分支），断言返回**中文**而非英文串，且删除动作须有 `[ ! -d ... ] || die` 硬校验；③ **（v1.6 / QA A6，v1.7–v1.8 定稿覆盖方式）双劫持前置条件显式断言**：**由 QA #13 的 `proqa/i18n_acceptance.sh` A6 case `--case=double_hijack` 覆盖**（实测 A6 PASS、整套 9/9，且**已接入 `test.sh` 第 ⑥ 步，每次回归都会跑到**），先单独探测并断言 `base` 与 `candidate` 逐字同为 `TOTAL %@ ITEMS`，否则注入失效会让 ① 静默平凡通过；**A4 断言产品 `Localization.format` 仍返回「共 5 项」且 EXIT=0，A6 断言前置条件成立，两者互补**；**`MacCopy/Tests/` 内无独立双劫持单测编号，不要求补、不得为此追加测试代码**（主理人定稿 + 工程师回执）；④ 反证：同一 case 以 `-AppleLanguages "(zh-Hans)"` 跑一次，打印「zh-Hans 全绿但 en 下 exit 139」证明不叠加会假通过
- [ ] **QA A/B 矩阵对照（可复跑、可归档）**：空串 ❌→✅ 中文兜底、`%@` 误收 Int ❌ exit 139 → ✅「共 5 项」EXIT=0、删 `ko.lproj` ❌ 英文 → ✅ 中文；三个场景均需有修正前后的对照记录。**执行 `bash proqa/i18n_ab_matrix.sh`（用 `build_broken_kit.sh` / `build_fixed_kit.sh` 各编一份 kit，均不改 `src/`），断言 `RESULT|PASS` 且退出码 0，并归档 `proqa/i18n_ab_matrix.md`（含叠加条件说明、版本号锚定、生成时间）**。该归档同时是 `docs/PRD.md` 附录 B.2 第 4 条「可复跑 + 留痕」的**样板证据**：两版 kit 均在临时副本产生、未修改 `src/`
- [ ] 切换即时生效：8 语言 × 7 个界面元素核验完毕，任务进行中切换不中断；**主路径 + `MenuBarLocalizer`（`NSApp.mainMenu`、`@MainActor`、幂等）双保险均落地**；`NSApp.mainMenu` 未出现在 MacCopyKit
- [ ] **「恢复默认设置」后语言保持不变**（手动日语场景有单测），「恢复跟随系统」独立可用
- [ ] **对外口径（P0-18）**：采用 §9 交付说明原文；仅「专业本地化 / 母语级翻译 / 人工审校通过」三个禁用短语扫描命中数 0（「母语审校」四字不纳入，主理人定稿）；Q5 机翻限制、Q11 菜单不一致、**架构裁决 A 的 APFS 克隆 fd 通道限制**三条**并列披露**，不得只披露其中一条
- [ ] 既有基线测试全绿（以 `bash test.sh` 实际输出为准，不写具体数字）；新增语言专项测试 ≥ 8 个全绿；Swift 6 零 data race 告警
- [ ] AD-01 / AD-02 静态扫描通过；零第三方依赖（AppKit 仅 App target 的 `MenuBarLocalizer`）；`.app` 体积增量 ≤ 200 KiB —— **P0-13 ④ 独立证据**：QA 实测 Resources 远低于上限、`plutil -lint` 全过、`codesign --verify --deep --strict` 有效、仅依赖 `@rpath/libMacCopyKit.dylib` + `libSystem`。证据文件 `proqa/qa_package.log` / `proqa/qa_build_final.log` / `proqa/qa_final_confirm.log` / `proqa/qa_closeout.log`（此处不写具体数字）
- [ ] `package_app.sh` 幂等产出 8 份 `.lproj`；`plutil -lint` 全过 —— **P0-14 ④ 独立证据**：连续执行两次后 8 个 `.lproj` 数不变、无残留 `.xcstrings`、每份 K 条、`--check-languages` 先行校验通过。证据文件 `proqa/qa_package.log` 与 `proqa/qa_package2.log`（两次打包）、`proqa/qa_checklang.log`
- [ ] 32 张多语言截图（P1-03）无截断/重叠，德语长串通过
- [ ] 文档、Release Notes、设置页文案统一使用「八种语言」；仓库字面扫描中「国家」量词式表述命中数为 0（架构 §8 与 `test.sh` 静态扫描已落实，可打勾）
- [ ] §7 的 Q1–Q12（含 Q2b 子项，共 13 行）**全部已由主理人裁决并回写**（无开放项）

---

## 九、已知限制与对外口径（Q5 裁决 + 架构裁决 A，强制统一）

> 本节 Q5 部分与 `docs/ARCHITECTURE-I18N.md` §9 同源，**口径必须逐字一致**；架构裁决 A 部分与 `docs/PRD.md` 附录 C 同源。设计文档、交付说明、Release Notes、发版说明、对外宣传一律照此表述。
> **三条已知限制（Q5 机翻 / Q11 菜单不一致 / 架构裁决 A 克隆 fd 通道）须并列披露，不得只披露其中一条**（P0-18 ⑥）。

| 项 | 结论 |
|---|---|
| 审校资源 | 主理人裁决：**没有母语审校资源** |
| 翻译产出方式 | 基于中文基准逐条产出的**机翻初稿**（不联网、不下载翻译包、不引入第三方服务），未经母语审校 |
| 质量表述 | **翻译质量属机翻水平**。**不得**出现「专业本地化」「母语级翻译」「人工审校通过」等表述 |
| 质量保障手段 | 构建期自动校验（占位符数量与类型 / 空串 / `zh-Hant` 简体字 / 零缺失）+ 每语种抽查 20 条（产品侧）+ 全部既有回归测试（以 `bash test.sh` 实际输出为准，不写具体数字） |
| `zh-Hant` 例外 | 仍需术语表（≥20 条）并**禁止简繁机械转换**（P0-15）；术语按表人工校正，但**不等于**全量母语审校 |
| 后续演进 | 母语审校列 **P1-04，保持 P1**；若后续获得审校资源，只需替换 `translations/<lang>.json`，不改任何代码与架构 |

**必须写入交付说明的原文（直接引用，勿改写）**：

> MacCopy v1.1 提供八种语言界面。除简体中文（产品基准语言）外，其余七种语言的译文为机翻初稿，未经母语审校，可能存在措辞不够地道的情况。所有界面功能、占位符与错误提示均经过自动化校验，可正常使用。繁體中文按术语表进行了人工校正。我们会在后续版本持续改进翻译质量。

**同时显式标注的不一致（Q11 裁决，直接引用）**：

> Finder 服务菜单项名称由 macOS 依据 Service 自身 bundle 渲染，跟随**系统**语言；App 内手动切换语言**不影响**该菜单名。v1.1 接受此不一致，计划在 P1-09 统一。

### 其他须写入发版说明的已知限制（架构裁决 A，主理人定稿）

**逐字引用，勿改写**：

> APFS 克隆快路径在 fd 通道下不生效，同卷复制走全量拷贝。

配套口径（同样须出现在发版说明或版本说明中）：

| 项 | 结论 |
|---|---|
| v1.1 范围 | **不动冻结区**（复制引擎 / 校验 / 断点续传 / 任务队列 / 报告数据模型）；APFS 克隆 fd 通道分流**单独立项 v1.2** |
| `copyWithClone()` 返回 `false` | **诚实行为，非 bug**；不得为「让快路径生效」而改动冻结区或伪造返回值 |
| 对 P1-01 验收的影响 | P1-01「同卷复制 100 GiB 逻辑文件 ≤ 5 s」仅适用于**克隆可用路径**；fd 通道下按上述口径走全量拷贝，不以秒拷验收。详见 `docs/PRD.md` 附录 C |
| 与本节其他口径的关系 | 与 Q5 机翻限制、Q11 菜单不一致并列，同属「已知限制」，**均须随交付物呈现**，不得只披露其中一条 |

---

## 十、修订记录

> **关于行数**：本表中的行数（870 / 1048 / 1113）都是**当时对齐版本的历史快照**，用于追溯，不代表当前值，也不需要与现状同步。头部与页脚已改为按「架构版本号 + 任务编号」定位，不再硬编码行数；测试基线同理，以 `bash test.sh` 实际输出为准。

| 版本 | 日期 | 变更 | 触发来源 |
|---|---|---|---|
| v1.0 | 2026-11-08 | 初版：八语言清单、方案 C、P0×15 / P1×10 / P2×4、12 组待确认问题 | team-lead 增量需求 |
| **v1.1** | 2026-11-08 | ① **Q2b 关闭**：架构实跑 SwiftUI 探针零 error + 双保险路径，降级不启用，P0-05 不改写；② §3.4 兜底表新增「是否系统自动提供」列，明确空串与占位符**非免费**；③ §3.5 新增 3 条补充实测与第 3/4 条实现约束；④ P0-05 补④天然满足说明 + ⑤菜单双保险，P0-06 补②空串 + ⑤防崩溃，P0-08 补⑤迁移时序，P0-10 改为双层防护；⑤ **新增 P0-16**（恢复默认不重置语言）；⑥ Q5 标记「架构不介入，仍待主理人裁决」，Q7 升级为硬验收；⑦ §6 C2/C4/C5/C6/C7 补实现要求，新增 C14（日志快照不改）与绝对路径模块缓存环境坑；⑧ §8 验收清单同步 | software-architect 的 `docs/ARCHITECTURE-I18N.md`（870 行）及三项补充探针；产品侧已独立复现空串与 SIGSEGV |
| **v1.2** | 2026-11-08 | ① **Q5 裁决**：无母语审校资源，机翻水平为**已知限制**，P1-04 保持 P1；新增 §9「已知限制与对外口径」含可直接引用的交付说明原文与 Q11 标注；② **Q2b 追加裁决**：降级路径整行作废，兜底指定 `NSApp.mainMenu`（`MenuBarLocalizer`、`@MainActor`、幂等），`@Published` 归位为主路径；③ **Q10 裁决**：八语清单锁定、`es` 保留不换 `pt-BR`，§2 备选表述作废；④ **追加硬要求**：翻译数据与代码分离（8 份 `translations/<lang>.json` → `--sync` / `--merge-translations` / `--check-languages` 三子命令 → 单一 xcstrings → 8 份 strings；校验含 `zh-Hant` 简体字扫描）；⑤ **新增 P0-17 / P0-18**（P0 由 16 → 18 条）；⑥ §3.5 / §6（C1、C6、C9、C11、新增 C15/C16）/ §8 同步；⑦ §7 标题改为「已全部裁决，无开放项」 | 主理人对 PRD §7 全部 12 问 + Q2b + Q5 的裁决；software-architect `docs/ARCHITECTURE-I18N.md` v1.2（1048 行）§0 / §9 / §11 |
| **v1.12（定稿）** | 2026-11-08 | ① **记录第 ⑤ 项独立承重证据**：QA 在临时副本 `proqa/.check5`（已清理）只篡改 `baseline-placeholders.json` 冻结签名、译文与 180 条快照均不动 → `EXIT=1` 且失败项恰好 1 条，证明「基准占位符签名未漂移」不是被 180 条逐字比对顺带覆盖；清理后真实文件未动、真实 `--check-languages` `EXIT=0`；② **记录已知文案滞后**：`sync_catalog.py:252-253` 成功打印仍只列四项，docstring 与实现均为五项，**校验行为正常**，§2 与 §8 均加注「不得据此判第 ⑤ 项未生效」；③ 主 PRD 附录 C.1.1 新增 **v1.2 纯文案待办 ⑤**（成功输出行补齐第 5 项），明确「非功能、不动冻结区、v1.1 代码冻结不改脚本」，并区分「v1.2 功能待办只有 AD-13 分流」；④ QA 确认 v1.10 五项修正正确、验收命令一行未改、v1.4 锚定有效、`docs/PRD.md:423` 合规范例已撤零命中。**验收断言、门槛数值、脚本、代码全部零变化** | software-qa-engineer 的独立负向核验消息（第 ⑤ 项隔离验证 + 成功打印行纯文案不一致）；产品侧采纳「不改脚本、归 v1.2 一行打印文案」的判断 |
| **v1.11（定稿）** | 2026-11-08 | ① **依 QA 自查更正，撤销「合规范例」**：删除主 PRD 附录 B.2 第 4 条末句「QA 第 2 轮回归即按此口径执行…排除环境争用后安静串行重跑」——QA 复查三轮原始日志证明该次重跑**无任何可指认前提违反**（失败轮 `getloadavg` 6.19 反为三轮最低、通过轮 6.35/7.03 更高；三轮 `modified during the build` 与 `error:`/`warning:` 均 0、`build.sh` 与 `test.sh` 相隔 45 秒无重叠；失败轮 8 次采样极差仅 0.034 呈整体平移而非争用抖动），「排除环境争用」属结论性措辞而非证据；② **形式化示例替代真实执行**：改为「合规＝报告写明并发 `build.sh` PID/时间戳重叠后重跑一整轮」「违规＝仅以负载略高/再跑一次说不定就过为由重跑 → 直接适用第 5 条终局判定」；③ **「可指认」收紧为可观测事件**（QA 方法论建议，采纳）：✅ 并发进程 PID/时间戳重叠、`modified during the build`、非 Release、采样明确双峰长尾；❌ 「负载高」「感觉抢 CPU」「排除环境争用」等推测与结论性措辞，`getloadavg()` 数值本身不足以指认；并写明**禁止事后补前提**、**本条不回溯判定历史执行**、**不以任何单次重跑作为合规范例**；④ §10 v1.9 行的「合规范例」记录加删除线并注「v1.11 撤销」；⑤ **最终路由 NoOne 的理由不以该次重跑为依据**，而以附录 B.1「算法正确性以官方 35/35 test vectors 为唯一判据」为准（QA 确认）。**验收断言、门槛数值、脚本、代码全部零变化** | software-qa-engineer 两条自查更正消息（三轮原始日志复查 + 最小删改方案）；产品侧采纳其「不让站不住脚的例子变成先例」的 QA 立场，未为留痕事后补前提 |
| **v1.10（定稿）** | 2026-11-08 | ① **修正实质不一致**：`--check-languages` 实为**五项硬校验**（`sync_catalog.py:10-11,159-254`），此前 PRD 全写「四项」。§2 流水线说明、§2 清单、P0-17 ④、C9、§8 打勾项及 `docs/PRD.md` 附录 B.3 约束**全部改为五项**，并补第 ⑤ 项「**基准占位符签名未漂移**」（`docs/i18n/baseline-placeholders.json`，防中文基准自身被改坏导致运行期 `FormatSignature` 比对基准漂移）；中文基准快照 180 条逐字比对明确为**并列的独立步骤、不计入五项**；`ensureHealthyTranslations()` 重建译文后五项 + 快照比对仍逐条全跑；② **§8 两条独立证据引用补具体文件**：`proqa/qa_package.log` / `qa_package2.log` / `qa_checklang.log` / `qa_build_final.log` / `qa_final_confirm.log` / `qa_closeout.log`（均已核实存在），仍不写具体测量数字；`proqa/i18n_ab_matrix.md` 标注为附录 B.2 第 4 条「可复跑 + 留痕」的样板证据；③ **主 PRD 附录 C 新增 C.1.1**：明确架构 §4.3.1 v1.2 待办第 ③④ 项（clone 路径绕过限速、≥4 MiB 进度字节重复累加）**已在 v1.1 修复并划掉、不属 v1.2 待办**，PRD 从未列为 Known Issues 故无需归档；v1.2 实际只剩 AD-13 路径长度分流 + 第 1 项复核移除，**防止立项时重复施工**。验收断言与门槛数值零变化 | software-engineer 回执（五项硬校验 / 两个 v1.1 已修缺陷 / 181 全绿）与 software-qa-engineer 的 P0-13/14 独立实测数据及证据文件路径；产品侧直接核对 `sync_catalog.py` 与 `ARCHITECTURE.md:1113-1124` 后落地，未重复跑测试 |
| **v1.9（定稿）** | 2026-11-08 | ① **§8 补两条独立证据引用**：P0-13 ④（`.app` 体积增量 ≤ 200 KiB + `codesign --verify`）与 P0-14 ④（`package_app.sh` 连续两次执行后 8 个 `.lproj` 数不变、无残留 `.xcstrings`、每份条目数一致、`plutil -lint` 全过）均标注「见 QA 第 2 轮回归报告」，**未写具体测量数字**；② 主 PRD 附录 B.2 第 4 条补 **「重跑的前提违反必须可指认且留痕」**——验收报告须写明具体违反哪项前提（**v1.11 已收紧为可观测事件**：并发 `build.sh` PID/时间戳重叠、`modified during the build`、非 Release、采样明确双峰长尾；「负载高」等推测不可指认）及修正动作；无法指认、仅以「再跑一次说不定就过」为由的重跑一律禁止，直接适用第 5 条终局判定，堵住「再跑几次总能过」的漏洞；③ ~~记录 QA 第 2 轮按此口径执行（首次仅吞吐项失败 → 排除环境争用后安静串行重跑 …）~~ **该「合规范例」已于 v1.11 依 QA 自查更正撤销**：三轮原始日志显示失败轮 `getloadavg` 最低、无并发构建痕迹、8 次采样极差仅 0.034 呈整体平移，**无任何可指认前提违反**，不应作先例。**验收断言与门槛数值零变化** | software-qa-engineer 第 2 轮回归报告（v1.7 与验收命令无措辞冲突、命令一行未改）；产品侧据此补文档，未新增需求、未改脚本。**v1.11 更正依据：QA 对三轮原始日志的复查** |
| **v1.8（定稿）** | 2026-11-08 | ① **§8 ③ A6 覆盖方式细化**（依工程师回执）：明确由 **QA #13 的 `proqa/i18n_acceptance.sh` A6 case `--case=double_hijack`** 覆盖、**已接入 `test.sh` 第 ⑥ 步**、A4（产品 `Localization.format` 返回「共 5 项」EXIT=0）与 A6（前置条件成立）互补、**`MacCopy/Tests/` 内无独立双劫持单测编号、不要求补、不得追加测试代码**；② **主 PRD 附录 B 测量次数由 5 次统一为 8 次**（主理人最终口径，与工程师「高优先级专用线程 + 8 次取最优 + 记录全部采样值」实现一致，10 次连续运行零失败），并新增 **B.3 测量实现加固记录**（`measureBLAKE3` 同步非 async、`UInt(bitPattern:)` 传标量、`ensureHealthyTranslations()` + `.atomic` 立即恢复）与口径修订记录；**B.1/B.2 其余裁决全部不变、验收门槛数值零变化** | team-lead 与 software-engineer 两条最终口径消息；产品侧按裁决落地，未新增需求、未改动任何验收断言 |
| **v1.7（定稿）** | 2026-11-08 | ① **Q5 最终关闭确认**：无母语审校资源、机翻初稿 + 构建期自动校验 + 每语种抽查 20 条；P1-04 保持 P1、v1.1 不执行且不得声称已审校；§9 原文照用；**P0-18 禁用词扫描范围维持现状**（只扫三个禁用短语，不含「母语审校」四字，避免与 §7/§9 描述「无该资源」及 P1 计划自相矛盾）——主理人明确「不需要改成范围化规则」；② **§8 ③ 与 P0-10 ⑦⑧ 覆盖方式定稿**：由 `proqa/i18n_acceptance.sh --case=double_hijack` 覆盖（A6 PASS，整套 9/9），**不要求 `src/` 内再有同名单测，不得为此追加测试代码**；P0-10 ⑦「须有单测」措辞改为「须有用例」以消除歧义；③ **发版说明新增架构裁决 A**（§9 新增「其他须写入发版说明的已知限制」，逐字引用「APFS 克隆快路径在 fd 通道下不生效，同卷复制走全量拷贝」；v1.1 不动冻结区、分流单独立项 v1.2、`copyWithClone()` 返回 false 为诚实行为非 bug、P1-01 秒拷验收仅适用克隆可用路径）；详细范围裁决见 `docs/PRD.md` 附录 C；④ 主 PRD 附录 B 追加**固定 5 次上限**（全部低于门槛不再重跑、直接判真实回归；**该次数已于 v1.8 对齐为 8 次，见上一行，此处按历史记录原样保留**）；⑤ 全文按「版本号 + 条款/任务编号」定位，不写行数与测试数 | team-lead 两条最终裁决消息；产品侧按裁决逐条落地，未新增需求、未改动验收门槛数值 |
| **v1.6** | 2026-11-08 | ① **P0-10 新增 ⑧ / QA A6 前置断言**：验收前须单独探测并断言 `base` 与 `candidate` 逐字同为 `TOTAL %@ ITEMS`，否则注入失效会让防崩溃用例静默平凡通过（第三类假通过）；② §3.4「验收含义」由 3 条增至 **4 条**（补真删 `ko.lproj` 硬校验、zh-Hans 反证、A6 前置）；③ §8 叠加条件打勾项补 ③④ 两条，并把 A/B 矩阵改为**可复跑可归档**（`bash proqa/i18n_ab_matrix.sh` → `RESULT\|PASS` / EXIT=0 → 归档 `proqa/i18n_ab_matrix.md`）；④ 主 PRD 新增**附录 B** 定义吞吐类验收测量口径（Q3 硬指标 ≥1.0 GB/s **不放宽**）。**QA 的 `proqa/i18n_acceptance.sh` 已等价实现 A1~A6 / B1~B2 / D1 共 9 条硬断言，脚本锚定 v1.4 仍然有效、无需改动** | software-qa-engineer 的真实 `.app` 验收实测与 A6 双劫持前置断言、可复现 A/B 矩阵脚本；产品侧直接采信其输出，未重复跑探针 |
| **v1.5** | 2026-11-08 | ① **测试基线彻底去数字**：头部、P0-12、C13、§8、§9 共 5 处的「当前 123/123」「当前 123 个」全部改为「**以 `bash test.sh` 实际输出为准，不写具体数字**」；历史数字仅留 §10 沿革。② **引擎参数语义归位**：`FileEnumerator.maxDepth` 的澄清不属 i18n 增量，补在 `docs/PRD.md` **附录 A**，§1 范围边界加交叉引用；③ 头部/页脚版本与范围说明同步。**⚠️ 本版为纯文档措辞修订：P0-01~P0-18 的验收条件、§8 打勾项、V-B5/V-B6 叠加条件与 v1.4 完全一致，QA 命令无需改动** | software-engineer 反馈本轮施工后 `bash test.sh` 已达 178/178（v1.0 119 → 中途 123 → 178），并转达 QA-2 的 Q2「maxDepth 语义未定义」；产品侧核实 `FileEnumerator.swift:100/163` 后按实际行为写入 PRD.md 附录 A，未重复跑测试 |
| **v1.4** | 2026-11-08 | ① **采纳 QA 的 V-B5 / V-B6 新证据**：基准被劫持会让「构建期校验 + 运行期守卫」**双层防护整体失效并 SIGSEGV**（`base`/`candidate` 同为 `TOTAL %@ ITEMS` → `FormatSignature` 假相等 → 守卫不触发 → exit 139），不再只是「退回错语言」；`guard let bundle else { return base }` 分支在整份 `.lproj` 被删时返回被劫持的英文串；② §3.4 v1.3 说明块「三个连锁错误」→ **四个失效点**，补 V-B5 机理与**两重叠加验收条件**（系统语言 = 译文语言、`ko.lproj` 物理删除变体）及 QA A/B 矩阵；③ §3.5 新增 V-B5 / V-B6 两行、**实现约束由五条增至六条**（`bundle == nil` 分支返回 `baseline()`、`FormatSignature` 不得仅凭两边签名相等放过）；④ **P0-06 ③ 补 V-B6 具体路径、新增 ⑦ 叠加条件与 ⑧ ko 变体；P0-10 新增 ⑦ 双劫持单测**；⑤ §8 新增「v1.4 两条叠加条件」与「QA A/B 矩阵对照」打勾项 | software-qa-engineer 用真实 `.app`（8 个 `.lproj`、`CFBundleDevelopmentRegion=en`、注入空串/坏占位符、`-AppleLanguages "(en)"`）复现 V-B5/V-B6 及 A/B 矩阵；software-architect 已落地架构 §2.2 / §3.3 / §0 风险表 / AD-I13 / AD-I14 / T-I02 / T-I05，产品侧直接采信、未重复跑探针 |
| **v1.3** | 2026-11-08 | ① 同步架构 V-B 修正（当时对齐 1113 行版本）；② **测试基线去硬编码**：119 → 「以施工时 `bash test.sh` 实际输出为准（当前 **123/123** 全绿）」，涉及头部、P0-12、C13、§8、§9 共 5 处；③ **采纳 V-B1~V-B4 新发现**：中文基准必须绕开 `Bundle.main`——§3.4 兜底表新增「中文基准取法」行 + v1.3 说明块（含三处连锁失效分析）、§3.5 新增补充行与**第 5 条实现约束**、C2 要求先实现 `Localization.baseline(_:_:)`（不存在的 `table:` 名）；④ **P0-06 新增 ⑥、P0-10 新增 ⑥**：兜底测试必须在 `Bundle.main` 含目标语言资源的环境下执行并断言回退为中文，基准不随系统语言漂移；⑤ §8 新增「中文基准真实性专项」打勾项；⑥ **术语消歧**：§2 新增对照表，区分「冻结基准快照 JSON（T-I01 数据）」与「运行期 `Localization.baseline()` 函数（T-I02 代码）」两个同名概念；⑦ **对齐文档行数去硬编码**：头部/页脚改为「架构 v1.2 + 任务编号 T-I01~T-I05」定位，不再写行数（架构补实测论证会持续变行数） | software-architect `docs/ARCHITECTURE-I18N.md` v1.2（当时 1113 行）§2.2 V-B1~V-B4 / §3.3「中文基准必须绕开 Bundle.main」/ AD-I12 / T-I02 / §8；产品侧已独立复现 V-B1~V-B4（含 HIJACKED 注入场景），并补记一处精确化：`bundle: nil` 在裸 CLI 进程返回中文、结果环境相关，故更不可依赖 |

---

*增量 PRD v1.12（定稿）｜ MacCopy v1.1 I18N ｜ 2026-11-08 ｜ 基准：docs/PRD.md（附录 A / B / C）｜ 对齐：docs/ARCHITECTURE-I18N.md v1.2（T-I01~T-I05，按版本号定位）｜ §7 已全部裁决，无开放项*
