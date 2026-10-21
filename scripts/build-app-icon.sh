#!/bin/bash
# 从透明 PNG 生成 macOS 的多分辨率图标，保留 Retina 和小尺寸资源。
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ICON_SOURCE="$PROJECT_DIR/Resources/FileDeck.png"
ICON_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/filedeck-icon.XXXXXX")"
trap 'rm -rf "$ICON_TEMP"' EXIT
ICON_SET="$ICON_TEMP/FileDeck.iconset"
mkdir "$ICON_SET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICON_SET/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" "$ICON_SOURCE" --out "$ICON_SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICON_SET" -o "$PROJECT_DIR/Resources/FileDeck.icns"
echo "已生成 FileDeck.icns（16–1024 像素）"
