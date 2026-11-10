#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Config/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PROJECT_DIR/Config/Info.plist")"
VERIFY_DIR=""
MOUNT_DIR=""
MOUNTED=0
if [ "$#" -gt 0 ]; then
  APP_BUNDLE="$1"
else
  VERIFY_DIR="$(mktemp -d /tmp/x-article-archiver-app-verify.XXXXXX)"
  MOUNT_DIR="$VERIFY_DIR/mount"
  mkdir -p "$MOUNT_DIR"
  hdiutil attach "$PROJECT_DIR/dist/MarkX-$APP_VERSION.dmg" -nobrowse -readonly -mountpoint "$MOUNT_DIR" -quiet
  MOUNTED=1
  APP_BUNDLE="$MOUNT_DIR/MarkX.app"
fi

cleanup() {
  if [ "$MOUNTED" -eq 1 ]; then hdiutil detach "$MOUNT_DIR" -quiet || true; fi
  if [ -n "$VERIFY_DIR" ]; then rm -rf "$VERIFY_DIR"; fi
}
trap cleanup EXIT

test -d "$APP_BUNDLE"
test -x "$APP_BUNDLE/Contents/MacOS/XArticleArchiverApp"
test -f "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
plutil -lint "$APP_BUNDLE/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
file "$APP_BUNDLE/Contents/MacOS/XArticleArchiverApp" | grep -q 'arm64'
test "$(defaults read "$APP_BUNDLE/Contents/Info" CFBundleDisplayName)" = "MarkX"
test "$(defaults read "$APP_BUNDLE/Contents/Info" CFBundleName)" = "MarkX"
test "$(defaults read "$APP_BUNDLE/Contents/Info" CFBundleShortVersionString)" = "$APP_VERSION"
test "$(defaults read "$APP_BUNDLE/Contents/Info" CFBundleVersion)" = "$BUILD_NUMBER"
test "$(defaults read "$APP_BUNDLE/Contents/Info" LSMultipleInstancesProhibited)" = "1"
test "$(defaults read "$APP_BUNDLE/Contents/Info" CFBundleURLTypes | grep -c xarticlearchiver)" -ge 1
test "$(defaults read "$APP_BUNDLE/Contents/Info" CFBundleIconFile)" = "AppIcon.icns"
file "$APP_BUNDLE/Contents/Resources/AppIcon.icns" | grep -q 'Mac OS X icon'
cmp -s "$PROJECT_DIR/Config/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cmp -s "$PROJECT_DIR/LICENSE" "$APP_BUNDLE/Contents/Resources/LICENSE"
printf 'APP_VERIFY=PASS\n'
