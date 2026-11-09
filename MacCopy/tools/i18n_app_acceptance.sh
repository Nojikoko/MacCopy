#!/bin/bash
#
# 真实 .app 内的 i18n 验收（AD-I12 / V-B1~V-B4 / P0-06 ⑥ / P0-10 ⑥）。
#
# 为什么需要独立 .app：`bash test.sh` 编译的是裸 Mach-O，`Bundle.main` 里
# 没有 .lproj 资源 → 裸 `String(localized:defaultValue:)` 会「看起来正常」，
# 中文基准被系统语言劫持的坑测不出来（QA 证实的假通过）。
# 这里构造一个带 8 个 .lproj 的真实 .app，并用 `-AppleLanguages "(en)"`
# 让系统语言 = 被注入坏译文的语言，两者叠加才能暴露 SIGSEGV。
#
# 用法：bash tools/i18n_app_acceptance.sh
# 退出码：0 = 全部通过；非 0 = 失败（含 exit 139 = 防护失效崩溃）

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$ROOT/tools"
APP="$ROOT/.tmp/I18NAcceptance.app"
BIN="$ROOT/.tmp/I18NAppProbeBin"
BUILD="$ROOT/.build"
SDK="$(xcrun --show-sdk-path)"
TARGET="arm64-apple-macos13.0"

# 模块缓存用**绝对路径**（V-A10：相对路径会撞 Workbuddy/WorkBuddy 大小写冲突）。
MC="$ROOT/.tmp/i18n-app-modcache"
export TMPDIR="$ROOT/.tmp"
export CLANG_MODULE_CACHE_PATH="$MC"
install -d "$ROOT/.tmp" "$MC" "$BUILD"

echo "=== 1/5 编译探针（链接产品 MacCopyKit） ==="
swiftc -O -parse-as-library -swift-version 6 \
    -target "$TARGET" -sdk "$SDK" \
    -module-name I18NAppProbe \
    -module-cache-path "$MC" \
    -I "$BUILD" -L "$BUILD" -lMacCopyKit \
    -Xlinker -rpath -Xlinker "$ROOT/.tmp" \
    "$TOOLS/I18NAppProbe.swift" -o "$BIN"

echo "=== 2/5 组装真实 .app（8 个 .lproj） ==="
rm -rf "$APP" 2>/dev/null || true
install -d "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/I18NAppProbe"
cp "$BUILD/libMacCopyKit.dylib" "$APP/Contents/Frameworks/libMacCopyKit.dylib"
install_name_tool -id "@rpath/libMacCopyKit.dylib" \
    "$APP/Contents/Frameworks/libMacCopyKit.dylib"
install_name_tool -change "$BUILD/libMacCopyKit.dylib" "@rpath/libMacCopyKit.dylib" \
    "$APP/Contents/MacOS/I18NAppProbe"
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP/Contents/MacOS/I18NAppProbe"
install_name_tool -add_rpath "$ROOT/.tmp" "$APP/Contents/MacOS/I18NAppProbe" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>I18NAppProbe</string>
  <key>CFBundleIdentifier</key><string>com.maccopy.i18n.acceptance</string>
  <key>CFBundleName</key><string>I18NAppProbe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>zh-Hans</string><string>en</string><string>zh-Hant</string>
    <string>ja</string><string>ko</string><string>fr</string>
    <string>de</string><string>es</string>
  </array>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "=== 3/5 生成 8 份 .strings（en 注入劫持 + 坏占位符） ==="
for tag in zh-Hans en zh-Hant ja ko fr de es; do
    install -d "$APP/Contents/Resources/$tag.lproj"
done

# en：故意把中文 defaultValue 对应的 key 译成英文，并注入
# ① 正常译文 ② 空串 ③ 坏占位符 %@ ④ HIJACKED（试图劫持 defaultValue 本身）。
cat > "$APP/Contents/Resources/en.lproj/Localizable.strings" <<'STRINGS'
"qa.total" = "TOTAL %d ITEMS";
"qa.empty" = "";
"qa.bad" = "TOTAL %@ ITEMS";
"qa.cancelled" = "CANCELLED";
"操作已取消。" = "HIJACKED";
"共 %d 项" = "HIJACKED";
STRINGS

for tag in zh-Hans zh-Hant ja ko fr de es; do
    cat > "$APP/Contents/Resources/$tag.lproj/Localizable.strings" <<STRINGS
"qa.total" = "[$tag] %d ITEMS";
"qa.empty" = "[$tag] EMPTY";
"qa.cancelled" = "[$tag] CANCEL";
STRINGS
done

codesign --force --sign - "$APP/Contents/Frameworks/libMacCopyKit.dylib" 2>/dev/null || true
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "=== 4/5 场景 A：系统语言 = en（与注入语言叠加，防护必须触发） ==="
set +e
"$APP/Contents/MacOS/I18NAppProbe" -AppleLanguages "(en)" all
RC_EN=$?
set -e
echo "场景 A EXIT=$RC_EN"
if [ "$RC_EN" -ne 0 ]; then
    echo "❌ 场景 A 失败（139 = SIGSEGV，说明 baseline() 防护未生效）"
    exit 1
fi

echo "=== 4b/5 对照：系统语言 = zh-Hans（不叠加，用于证明「不叠加会假通过」） ==="
set +e
"$APP/Contents/MacOS/I18NAppProbe" -AppleLanguages "(zh-Hans)" all > /dev/null 2>&1
RC_ZH=$?
set -e
echo "对照 EXIT=$RC_ZH (仅记录，不作为判定)"

echo "=== 5/5 场景 B：物理删除整个 ko.lproj → bundle == nil 分支 ==="
rm -rf "$APP/Contents/Resources/ko.lproj"
codesign --force --deep --sign - "$APP" 2>/dev/null || true
set +e
"$APP/Contents/MacOS/I18NAppProbe" -AppleLanguages "(ko)" noBundle
RC_KO=$?
set -e
echo "场景 B EXIT=$RC_KO"
if [ "$RC_KO" -ne 0 ]; then
    echo "❌ 场景 B 失败（整个 lproj 缺失时必须恒中文）"
    exit 1
fi

echo ""
echo "✅ 真实 .app i18n 验收通过（en 叠加 / ko.lproj 物理缺失 / 均未崩溃）"
exit 0
