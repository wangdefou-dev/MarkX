#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$PROJECT_DIR/dist"
DMG_PATH="$DIST_DIR/MarkX-0.2.7.dmg"
ZIP_PATH="$DIST_DIR/MarkX-0.2.7.zip"
VERIFY_DIR="$(mktemp -d /tmp/x-article-archiver-verify.XXXXXX)"
MOUNT_DIR="$VERIFY_DIR/mount"

cleanup() {
  if mount | grep -q "$MOUNT_DIR"; then hdiutil detach "$MOUNT_DIR" -quiet || true; fi
  rm -rf "$VERIFY_DIR"
}
trap cleanup EXIT

test -f "$DMG_PATH"
test -f "$ZIP_PATH"

mkdir -p "$MOUNT_DIR" "$VERIFY_DIR/zip"
hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$MOUNT_DIR" -quiet
test -L "$MOUNT_DIR/Applications"
test "$(readlink "$MOUNT_DIR/Applications")" = "/Applications"
test -f "$MOUNT_DIR/.background/DMG-background.png"
test -f "$MOUNT_DIR/.DS_Store"
"$PROJECT_DIR/scripts/verify-app.sh" "$MOUNT_DIR/MarkX.app"
hdiutil detach "$MOUNT_DIR" -quiet

ditto -x -k "$ZIP_PATH" "$VERIFY_DIR/zip"
"$PROJECT_DIR/scripts/verify-app.sh" "$VERIFY_DIR/zip/MarkX.app"

printf 'PACKAGE_VERIFY=PASS\n'
