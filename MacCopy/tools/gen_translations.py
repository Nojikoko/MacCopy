#!/usr/bin/env python3
"""生成 8 份 translations/<lang>.json（i18n v1.1 / T-I01）。

数据源：
  - docs/i18n/baseline-v1.0-zh-Hans.json —— 主理人冻结的 180 条中文基准（逐字不变）
  - tools/i18n_data_part{1,2,3,4}.tsv —— 逐 key 的 7 语机翻初稿
  - NEW_KEYS —— 语言 UI 新增 key 的中文基准

约束：
  - 译文占位符数量/类型必须与中文基准一致（否则运行期 String(format:) 会 SIGSEGV）
  - 不联网、不引入第三方依赖
  - zh-Hans.json 的 180 条必须与冻结快照逐字节一致
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASELINE = ROOT.parent / "docs" / "i18n" / "baseline-v1.0-zh-Hans.json"
OUT = ROOT / "src" / "MacCopyApp" / "Localization" / "translations"
DATA_PARTS = [ROOT / "tools" / f"i18n_data_part{i}.tsv" for i in range(1, 5)]

LANGS = ["zh-Hans", "en", "zh-Hant", "ja", "ko", "fr", "de", "es"]

# 占位符正则：与 Support/FormatSignature.swift 及 --check-languages 完全一致。
PLACEHOLDER = re.compile(
    r"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|L|z|t|j)?[@%dDuUxXoOfFeEgGcCsSaAp]"
)
def sig(s: str) -> list[str]:
    """占位符类型签名（忽略位置/宽度修饰，只保留类型字符）。"""
    return [m[-1] for m in PLACEHOLDER.findall(s)]

# 语言 UI 新增 key（架构 T-I01 §3 列出的 11 条）。全部无占位符，
# 「当前生效语言」等动态值由 SwiftUI 单独 Text 渲染，避免新增格式串。
NEW_KEYS: dict[str, str] = {
    "ui.settings.language": "界面语言",
    "ui.settings.language.followSystem": "跟随系统语言",
    "ui.settings.language.picker": "选择语言",
    "ui.settings.language.current": "当前生效语言",
    "ui.settings.language.instantHint": "切换后立即生效，无需重启。",
    "ui.settings.language.restoreFollow": "恢复跟随系统",
    "ui.settings.language.migratedHint": "已从旧版本升级，界面语言保持简体中文。",
    "ui.settings.language.unsupportedHint": "当前系统语言暂未支持，已显示 English。",
    "ui.settings.language.sectionHint": "此设置只影响界面文字，不影响文件内容与校验结果。",
    "ui.settings.language.followSource": "跟随系统语言",
    "ui.settings.language.manualHint": "手动选择",
    "ui.settings.maintenance": "维护",
    # BUG-004 修复：新增文案必须进**数据源**（本字典 + TSV），
    # 否则 `ensureHealthyTranslations()` 的自愈重建会把它静默丢弃 ——
    # 表现是「加了 key，跑一次 test.sh 就没了」。
    "ui.log.sourceMissing": "以下源不存在，已忽略：%@",
}


def load_rows() -> dict[str, list[str]]:
    """读取 4 份 TSV，返回 {key: [en, zh-Hant, ja, ko, fr, de, es]}。"""
    rows: dict[str, list[str]] = {}
    for part in DATA_PARTS:
        if not part.exists():
            print(f"❌ 缺少数据分片：{part}", file=sys.stderr)
            sys.exit(2)
        for lineno, raw in enumerate(
            part.read_text(encoding="utf-8-sig").splitlines(), 1
        ):
            if not raw.strip() or raw.lstrip().startswith("#"):
                continue
            cols = raw.split("\t")
            if len(cols) != 8:
                print(f"❌ {part.name}:{lineno} 列数={len(cols)}，应为 8", file=sys.stderr)
                sys.exit(2)
            key = cols[0]
            if key in rows:
                print(f"❌ 重复 key：{key}", file=sys.stderr)
                sys.exit(2)
            rows[key] = cols[1:]
    return rows


def main() -> int:
    frozen = json.loads(BASELINE.read_text(encoding="utf-8"))["strings"]
    if len(frozen) != 180:
        print(f"❌ 冻结快照应为 180 条，实际 {len(frozen)}", file=sys.stderr)
        return 2

    rows = load_rows()
    zh_hans = dict(frozen)
    zh_hans.update(NEW_KEYS)
    K = len(zh_hans)
    N = len(NEW_KEYS)
    print(f"K = {K}（180 冻结 + {N} 新增）")

    missing = sorted(set(zh_hans) - set(rows))
    extra = sorted(set(rows) - set(zh_hans))
    if missing or extra:
        print(f"❌ 译文表缺 {len(missing)} 条 / 多 {len(extra)} 条", file=sys.stderr)
        for k in missing[:10]:
            print(f"   缺：{k}", file=sys.stderr)
        for k in extra[:10]:
            print(f"   多：{k}", file=sys.stderr)
        return 2

    # 占位符一致性（构建期第一道防线）。
    errors = []
    for key, base in zh_hans.items():
        expected = sig(base)
        for i, lang in enumerate(LANGS[1:]):
            actual = sig(rows[key][i])
            if actual != expected:
                errors.append((lang, key, expected, actual))
    if errors:
        print(f"❌ 占位符不一致 {len(errors)} 处：", file=sys.stderr)
        for lang, key, exp, act in errors[:20]:
            print(f"   {lang} / {key} / 期望 {exp} / 实际 {act}", file=sys.stderr)
        return 2

    OUT.mkdir(parents=True, exist_ok=True)
    # zh-Hans：冻结 180 条 + 新增 N 条
    (OUT / "zh-Hans.json").write_text(
        json.dumps(zh_hans, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    # 其余 7 语
    for i, lang in enumerate(LANGS[1:]):
        data = {k: rows[k][i] for k in zh_hans}
        (OUT / f"{lang}.json").write_text(
            json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

    print(f"✅ 已生成 8 份 JSON，各 {K} 条 → {OUT.relative_to(ROOT)}")
    for lang in LANGS:
        p = OUT / f"{lang}.json"
        d = json.loads(p.read_text(encoding="utf-8"))
        print(f"   {p.name:16s} {len(d)} 条")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
