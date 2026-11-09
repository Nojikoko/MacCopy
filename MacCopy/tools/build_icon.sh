#!/bin/bash
#
# 从 Resources/Icon/MacCopyIcon.svg 生成 macOS 应用图标 MacCopy.icns
#
# 设计源：Resources/Icon/MacCopyIcon.svg（矢量，唯一事实源）
# 渲染：Edge / Chrome headless（任何支持 SVG + 透明截图的浏览器均可）
# 打包：sips（缩放）+ iconutil（生成 icns），均为 macOS 自带，零第三方依赖
#
# 小尺寸优化：16/32px 另用「减留白 + 加粗描边」的变体渲染。
#   16px 只有 256 个像素，标准版里白色勾会糊成一个点；变体通过
#   收紧 viewBox 让符号撑满更多画布、加粗线条，保证侧栏/列表里仍可辨认。
#
# 用法：bash tools/build_icon.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICON_DIR="$ROOT/Resources/Icon"
SVG="$ICON_DIR/MacCopyIcon.svg"
ICNS="$ICON_DIR/MacCopy.icns"
TMP="$ROOT/.tmp/icon-build"

EDGE="/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
if [ ! -x "$EDGE" ]; then
    EDGE="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
fi
if [ ! -x "$EDGE" ]; then
    echo "❌ 未找到 Edge 或 Chrome（用于把 SVG 渲染成 PNG）" >&2
    exit 2
fi

install -d "$TMP" "$TMP/profile" "$TMP/MacCopy.iconset"
SET="$TMP/MacCopy.iconset"

# ① 生成标准版与小尺寸优化版 SVG
python3 - "$SVG" "$TMP" <<'PYEOF'
import sys
src, tmp = sys.argv[1], sys.argv[2]
svg = open(src, encoding="utf-8").read()

# 小尺寸变体：收紧 viewBox 让符号放大约 13%，并加粗所有描边
small = (svg
    .replace('viewBox="0 0 1024 1024"', 'viewBox="60 60 904 904"')
    .replace('stroke-width="65"', 'stroke-width="84"')
    .replace('stroke-width="23"', 'stroke-width="31"')
    .replace('stroke-width="4"', 'stroke-width="6"')
    .replace('r="104"', 'r="118"'))
assert small != svg, "小尺寸变体替换未生效，请检查 SVG"
open(tmp + "/small.svg", "w", encoding="utf-8").write(small)
open(tmp + "/standard.svg", "w", encoding="utf-8").write(svg)
PYEOF

# ② SVG → HTML 包装（保证透明背景、零边距）
make_html() {
python3 - "$1" "$2" <<'PYEOF'
import sys
svg = open(sys.argv[1], encoding="utf-8").read()
body = svg[svg.index("<svg"):]
html = (
    '<!doctype html><html><head><meta charset="utf-8"><style>'
    'html,body{margin:0;padding:0;width:1024px;height:1024px;'
    'background:transparent;overflow:hidden}'
    'svg{display:block;width:1024px;height:1024px}'
    '</style></head><body>' + body + '</body></html>'
)
open(sys.argv[2], "w", encoding="utf-8").write(html)
PYEOF
}

render() {
    local svg_file="$1" out_png="$2" tag="$3"
    echo "渲染 $tag …"
    make_html "$svg_file" "$TMP/render.html"
    rm -f "$out_png"
    "$EDGE" --headless --disable-gpu --no-first-run --no-default-browser-check \
        --user-data-dir="$TMP/profile" \
        --default-background-color=00000000 \
        --screenshot="$out_png" \
        --window-size=1024,1024 --force-device-scale-factor=1 --hide-scrollbars \
        "file://$TMP/render.html" >/dev/null 2>&1 || true
    if [ ! -f "$out_png" ]; then
        echo "❌ $tag 渲染失败" >&2
        exit 3
    fi
}

render "$TMP/standard.svg" "$TMP/icon-standard-1024.png" "标准版 1024×1024"
render "$TMP/small.svg" "$TMP/icon-small-1024.png" "小尺寸优化版 1024×1024"

# ③ 生成 macOS 标准 iconset 的 10 个尺寸
#    <= 64px 用优化版，其余用标准版
echo "生成 iconset …"
make_size() {
    local src_png="$1" size="$2" name="$3"
    cp "$src_png" "$SET/$name"
    sips -z "$size" "$size" "$SET/$name" >/dev/null
}
SMALL="$TMP/icon-small-1024.png"
FULL="$TMP/icon-standard-1024.png"
make_size "$SMALL" 16   "icon_16x16.png"
make_size "$SMALL" 32   "icon_16x16@2x.png"
make_size "$SMALL" 32   "icon_32x32.png"
make_size "$SMALL" 64   "icon_32x32@2x.png"
make_size "$FULL"  128  "icon_128x128.png"
make_size "$FULL"  256  "icon_128x128@2x.png"
make_size "$FULL"  256  "icon_256x256.png"
make_size "$FULL"  512  "icon_256x256@2x.png"
make_size "$FULL"  512  "icon_512x512.png"
make_size "$FULL"  1024 "icon_512x512@2x.png"

# ④ 打包 icns
iconutil -c icns "$SET" -o "$ICNS"
echo "✅ 已生成 $ICNS"

# ⑤ 附上 1024 PNG，供 README / 网页使用
cp "$FULL" "$ICON_DIR/MacCopyIcon-1024.png"
echo "   预览图：$ICON_DIR/MacCopyIcon-1024.png"
