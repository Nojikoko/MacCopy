#!/usr/bin/env python3
"""String Catalog 同步 / 合并 / 校验（MacCopy v1.1 / i18n）。

三个子命令：
    --sync                 扫描源码 Localization.string/format 调用 → 补新 key 到
                           8 份 translations/*.json（值为空，打印待译清单），
                           **不覆盖已有译文**。
    --merge-translations   读 8 份 translations/*.json → 生成单一
                           Localization/Localizable.xcstrings（每 key 8 个 localizations）。
    --check-languages      五项硬校验（零缺失 / 占位符数量与类型 / 空串 /
                           zh-Hant 简体字扫描 / 基准占位符签名未漂移）
                           + 中文基准快照逐字比对；失败非零退出。
    --check                旧语义保留：只检查源码 key 是否都在 Catalog 里（不写文件）。

默认（无参数）= --sync + --merge-translations。
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CATALOG = ROOT / "src" / "MacCopyApp" / "Localization" / "Localizable.xcstrings"
TRANSLATIONS = ROOT / "src" / "MacCopyApp" / "Localization" / "translations"
SOURCE_DIRS = [ROOT / "src" / "MacCopyApp", ROOT / "src" / "MacCopyKit"]
BASELINE = ROOT.parent / "docs" / "i18n" / "baseline-v1.0-zh-Hans.json"
BASELINE_PLACEHOLDERS = ROOT.parent / "docs" / "i18n" / "baseline-placeholders.json"
SIMPLIFIED_CHARS = ROOT.parent / "docs" / "i18n" / "simplified-chars.txt"

LANGS = ["zh-Hans", "en", "zh-Hant", "ja", "ko", "fr", "de", "es"]

# 与 Support/FormatSignature.swift、tools/gen_translations.py 完全一致的占位符正则。
PLACEHOLDER = re.compile(
    r"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|L|z|t|j)?[@%dDuUxXoOfFeEgGcCsSaAp]"
)
def sig(s: str) -> list[str]:
    """占位符类型签名（忽略位置/宽度修饰，只保留类型字符）。"""
    return [m[-1] for m in PLACEHOLDER.findall(s)]

# 匹配 Localization.string("key", default: "中文") / format(...)
PATTERN = re.compile(
    r'Localization\.(?:string|format)\(\s*"([A-Za-z0-9_.\-]+)"\s*,\s*default:\s*"((?:[^"\\]|\\.)*)"',
    re.MULTILINE,
)


def collect_source_keys() -> dict[str, str]:
    """扫描 Swift 源码，返回 {key: 中文 defaultValue}。"""
    found: dict[str, str] = {}
    for directory in SOURCE_DIRS:
        for path in directory.rglob("*.swift"):
            text = path.read_text(encoding="utf-8")
            for key, value in PATTERN.findall(text):
                value = (value.replace(r'\"', '"')
                              .replace(r"\n", "\n")
                              .replace(r"\\", "\\"))
                if key in found and found[key] != value:
                    print(f"⚠️  key 冲突：{key} -> {found[key]!r} vs {value!r}",
                          file=sys.stderr)
                found[key] = value
    return found


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8-sig"))


def write_json(path: Path, data: dict) -> None:
    path.write_text(
        json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


# ---------------------------------------------------------------- --sync

def cmd_sync() -> int:
    found = collect_source_keys()
    print(f"源码中发现 {len(found)} 个 Localization key。")
    pending: dict[str, list[str]] = {}
    for lang in LANGS:
        path = TRANSLATIONS / f"{lang}.json"
        data = read_json(path) if path.exists() else {}
        added = []
        for key, zh in found.items():
            if key not in data:
                if lang == "zh-Hans":
                    data[key] = zh
                else:
                    data[key] = ""       # 空值 → --check-languages 会拦截
                    added.append(key)
        write_json(path, data)
        if added:
            pending[lang] = added

    if pending:
        print(f"⚠️  新增 key 需补译文（共 {len(next(iter(pending.values())))} 个）：")
        for lang, keys in pending.items():
            print(f"   {lang}: {len(keys)} 条待译")
        for key in next(iter(pending.values()))[:20]:
            print(f"     - {key}: {found[key]}")
    else:
        print("✅ 无新增 key，8 份译文齐全。")
    return 0


# -------------------------------------------------- --merge-translations

def cmd_merge() -> int:
    catalog: dict = {
        "sourceLanguage": "zh-Hans",
        "version": "1.0",
        "strings": {},
    }
    per_lang: dict[str, dict[str, str]] = {}
    for lang in LANGS:
        path = TRANSLATIONS / f"{lang}.json"
        if not path.exists():
            print(f"❌ 缺少译文文件：{path}", file=sys.stderr)
            return 1
        per_lang[lang] = read_json(path)

    keys = sorted(per_lang["zh-Hans"].keys())
    for key in keys:
        localizations = {}
        for lang in LANGS:
            value = per_lang[lang].get(key, "")
            localizations[lang] = {
                "stringUnit": {"state": "translated", "value": value}
            }
        catalog["strings"][key] = {
            "comment": "v1.1 八语言（translations/*.json 为唯一译文事实源）",
            "localizations": localizations,
        }

    CATALOG.parent.mkdir(parents=True, exist_ok=True)
    CATALOG.write_text(
        json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(f"✅ 已生成 {CATALOG.relative_to(ROOT)}：{len(keys)} key × {len(LANGS)} 语言")
    return 0


# ------------------------------------------------------ --check-languages

def load_simplified_chars() -> set[str]:
    chars: set[str] = set()
    for line in SIMPLIFIED_CHARS.read_text(encoding="utf-8-sig").splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        chars.update(s)
    return chars


def cmd_check_languages() -> int:
    errors: list[str] = []
    per_lang: dict[str, dict[str, str]] = {}

    # ① 中文基准快照比对（P0-03）：180 条逐字不变。
    if not BASELINE.exists():
        errors.append(f"冻结快照不存在：{BASELINE}")
        frozen = {}
    else:
        frozen = read_json(BASELINE).get("strings", {})
        if len(frozen) != 180:
            errors.append(f"冻结快照应为 180 条，实际 {len(frozen)}")

    for lang in LANGS:
        path = TRANSLATIONS / f"{lang}.json"
        if not path.exists():
            errors.append(f"[缺失] 语言 / {lang} / 整份译文文件不存在：{path.name}")
            per_lang[lang] = {}
            continue
        per_lang[lang] = read_json(path)

    zh = per_lang.get("zh-Hans", {})
    K = len(zh)
    if K == 0:
        errors.append("[基准] zh-Hans.json 为空，无法校验")
        print("\n".join(errors), file=sys.stderr)
        return 1

    for key, value in frozen.items():
        if key not in zh:
            errors.append(f"[基准] zh-Hans / {key} / 冻结 key 丢失")
        elif zh[key] != value:
            errors.append(
                f"[基准] zh-Hans / {key} / 中文基准被改动：期望 {value!r} 实际 {zh[key]!r}"
            )

    # 第五道：基准占位符签名快照（架构师建议 / P0-10）。
    # 防止「中文基准自身被改坏」导致运行期 FormatSignature 比对基准漂移。
    if BASELINE_PLACEHOLDERS.exists():
        snap = read_json(BASELINE_PLACEHOLDERS).get("placeholders", {})
        for key, expected in snap.items():
            actual = PLACEHOLDER.findall(zh.get(key, ""))
            if actual != expected:
                errors.append(
                    f"[基准占位符] zh-Hans / {key} / 期望 {expected} 实际 {actual}"
                )
        for key, value in zh.items():
            if key not in snap and PLACEHOLDER.findall(value):
                errors.append(
                    f"[基准占位符] zh-Hans / {key} / 新增了未登记的占位符"
                )
    else:
        errors.append("[基准占位符] 冻结快照不存在（应先导出 baseline-placeholders.json）")

    for lang in LANGS:
        data = per_lang.get(lang, {})
        missing = sorted(set(zh) - set(data))
        extra = sorted(set(data) - set(zh))
        for key in missing:
            errors.append(f"[缺失] {lang} / {key} / 缺少译文")
        for key in extra:
            errors.append(f"[多余] {lang} / {key} / 基准中不存在的 key")
        simplified = load_simplified_chars() if lang == "zh-Hant" else set()
        for key, base in zh.items():
            if key not in data:
                continue
            value = data[key]
            if not isinstance(value, str) or not value.strip():
                errors.append(f"[空串] {lang} / {key} / 译文为空或全空白")
                continue
            expected, actual = sig(base), sig(value)
            if expected != actual:
                errors.append(
                    f"[占位符] {lang} / {key} / 期望 {expected} 实际 {actual}"
                )
            if simplified:
                hit = sorted(set(value) & simplified)
                if hit:
                    errors.append(
                        f"[简体字] zh-Hant / {key} / 命中 {''.join(hit)}"
                    )

    if errors:
        print(f"❌ --check-languages 失败（{len(errors)} 项）：", file=sys.stderr)
        for e in errors[:60]:
            print(f"   {e}", file=sys.stderr)
        if len(errors) > 60:
            print(f"   ... 还有 {len(errors) - 60} 项", file=sys.stderr)
        return 1

    print(f"✅ --check-languages 通过：{len(LANGS)} 语言 × {K} key（180 冻结 + {K - 180} 新增）")
    for lang in LANGS:
        print(f"   {lang:8s} {len(per_lang[lang])} 条")
    print("   逐语种零缺失 / 占位符数量与类型一致 / 无空串 / zh-Hant 简体字 0 命中")
    print("   中文基准快照 180 条逐字一致")
    return 0


# ---------------------------------------------------------------- --check

def cmd_check() -> int:
    if not CATALOG.exists():
        print(f"❌ Catalog 不存在：{CATALOG}", file=sys.stderr)
        return 1
    strings = read_json(CATALOG).get("strings", {})
    found = collect_source_keys()
    missing = [k for k in found if k not in strings]
    print(f"源码 {len(found)} 个 key；Catalog {len(strings)} 个；缺失 {len(missing)} 个。")
    for key in missing[:20]:
        print(f"   - {key}: {found[key]}")
    return 1 if missing else 0


def main() -> int:
    args = set(sys.argv[1:])
    if "--check-languages" in args:
        return cmd_check_languages()
    if "--check" in args:
        return cmd_check()
    if "--merge-translations" in args:
        return cmd_merge()
    if "--sync" in args:
        return cmd_sync()
    rc = cmd_sync()
    if rc != 0:
        return rc
    return cmd_merge()


if __name__ == "__main__":
    raise SystemExit(main())
