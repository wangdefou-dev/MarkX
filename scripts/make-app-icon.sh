#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_IMAGE="${1:-$PROJECT_DIR/Design/AppIcon/AppIcon-corrected-v4-preview.png}"
MASTER_IMAGE="$PROJECT_DIR/Config/AppIcon-1024.png"
ICONSET_DIR="$PROJECT_DIR/Config/AppIcon.iconset"
ICNS_PATH="$PROJECT_DIR/Config/AppIcon.icns"

mkdir -p "$ICONSET_DIR"
sips -z 1024 1024 "$SOURCE_IMAGE" --out "$MASTER_IMAGE" >/dev/null

sips -z 16 16 "$MASTER_IMAGE" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "$MASTER_IMAGE" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$MASTER_IMAGE" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "$MASTER_IMAGE" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$MASTER_IMAGE" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "$MASTER_IMAGE" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$MASTER_IMAGE" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "$MASTER_IMAGE" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$MASTER_IMAGE" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
cp "$MASTER_IMAGE" "$ICONSET_DIR/icon_512x512@2x.png"

xattr -cr "$ICONSET_DIR" "$MASTER_IMAGE"
iconutil -c icns "$ICONSET_DIR" -o "$ICNS_PATH"
xattr -cr "$ICNS_PATH"

sips -g pixelWidth -g pixelHeight -g hasAlpha "$MASTER_IMAGE"
file "$ICNS_PATH"
printf 'ICON_BUILD=PASS\n%s\n' "$ICNS_PATH"
