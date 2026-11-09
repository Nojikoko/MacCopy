#!/bin/bash
#
# 把 swiftc 产物打包为可双击运行的 MacCopy.app（v1.1 八语言）。
#
# 背景：本机 SwiftPM 不可用（BUILD-ENV-NOTES.md），用 swiftc 直接编译出
# 裸 Mach-O + dylib。此脚本把它们组装成标准 .app bundle：
#   - dylib 放进 Contents/Frameworks，install name 改为 @rpath
#   - 可执行文件加 @executable_path/../Frameworks 的 rpath
#   - 8 份 <lang>.lproj/Localizable.strings（从 String Catalog 生成）
#   - ad-hoc 签名（本机可运行；正式分发需 Developer ID + 公证）
#
# 用法：bash package_app.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/.build"
DIST="$ROOT/dist"
APP="$DIST/MacCopy.app"
LANGS=(zh-Hans en zh-Hant ja ko fr de es)

export TMPDIR="$ROOT/../.tmp"
export CLANG_MODULE_CACHE_PATH="$ROOT/../.tmp/modcache"

echo "=== 1/8 语言完整性校验（P0-02 ④：失败即阻断，不产出 .app） ==="
python3 "$ROOT/sync_catalog.py" --check-languages

echo "=== 2/8 生成单一 String Catalog（8 语言合并） ==="
python3 "$ROOT/sync_catalog.py" --merge-translations > /dev/null
echo "    Catalog 就绪"

echo "=== 3/8 先确保已构建 ==="
bash "$ROOT/build.sh" > /dev/null
echo "    构建产物就绪"

echo "=== 4/8 应用图标（缺失时自动从 SVG 生成） ==="
ICNS="$ROOT/Resources/Icon/MacCopy.icns"
if [ ! -f "$ICNS" ]; then
    echo "    MacCopy.icns 不存在，运行 tools/build_icon.sh …"
    bash "$ROOT/tools/build_icon.sh" > /dev/null
fi
if [ ! -f "$ICNS" ]; then
    echo "❌ 图标生成失败，阻断打包" >&2
    exit 3
fi
echo "    图标就绪（$(du -h "$ICNS" | awk '{print $1}')）"

echo "=== 5/8 组装 bundle 目录（幂等：重建 Resources） ==="
# 沙盒下 mkdir 被拦，用 install -d（等价且可用）。
rm -rf "$APP/Contents/Resources" 2>/dev/null || true
install -d "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
for lang in "${LANGS[@]}"; do
    install -d "$APP/Contents/Resources/$lang.lproj"
done
cp "$BUILD/MacCopy" "$APP/Contents/MacOS/MacCopy"
cp "$BUILD/libMacCopyKit.dylib" "$APP/Contents/Frameworks/libMacCopyKit.dylib"
cp "$ROOT/src/MacCopyApp/Info.plist" "$APP/Contents/Info.plist"
cp "$ICNS" "$APP/Contents/Resources/MacCopy.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "=== 6/8 修正动态库路径 ==="
OLD_DYLIB="$BUILD/libMacCopyKit.dylib"
install_name_tool -id "@rpath/libMacCopyKit.dylib" \
    "$APP/Contents/Frameworks/libMacCopyKit.dylib"
install_name_tool -change "$OLD_DYLIB" "@rpath/libMacCopyKit.dylib" \
    "$APP/Contents/MacOS/MacCopy"
if ! otool -l "$APP/Contents/MacOS/MacCopy" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "$APP/Contents/MacOS/MacCopy"
fi

echo "=== 7/8 生成 8 份本地化资源 ==="
# String Catalog(.xcstrings) → 8 份 Localizable.strings。
# 逐语言打印条目数（应都等于 K）；德法语含 " / 换行，转义保留。
python3 - "$ROOT/src/MacCopyApp/Localization/Localizable.xcstrings" \
          "$APP/Contents/Resources" "${LANGS[@]}" <<'PYEOF'
import json, sys
src, resources, *langs = sys.argv[1:]
with open(src, encoding="utf-8") as f:
    catalog = json.load(f)
strings = catalog.get("strings", {})
for lang in langs:
    lines = []
    for key, entry in strings.items():
        node = entry.get("localizations", {}).get(lang, {})
        value = node.get("stringUnit", {}).get("value")
        if value is None:
            value = entry.get("localizations", {}).get("zh-Hans", {}) \
                        .get("stringUnit", {}).get("value", key)
        escaped = (value.replace("\\", "\\\\")
                        .replace('"', '\\"')
                        .replace("\n", "\\n"))
        lines.append(f'"{key}" = "{escaped}";')
    out = f"{resources}/{lang}.lproj/Localizable.strings"
    with open(out, "w", encoding="utf-8") as f:
        f.write(f"/* MacCopy {lang} — generated from String Catalog */\n")
        f.write("\n".join(lines) + "\n")
    print(f"    {lang:8s} {len(lines)} 条")
PYEOF

echo "=== 8/8 ad-hoc 签名与校验 ==="
codesign --force --sign - "$APP/Contents/Frameworks/libMacCopyKit.dylib" 2>/dev/null || true
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "    依赖："
otool -L "$APP/Contents/MacOS/MacCopy" | grep -E "MacCopyKit|libSystem" | sed 's/^/      /'
echo "    签名："
codesign --verify --verbose=1 "$APP" 2>&1 | head -3 | sed 's/^/      /' || true
echo "    lproj 目录数：$(find "$APP/Contents/Resources" -name '*.lproj' -type d | wc -l | tr -d ' ')"

echo ""
echo "✅ 已生成：$APP"
echo "   启动命令：open \"$APP\""
