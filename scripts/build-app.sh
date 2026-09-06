#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$PROJECT_DIR/dist"
APP_NAME="MarkX"
DMG_VOLUME_NAME="MarkX 安装"
DMG_PATH="$DIST_DIR/MarkX-0.2.12.dmg"
ZIP_PATH="$DIST_DIR/MarkX-0.2.12.zip"
BUILD_DIR="$(mktemp -d /tmp/x-article-archiver-app.XXXXXX)"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
STAGING_DIR="$(mktemp -d /tmp/x-article-archiver-dmg.XXXXXX)"
DMG_MOUNT_DIR=""
DMG_RW_PATH="$BUILD_DIR/MarkX-rw.dmg"
DMG_DEVICE=""
IDENTITY="${CODE_SIGN_IDENTITY:--}"

cleanup() {
  if [ -n "$DMG_DEVICE" ]; then
    hdiutil detach "$DMG_DEVICE" -quiet || true
  fi
  rm -rf "$BUILD_DIR"
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

cd "$PROJECT_DIR"
"$PROJECT_DIR/scripts/make-app-icon.sh"
"$PROJECT_DIR/scripts/make-dmg-background.sh"
swift test
swift build -c release --arch arm64

rm -rf "$DIST_DIR/$APP_NAME.app"
rm -f "$DMG_PATH" "$ZIP_PATH"
mkdir -p "$DIST_DIR" "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$STAGING_DIR"

cp "$PROJECT_DIR/.build/arm64-apple-macosx/release/XArticleArchiverApp" "$APP_BUNDLE/Contents/MacOS/XArticleArchiverApp"
cp "$PROJECT_DIR/Config/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$PROJECT_DIR/Config/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
chmod 755 "$APP_BUNDLE/Contents/MacOS/XArticleArchiverApp"
xattr -cr "$APP_BUNDLE"

codesign --force --deep --options runtime --timestamp=none --entitlements "$PROJECT_DIR/Config/XArticleArchiver.entitlements" --sign "$IDENTITY" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

ditto --norsrc --noextattr "$APP_BUNDLE" "$STAGING_DIR/$APP_NAME.app"
xattr -cr "$STAGING_DIR/$APP_NAME.app"
codesign --verify --deep --strict --verbose=2 "$STAGING_DIR/$APP_NAME.app"
mkdir -p "$STAGING_DIR/.background"
cp "$PROJECT_DIR/Config/DMG-background.png" "$STAGING_DIR/.background/DMG-background.png"
ln -s /Applications "$STAGING_DIR/Applications"

if mount | grep -Fq "/Volumes/$DMG_VOLUME_NAME"; then
  hdiutil detach "/Volumes/$DMG_VOLUME_NAME" -quiet || hdiutil detach "/Volumes/$DMG_VOLUME_NAME" -force -quiet
fi

# Build a writable image first so Finder can persist the standard drag-to-
# Applications layout and large icon positions into the volume's .DS_Store.
hdiutil create -volname "$DMG_VOLUME_NAME" -srcfolder "$STAGING_DIR" -ov -fs HFS+ -format UDRW "$DMG_RW_PATH" >/dev/null
ATTACH_OUTPUT="$(hdiutil attach "$DMG_RW_PATH" -readwrite -noverify -noautoopen)"
DMG_DEVICE="$(printf '%s\n' "$ATTACH_OUTPUT" | awk '/Apple_HFS|Apple_APFS/ {print $1; exit}')"
DMG_MOUNT_DIR="$(printf '%s\n' "$ATTACH_OUTPUT" | awk -F '\t' '/Apple_HFS|Apple_APFS/ {print $3; exit}')"
test -n "$DMG_DEVICE"
test -n "$DMG_MOUNT_DIR"

LAYOUT_ICON_SIZE="$(osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$DMG_VOLUME_NAME"
    open
    set installerWindow to container window
    set current view of installerWindow to icon view
    set toolbar visible of installerWindow to false
    set statusbar visible of installerWindow to false
    set pathbar visible of installerWindow to false
    set bounds of installerWindow to {100, 100, 820, 560}
    set viewOptions to the icon view options of installerWindow
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 144
    set text size of viewOptions to 14
    set background picture of viewOptions to file ".background:DMG-background.png"
    set position of item "$APP_NAME.app" of installerWindow to {180, 250}
    set position of item "Applications" of installerWindow to {540, 250}
    update without registering applications
    delay 2
    close installerWindow
    delay 2
    open
    set installerWindow to container window
    set viewOptions to the icon view options of installerWindow
    set icon size of viewOptions to 144
    set background picture of viewOptions to file ".background:DMG-background.png"
    update without registering applications
    delay 2
    set savedIconSize to icon size of viewOptions
    close installerWindow
    delay 2
    return savedIconSize as text
  end tell
end tell
APPLESCRIPT
)"
test "$LAYOUT_ICON_SIZE" = "144"

SetFile -a V "$DMG_MOUNT_DIR/.background"
sync
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if [ -f "$DMG_MOUNT_DIR/.DS_Store" ]; then break; fi
  sleep 0.5
done
test -f "$DMG_MOUNT_DIR/.DS_Store"
hdiutil detach "$DMG_DEVICE" -quiet
DMG_DEVICE=""
hdiutil convert "$DMG_RW_PATH" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null

# Keep bundle construction in /tmp. Building a .app directly inside an
# iCloud/File Provider folder can attach FinderInfo and invalidate its seal.
xattr -cr "$APP_BUNDLE"
codesign --force --deep --options runtime --timestamp=none --entitlements "$PROJECT_DIR/Config/XArticleArchiver.entitlements" --sign "$IDENTITY" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
ditto -c -k --norsrc --noextattr --keepParent "$APP_BUNDLE" "$ZIP_PATH"

file "$APP_BUNDLE/Contents/MacOS/XArticleArchiverApp"
plutil -lint "$APP_BUNDLE/Contents/Info.plist"
shasum -a 256 "$DMG_PATH" "$ZIP_PATH"

printf '\nBuilt local test installers:\n%s\n%s\n' "$DMG_PATH" "$ZIP_PATH"
if [ "$IDENTITY" = "-" ]; then
  printf 'Note: ad-hoc signed for local testing; Developer ID notarization is not configured on this Mac.\n'
fi
