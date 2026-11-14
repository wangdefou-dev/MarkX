#!/bin/bash
set -euo pipefail

VERSION="$1"
ASSET_DIR="$2"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
DMG="MarkX-$VERSION.dmg"
CHECKSUM=SHA256SUMS.txt
PREFIX="downloads/markx/$VERSION"
BUCKET=defou-ai
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

(
  cd "$ASSET_DIR"
  # Validate the exact manifest before accepting any filenames or uploading.
  shasum -a 256 "$DMG" > "$WORK_DIR/expected-sha"
  cmp "$CHECKSUM" "$WORK_DIR/expected-sha"
)

if [ "${MARKX_VERIFY_ONLY:-0}" != 1 ]; then
  : "${R2_ENDPOINT:?Set the R2_ENDPOINT Actions variable}"
  : "${AWS_ACCESS_KEY_ID:?Set the R2_ACCESS_KEY_ID Actions secret}"
  : "${AWS_SECRET_ACCESS_KEY:?Set the R2_SECRET_ACCESS_KEY Actions secret}"

  put_immutable() {
    local name="$1" content_type="$2"
    if ! aws --region auto --endpoint-url "$R2_ENDPOINT" s3api put-object \
      --bucket "$BUCKET" --key "$PREFIX/$name" --if-none-match '*' \
      --body "$ASSET_DIR/$name" --content-type "$content_type" \
      --cache-control 'public, max-age=31536000, immutable' > /dev/null; then
      # A concurrent or previous upload can win. Continue only for identical bytes.
      aws --region auto --endpoint-url "$R2_ENDPOINT" s3api get-object \
        --bucket "$BUCKET" --key "$PREFIX/$name" "$WORK_DIR/existing-$name" > /dev/null
      if ! cmp -s "$ASSET_DIR/$name" "$WORK_DIR/existing-$name"; then
        printf 'Existing R2 object %s/%s differs from this release. Use a new version.\n' "$PREFIX" "$name" >&2
        return 1
      fi
    fi
  }

  put_immutable "$DMG" application/x-apple-diskimage
  put_immutable "$CHECKSUM" 'text/plain; charset=utf-8'
fi

curl --fail --silent --show-error --location --retry 8 --retry-all-errors --connect-timeout 10 --max-time 90 \
  "https://download.markx.defou.ai/$VERSION/$DMG?source=verify" -o "$WORK_DIR/online-$DMG"
curl --fail --silent --show-error --location --retry 8 --retry-all-errors --connect-timeout 10 --max-time 90 \
  "https://1want.link/$PREFIX/$CHECKSUM" -o "$WORK_DIR/online-$CHECKSUM"
cmp "$ASSET_DIR/$DMG" "$WORK_DIR/online-$DMG"
cmp "$ASSET_DIR/$CHECKSUM" "$WORK_DIR/online-$CHECKSUM"
printf 'Public release assets match the original DMG and SHA-256 manifest for %s.\n' "$VERSION"
