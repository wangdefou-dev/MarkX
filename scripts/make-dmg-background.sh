#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_SVG="$PROJECT_DIR/Design/Installer/DMG-background.svg"
OUTPUT_PNG="$PROJECT_DIR/Config/DMG-background.png"

sips -s format png "$SOURCE_SVG" --out "$OUTPUT_PNG" >/dev/null
test "$(sips -g pixelWidth "$OUTPUT_PNG" | awk '/pixelWidth/ {print $2}')" = "720"
test "$(sips -g pixelHeight "$OUTPUT_PNG" | awk '/pixelHeight/ {print $2}')" = "460"
printf 'DMG_BACKGROUND_BUILD=PASS\n%s\n' "$OUTPUT_PNG"
