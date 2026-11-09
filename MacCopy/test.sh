#!/bin/bash
#
# MacCopy 测试脚本。
#
# 编译并运行自建测试运行器（不用 XCTest，原因见 docs/BUILD-ENV-NOTES.md §6.3）。
# 退出码非 0 表示存在失败用例。
#
# 用法：
#   ./test.sh          # Release（-O）—— BLAKE3 吞吐测试必须用 Release
#   ./test.sh debug    # Debug

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/.build"
TMP_DIR="$ROOT/.tmp"
MODULE_CACHE="$TMP_DIR/modcache"

export TMPDIR="$TMP_DIR"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"

SDK="$(xcrun --show-sdk-path)"
TARGET="arm64-apple-macos13.0"

OPTIMIZATION="-O"
if [ "${1:-}" = "debug" ]; then
    OPTIMIZATION="-Onone"
    echo "测试模式：Debug（吞吐断言可能不达标，仅供功能调试）"
else
    echo "测试模式：Release"
fi

install -d "$BUILD_DIR" "$TMP_DIR" "$MODULE_CACHE"

# ① 先构建库。
echo "=== 构建 MacCopyKit ==="
bash "$ROOT/build.sh" "$([ "${1:-}" = "debug" ] && echo debug || echo release)"

# ② 编译测试。
echo ""
echo "=== 编译测试 ==="
SOURCES_FILE="$BUILD_DIR/test-sources.txt"
find "$ROOT/Tests" -name '*.swift' | sort > "$SOURCES_FILE"

swiftc $OPTIMIZATION -parse-as-library -swift-version 6 \
    -target "$TARGET" \
    -sdk "$SDK" \
    -module-name MacCopyTests \
    -module-cache-path "$MODULE_CACHE" \
    -I "$BUILD_DIR" \
    -L "$BUILD_DIR" \
    -lMacCopyKit \
    @"$SOURCES_FILE" \
    -o "$BUILD_DIR/MacCopyTests"

# ③ 运行测试。
echo ""
echo "=== 运行测试 ==="
export DYLD_LIBRARY_PATH="$BUILD_DIR${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
"$BUILD_DIR/MacCopyTests"
EXIT_CODE=$?

echo ""
if [ "$EXIT_CODE" -eq 0 ]; then
    echo "✅ 测试全部通过"
else
    echo "❌ 测试存在失败（退出码 $EXIT_CODE）"
fi

# ④ 静态合规扫描（v1.1 T-I05 §6）——只在测试全绿时执行，失败即整体非零。
# 用 Python 实现，避免 `set -o pipefail` 下 grep 无命中返回 1 导致脚本误退出。
echo ""
echo "=== 静态合规扫描 ==="
python3 - "$ROOT" <<'PYEOF' || exit 1
import json, re, sys
from pathlib import Path

root = Path(sys.argv[1])
src = root / "src"
kit = src / "MacCopyKit"
swift = sorted(src.rglob("*.swift"))
failed = []

# AD-01：@Observable 真实使用（排除注释行）。
ad01 = []
for p in swift:
    for n, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith("//") or stripped.startswith("*"):
            continue
        if "@Observable" in line:
            ad01.append(f"{p.relative_to(root)}:{n}")
if ad01:
    failed.append(f"AD-01 @Observable 真实使用 {len(ad01)} 处：{ad01[:3]}")
else:
    print("  ✅ AD-01：无 @Observable 真实使用")

# AD-02：MacCopyKit Foundation-only。
ad02 = []
for p in sorted(kit.rglob("*.swift")):
    for n, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
        if re.search(r"^\s*import\s+(SwiftUI|AppKit|ServiceManagement)\b", line):
            ad02.append(f"{p.relative_to(root)}:{n}")
if ad02:
    failed.append(f"AD-02 MacCopyKit 出现 UI 依赖 {len(ad02)} 处：{ad02[:3]}")
else:
    print("  ✅ AD-02：MacCopyKit Foundation-only")

# 术语规范：禁止以「国家」作八语量词。
term = []
for p in swift:
    for n, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
        if re.search(r"\d+\s*个国家|个国家语言|8\s*个国家", line):
            term.append(f"{p.relative_to(root)}:{n}")
if term:
    failed.append(f"术语规范：「国家」量词 {len(term)} 处")
else:
    print("  ✅ 术语规范：「八种语言」表述，无「国家」量词")

# 源码本地化 key 全部登记在 Catalog。
catalog = root / "src" / "MacCopyApp" / "Localization" / "Localizable.xcstrings"
if not catalog.exists():
    failed.append("Localizable.xcstrings 不存在")
else:
    keys = set(json.loads(catalog.read_text(encoding="utf-8")).get("strings", {}))
    pattern = re.compile(
        r'Localization\.(?:string|format)\(\s*"([A-Za-z0-9_.\-]+)"', re.MULTILINE
    )
    used = set()
    for p in swift:
        used.update(pattern.findall(p.read_text(encoding="utf-8")))
    missing = sorted(used - keys)
    if missing:
        failed.append(f"源码有 {len(missing)} 个未登记 key：{missing[:5]}")
    else:
        print(f"  ✅ 源码本地化 key 全部登记（{len(used)} 个）")

if failed:
    for f in failed:
        print(f"  ❌ {f}")
    print("❌ 静态合规扫描失败")
    sys.exit(1)

# ⑤ AD-I12 / P0-06 ⑥：中文基准写法的静态断言。
# 单测即使全绿也守不住 V-B1 —— 裸进程里把 baseline() 改回裸
# String(localized:defaultValue:) 仍会「看起来正常」。这条静态断言
# 在裸进程里也生效，是单测测不到的补集（架构 T-I05 第 7 步）。
loc = root / "src" / "MacCopyKit" / "Support" / "Localization.swift"
loc_text = loc.read_text(encoding="utf-8") if loc.exists() else ""
static_fail = []
if "baselineTable" not in loc_text:
    static_fail.append("Localization.swift 缺少 baselineTable")
if "private static func baseline(" not in loc_text:
    static_fail.append("Localization.swift 缺少 baseline(_:_:)")
base_count = loc_text.count("let base = baseline(key, defaultValue)")
if base_count < 2:
    static_fail.append(f"string/format 应以 baseline() 取 base，实际仅 {base_count} 处")
# 排除注释行后，统计「无 table: 且无 bundle:」的裸 String(localized:defaultValue:)
bare = []
for n, line in enumerate(loc_text.splitlines(), 1):
    if line.strip().startswith("//") or line.strip().startswith("*"):
        continue
    if re.search(r"String\(localized:[^)]*defaultValue:", line) \
            and "table:" not in line and "bundle:" not in line:
        bare.append(f"{loc.name}:{n}")
if bare:
    static_fail.append(f"存在可劫持的裸 String(localized:defaultValue:) {len(bare)} 处：{bare[:3]}")
if static_fail:
    for f in static_fail:
        print(f"  ❌ {f}")
    print("❌ AD-I12 静态断言失败")
    sys.exit(1)
print("  ✅ AD-I12：baseline() 存在、string/format 均使用、裸重载 0 处")

print("✅ 静态合规扫描通过")
PYEOF

# ⑤ 真实 .app 内的 i18n 验收（AD-I12 / P0-06 ⑥ / P0-10 ⑥）。
# 裸测试进程测不出「中文基准被 Bundle.main 劫持」的坑，必须构造带
# 8 个 .lproj 的真实 .app 并叠加 -AppleLanguages "(en)" 才能暴露 SIGSEGV。
echo ""
echo "=== 真实 .app i18n 验收 ==="
if bash "$ROOT/tools/i18n_app_acceptance.sh" > /dev/null 2>&1; then
    echo "  ✅ en 叠加 / ko.lproj 物理缺失 / 坏占位符 / 空串 / 漏 key 全部通过（未崩溃）"
else
    echo "  ❌ 真实 .app i18n 验收失败（139 = SIGSEGV，中文基准可能被劫持）"
    exit 1
fi

# ⑥ QA #13 官方单条验收（互补，不替代 ⑤）。
# 覆盖 en / de / zh-Hans 三种系统语言 + ko.lproj 物理删除变体，
# 含 A6「双劫持前置条件」断言，每个 case 独立子进程可单独捕获 SIGSEGV。
# QA 与架构都要求这条命令不能因单测全绿而跳过 —— 裸进程测不到 Bundle.main 劫持。
echo ""
echo "=== QA #13 i18n 专项验收（真实 .app / en + de + zh-Hans + ko 缺失）==="
I18N_ACCEPT="$ROOT/../proqa/i18n_acceptance.sh"
if [ -f "$I18N_ACCEPT" ]; then
    if bash "$I18N_ACCEPT" --no-build > /dev/null 2>&1; then
        echo "  ✅ 10/10 PASS（含 A6 双劫持前置条件、D1 缺失 lproj 回退）"
    else
        echo "  ❌ QA #13 i18n 专项验收失败"
        exit 1
    fi
else
    echo "  ⚠️  未找到 $I18N_ACCEPT —— 正式发版不允许跳过此步"
    exit 1
fi

exit "$EXIT_CODE"
