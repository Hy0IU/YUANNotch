#!/usr/bin/env bash
# Read-only validation of the final compressed DMG; never opens Finder or apps.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${1:-}"
if [[ ! -f "$IMAGE" ]]; then
  echo "usage: $0 <release.dmg>" >&2
  exit 1
fi
IMAGE="$(cd "$(dirname "$IMAGE")" && pwd)/$(basename "$IMAGE")"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/yuannotch-dmg-probe.XXXXXX")"
MOUNT_DIR="$WORK_DIR/remounted image"
MOUNTED=0
cleanup() {
  if [[ "$MOUNTED" == 1 ]] && ! hdiutil detach "$MOUNT_DIR" >/dev/null; then
    echo "Preserving mounted probe at $WORK_DIR" >&2
    return
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
mkdir -p "$MOUNT_DIR"
xcrun swiftc -swift-version 6 -o "$WORK_DIR/layout" "$ROOT_DIR/Scripts/dmg-layout/main.swift"
xcrun clang -Wno-deprecated-declarations -framework CoreServices \
  -o "$WORK_DIR/alias" "$ROOT_DIR/Scripts/dmg-layout/alias.c"
hdiutil verify "$IMAGE" >/dev/null
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$MOUNT_DIR" "$IMAGE" >/dev/null
MOUNTED=1
codesign --verify --deep --strict "$MOUNT_DIR/YUANNotch.app"
python3 "$ROOT_DIR/Scripts/dmg-layout/verify.py" "$MOUNT_DIR" "$WORK_DIR/background.alias"
"$WORK_DIR/alias" resolve "$WORK_DIR/background.alias" "$MOUNT_DIR/.background/installer.png"
"$WORK_DIR/layout" check-background "$MOUNT_DIR/.background/installer.png"
hdiutil detach "$MOUNT_DIR" >/dev/null
MOUNTED=0
hdiutil convert "$IMAGE" -format UDRW -o "$WORK_DIR/raw.dmg" >/dev/null
"$WORK_DIR/layout" check-auto-open "$WORK_DIR/raw.dmg"
echo "PASS compressed DMG integrity, app signature, and auto-open metadata"
