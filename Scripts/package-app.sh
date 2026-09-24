#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/YUANNotch.app"
APPLICATIONS_APP_DIR="/Applications/YUANNotch.app"
LEGACY_APPLICATIONS_APP_DIR="/Applications/NotchNotes.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
SOURCE_ICON="$ROOT_DIR/Resources/AppIcon.png"
RESOURCE_BUNDLE_NAME="YUANNotch_YUANNotch.bundle"
RESOURCE_BUNDLE="$ROOT_DIR/.build/release/$RESOURCE_BUNDLE_NAME"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP_VERSION="${APP_VERSION:-0.3.2}"
BUILD_NUMBER="${BUILD_NUMBER:-7}"
INSTALL_APP="${INSTALL_APP:-1}"

# Hardened Runtime and a secure timestamp belong on Developer ID releases.
# Keep local ad-hoc builds free of distribution-only signing options.
sign_component() {
  if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" "$@"
  else
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$@"
  fi
}

if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "error: APP_VERSION must be a semantic version (got '$APP_VERSION')" >&2
  exit 1
fi
if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: BUILD_NUMBER must be a positive integer (got '$BUILD_NUMBER')" >&2
  exit 1
fi

cd "$ROOT_DIR"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp ".build/release/YUANNotch" "$MACOS_DIR/YUANNotch"

# The app reads its mark from a resource bundle that sits beside the executable
# (see AppGlyph.resourceBundle). Without this copy the packaged app still runs on
# a machine that happens to keep its build tree — SwiftPM's lookup falls back to
# the build-time path — and crashes anywhere else, so fail here instead.
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
  echo "error: swift build did not produce $RESOURCE_BUNDLE_NAME" >&2
  exit 1
fi

# Ship it as a bundle that is actually well formed. A directory whose name ends
# in `.bundle` is a bundle to macOS, and `codesign` refuses to sign one that has
# no `Contents/Info.plist` — it rejects the whole app with "bundle format
# unrecognized, invalid, or unsuitable". SwiftPM emits the payload flat, so give
# it the structure the name promises; `Bundle(url:)` resolves `Glyph/` under
# `Contents/Resources/`, which is where AppGlyph looks.
RESOURCE_BUNDLE_DEST="$MACOS_DIR/$RESOURCE_BUNDLE_NAME"
mkdir -p "$RESOURCE_BUNDLE_DEST/Contents/Resources"
for item in "$RESOURCE_BUNDLE"/*; do
  cp -R "$item" "$RESOURCE_BUNDLE_DEST/Contents/Resources/"
done
cat > "$RESOURCE_BUNDLE_DEST/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>io.github.hy0iu.YUANNotch.resources</string>
  <key>CFBundleName</key>
  <string>YUANNotch_YUANNotch</string>
  <key>CFBundlePackageType</key>
  <string>BNDL</string>
</dict>
</plist>
PLIST

if [[ -f "$SOURCE_ICON" ]]; then
  TMP_DIR="$(mktemp -d)"
  ICONSET_DIR="$TMP_DIR/AppIcon.iconset"
  mkdir -p "$ICONSET_DIR"

  sips -z 16 16 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
  sips -z 32 32 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
  sips -z 64 64 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
  sips -z 256 256 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
  sips -z 512 512 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null
  iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"
  rm -rf "$TMP_DIR"
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>YUANNotch</string>
  <key>CFBundleIdentifier</key>
  <string>io.github.hy0iu.YUANNotch</string>
  <key>CFBundleName</key>
  <string>YUANNotch</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSRemindersFullAccessUsageDescription</key>
  <string>YUANNotch writes the reminders you create onto your Mac's Reminders database so Apple can sync them to your other devices.</string>
</dict>
</plist>
PLIST

sign_component "$MACOS_DIR/$RESOURCE_BUNDLE_NAME"
sign_component "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

if [[ "$INSTALL_APP" == "1" ]]; then
  rm -rf "$APPLICATIONS_APP_DIR"
  rm -rf "$LEGACY_APPLICATIONS_APP_DIR"
  cp -R "$APP_DIR" "$APPLICATIONS_APP_DIR"
fi

echo "Built $APP_DIR"
if [[ "$INSTALL_APP" == "1" ]]; then
  echo "Copied $APPLICATIONS_APP_DIR"
fi
