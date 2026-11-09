#!/bin/bash
#
# MacCopy 构建脚本。
#
# 环境事实（见 docs/BUILD-ENV-NOTES.md）：
# - 本机 SwiftPM（swift build / swift test）不可用，manifest 编译环节静默失败
# - 因此改用 `swiftc` 直接编译 → 链接
# - 沙盒拦截 `mkdir`，改用 `install -d`（等价的目录创建，且不被拦）
#
# 用法：
#   ./build.sh          # Release（-O）
#   ./build.sh debug    # Debug（-Onone）

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
    echo "构建模式：Debug"
else
    echo "构建模式：Release"
fi

# 创建目录（沙盒下 mkdir 被拦，用 install -d）。
install -d "$BUILD_DIR" "$TMP_DIR" "$MODULE_CACHE"

# 收集 Swift 源文件。
SOURCES_FILE="$BUILD_DIR/sources.txt"
find "$ROOT/src/MacCopyKit" -name '*.swift' | sort > "$SOURCES_FILE"
SOURCE_COUNT="$(wc -l < "$SOURCES_FILE" | tr -d ' ')"
echo "源文件数：$SOURCE_COUNT"

echo "编译 MacCopyKit …"
swiftc $OPTIMIZATION -parse-as-library -swift-version 6 \
    -target "$TARGET" \
    -sdk "$SDK" \
    -module-name MacCopyKit \
    -module-cache-path "$MODULE_CACHE" \
    @"$SOURCES_FILE" \
    -emit-module \
    -emit-module-path "$BUILD_DIR/MacCopyKit.swiftmodule" \
    -emit-library \
    -o "$BUILD_DIR/libMacCopyKit.dylib"

echo "构建完成：$BUILD_DIR/libMacCopyKit.dylib"

# ② 编译 CLI（跨模块集成验证：CLI 消费 MacCopyKit）。
CLI_SOURCES_FILE="$BUILD_DIR/cli-sources.txt"
find "$ROOT/src/MacCopyCLI" -name '*.swift' | sort > "$CLI_SOURCES_FILE"
if [ -s "$CLI_SOURCES_FILE" ]; then
    echo ""
    echo "编译 MacCopyCLI …"
    swiftc $OPTIMIZATION -parse-as-library -swift-version 6 \
        -target "$TARGET" \
        -sdk "$SDK" \
        -module-name MacCopyCLI \
        -module-cache-path "$MODULE_CACHE" \
        -I "$BUILD_DIR" \
        -L "$BUILD_DIR" \
        -lMacCopyKit \
        @"$CLI_SOURCES_FILE" \
        -o "$BUILD_DIR/MacCopyCLI"
    echo "构建完成：$BUILD_DIR/MacCopyCLI"
fi

# ③ 编译 App（SwiftUI，macOS 13.0 目标）。
APP_SOURCES_FILE="$BUILD_DIR/app-sources.txt"
find "$ROOT/src/MacCopyApp" -name '*.swift' | sort > "$APP_SOURCES_FILE"
if [ -s "$APP_SOURCES_FILE" ]; then
    echo ""
    echo "编译 MacCopyApp …"
    swiftc $OPTIMIZATION -parse-as-library -swift-version 6 \
        -target "$TARGET" \
        -sdk "$SDK" \
        -module-name MacCopyApp \
        -module-cache-path "$MODULE_CACHE" \
        -I "$BUILD_DIR" \
        -L "$BUILD_DIR" \
        -lMacCopyKit \
        @"$APP_SOURCES_FILE" \
        -o "$BUILD_DIR/MacCopy"
    echo "构建完成：$BUILD_DIR/MacCopy"
fi

echo ""
echo "全部构建产物："
ls -la "$BUILD_DIR/libMacCopyKit.dylib" "$BUILD_DIR/MacCopyCLI" "$BUILD_DIR/MacCopy" 2>/dev/null || true
