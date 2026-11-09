#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
swift build
BIN_DIR="$(swift build --show-bin-path)"
PREVIEW_DIR="$(mktemp -d /tmp/markx-ui-preview.XXXXXX)"
APP_BUNDLE="$PREVIEW_DIR/MarkX UI Review.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_DIR/XArticleArchiverApp" "$APP_BUNDLE/Contents/MacOS/XArticleArchiverApp"
cp Config/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
python3 - "$PROJECT_DIR/Config/Info.plist" "$APP_BUNDLE/Contents/Info.plist" <<'PY'
from pathlib import Path
import plistlib,sys
data=plistlib.loads(Path(sys.argv[1]).read_bytes())
data.update(CFBundleIdentifier='ai.defou.markx-ui-preview', CFBundleName='MarkX UI Review', CFBundleDisplayName='MarkX UI Review', MarkXInterfacePreview=True)
data.pop('CFBundleURLTypes',None)
Path(sys.argv[2]).write_bytes(plistlib.dumps(data))
PY
codesign --force --sign - "$APP_BUNDLE"
printf 'UI_PREVIEW_APP=%s\n' "$APP_BUNDLE"
