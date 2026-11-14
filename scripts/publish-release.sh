#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Config/Info.plist)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Config/Info.plist)"
TAG="v$VERSION"
REPO=wangdefou-dev/MarkX
DMG="${1:-dist/MarkX-$VERSION.dmg}"
CHECKSUM="$(dirname "$DMG")/SHA256SUMS.txt"

test "$(basename "$DMG")" = "MarkX-$VERSION.dmg"
git diff --quiet HEAD -- Config Sources Package.swift scripts CHANGELOG.md .github/workflows || {
  printf 'Commit the release source and version files before publishing.\n' >&2
  exit 1
}
if [ -n "$(git ls-files --others --exclude-standard -- Config Sources scripts .github/workflows)" ]; then
  printf 'Commit the untracked release source files before publishing.\n' >&2
  exit 1
fi
COMMIT="$(git rev-parse HEAD)"
if [ "$(gh api "repos/$REPO/commits/main" --jq .sha)" != "$COMMIT" ]; then
  printf 'Push this release commit to %s/main before publishing.\n' "$REPO" >&2
  exit 1
fi

NOTES="$(awk -v heading="## $VERSION 更新" '
  $0 == heading { release = 1; next }
  release && /^## / { exit }
  release && /^- / { print }
' CHANGELOG.md)"
if [ -z "$NOTES" ]; then
  printf 'Add the release notes under ## %s 更新 in CHANGELOG.md.\n' "$VERSION" >&2
  exit 1
fi

./scripts/verify-packages.sh "$DMG"
SHA256="$(shasum -a 256 < "$DMG" | awk '{print $1}')"
printf '%s  MarkX-%s.dmg\n' "$SHA256" "$VERSION" > "$CHECKSUM"

REMOTE_TAG="$(git ls-remote "https://github.com/$REPO.git" "refs/tags/$TAG" "refs/tags/$TAG^{}")"
if [ -z "$REMOTE_TAG" ]; then
  git push "https://github.com/$REPO.git" "$COMMIT:refs/tags/$TAG"
else
  # The peeled commit appears last when the version already has an annotated tag.
  test "$(printf '%s\n' "$REMOTE_TAG" | awk 'END { print $1 }')" = "$COMMIT" || {
    printf 'Release tag %s already belongs to another commit.\n' "$TAG" >&2
    exit 1
  }
fi

gh release create "$TAG" "$DMG" "$CHECKSUM" --repo "$REPO" --verify-tag \
  --title "MarkX $VERSION (Build $BUILD)" --notes "$NOTES" --prerelease
printf '\nTrack the R2 upload and website deployment at https://github.com/%s/actions\n' "$REPO"
