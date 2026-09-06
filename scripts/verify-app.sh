#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERIFY_DIR=""
if [ "$#" -gt 0 ]; then
  APP_BUNDLE="$1"
else
  VERIFY_DIR="$(mktemp -d /tmp/x-article-archiver-app-verify.XXXXXX)"
  trap 'rm -rf "$VERIFY_DIR"' EXIT
  ditto -x -k "$PROJECT_DIR/dist/MarkX-0.2.4.zip" "$VERIFY_DIR"
  APP_BUNDLE="$VERIFY_DIR/MarkX.app"
fi

test -d "$APP_BUNDLE"
test -x "$APP_BUNDLE/Contents/MacOS/XArticleArchiverApp"
test -f "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
plutil -lint "$APP_BUNDLE/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
file "$APP_BUNDLE/Contents/MacOS/XArticleArchiverApp" | grep -q 'arm64'
test "$(defaults read "$APP_BUNDLE/Contents/Info" CFBundleDisplayName)" = "MarkX"
test "$(defaults read "$APP_BUNDLE/Contents/Info" CFBundleName)" = "MarkX"
test "$(defaults read "$APP_BUNDLE/Contents/Info" CFBundleShortVersionString)" = "0.2.4"
test "$(defaults read "$APP_BUNDLE/Contents/Info" CFBundleVersion)" = "60"
test "$(defaults read "$APP_BUNDLE/Contents/Info" CFBundleURLTypes | grep -c xarticlearchiver)" -ge 1
test "$(defaults read "$APP_BUNDLE/Contents/Info" CFBundleIconFile)" = "AppIcon.icns"
file "$APP_BUNDLE/Contents/Resources/AppIcon.icns" | grep -q 'Mac OS X icon'
cmp -s "$PROJECT_DIR/Config/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
printf 'APP_VERIFY=PASS\n'
