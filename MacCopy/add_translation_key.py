#!/usr/bin/env python3
"""向 8 份 translations/<lang>.json 补一个新 key，保持占位符一致。

用法：python3 add_translation_key.py <key> <lang1>:<value1> <lang2>:<value2> ...
未指定的语言回落英文。
"""
import json
import sys
from pathlib import Path

TRANS = Path(__file__).resolve().parent / "src/MacCopyApp/Localization/translations"
LANGS = ["zh-Hans", "en", "zh-Hant", "ja", "ko", "fr", "de", "es"]


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    key = sys.argv[1]
    supplied = {}
    for item in sys.argv[2:]:
        lang, _, value = item.partition(":")
        supplied[lang] = value

    for lang in LANGS:
        path = TRANS / f"{lang}.json"
        data = json.loads(path.read_text(encoding="utf-8"))
        value = supplied.get(lang) or supplied.get("en")
        if value is None:
            print(f"❌ 缺少 {lang} 的译文")
            return 1
        data[key] = value
        ordered = dict(sorted(data.items()))
        path.write_text(
            json.dumps(ordered, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        print(f"  ✓ {lang}: {value}")
    print(f"✅ 已写入 {key} 到 {len(LANGS)} 份翻译")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
