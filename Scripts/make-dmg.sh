#!/usr/bin/env bash
# Build a drag-to-Applications disk image without Finder automation or packages.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="${1:-}"
OUTPUT="${2:-}"
SIGNING_IDENTITY="${SIGN_IDENTITY:--}"

if [[ ! -d "$SOURCE_APP/Contents/MacOS" || "$OUTPUT" != *.dmg ]]; then
  echo "usage: $0 <YUANNotch.app> <output.dmg>" >&2
  exit 1
fi
SOURCE_APP="$(cd "$(dirname "$SOURCE_APP")" && pwd)/$(basename "$SOURCE_APP")"
mkdir -p "$(dirname "$OUTPUT")"
OUTPUT="$(cd "$(dirname "$OUTPUT")" && pwd)/$(basename "$OUTPUT")"
PREVIEW="${DMG_PREVIEW_PATH:-${OUTPUT%.dmg}-preview.png}"
codesign --verify --deep --strict "$SOURCE_APP"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/yuannotch-dmg.XXXXXX")"
MOUNT_DIR="$WORK_DIR/mount"
MOUNTED=0
cleanup() {
  if [[ "$MOUNTED" == 1 ]]; then
    if ! hdiutil detach "$MOUNT_DIR" >/dev/null; then
      echo "Temporary image is still mounted at $MOUNT_DIR; preserving $WORK_DIR" >&2
      return
    fi
  fi
  if [[ "${KEEP_DMG_WORK:-0}" == 1 ]]; then
    echo "DMG build files preserved at $WORK_DIR" >&2
    return
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

xcrun swiftc -swift-version 6 -o "$WORK_DIR/layout" "$ROOT_DIR/Scripts/dmg-layout/main.swift"
# Carbon aliases remain Finder's background-image format, confined to this tool.
xcrun clang -Wno-deprecated-declarations -framework CoreServices \
  -o "$WORK_DIR/alias" "$ROOT_DIR/Scripts/dmg-layout/alias.c"

STAGE="$WORK_DIR/stage"
mkdir -p "$STAGE/.background" "$MOUNT_DIR"
ditto "$SOURCE_APP" "$STAGE/YUANNotch.app"
ln -s /Applications "$STAGE/Applications"
"$WORK_DIR/layout" background "$STAGE/.background/installer.png" "$PREVIEW" "$SOURCE_APP"

hdiutil create -ov -volname YUANNotch -fs HFS+ -layout NONE -format UDRW \
  -srcfolder "$STAGE" -nospotlight "$WORK_DIR/writable.dmg" >/dev/null
hdiutil attach -nobrowse -noautoopen -mountpoint "$MOUNT_DIR" \
  "$WORK_DIR/writable.dmg" >/dev/null
MOUNTED=1
"$WORK_DIR/alias" create "$MOUNT_DIR/.background/installer.png" "$WORK_DIR/background.alias"
"$WORK_DIR/layout" store "$MOUNT_DIR" "$WORK_DIR/background.alias"
hdiutil detach "$MOUNT_DIR" >/dev/null
MOUNTED=0
"$WORK_DIR/layout" auto-open "$WORK_DIR/writable.dmg"
"$WORK_DIR/layout" check-auto-open "$WORK_DIR/writable.dmg"

hdiutil convert "$WORK_DIR/writable.dmg" -format UDZO -imagekey zlib-level=9 \
  -o "$WORK_DIR/final.dmg" >/dev/null
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  codesign --force --sign "$SIGNING_IDENTITY" --timestamp \
    --identifier io.github.hy0iu.YUANNotch.dmg "$WORK_DIR/final.dmg"
  codesign --verify --strict "$WORK_DIR/final.dmg"
fi
hdiutil verify "$WORK_DIR/final.dmg" >/dev/null
mv -f "$WORK_DIR/final.dmg" "$OUTPUT"
echo "Built $OUTPUT"
echo "Installer preview: $PREVIEW"
