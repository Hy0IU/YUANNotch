#!/usr/bin/env bash
#
# Builds and runs the Apple Reminders probe (Scripts/reminders-v1-probe/main.swift).
#
# The probe is compiled together with the shipping
# Sources/YUANNotch/AppleRemindersService.swift, so it exercises the real
# service code. It needs its own signed .app bundle because EventKit access
# requires a bundle identifier plus NSRemindersFullAccessUsageDescription in
# the Info.plist — the same reason the app itself cannot be tested via
# `swift run`.
#
# macOS will show a Reminders permission dialog for the probe bundle on first
# run. That creates a separate entry in Privacy & Security from YUANNotch
# itself; delete the build directory printed at the end of the run to drop it
# (it lives under $TMPDIR, so it is not necessarily /tmp).
#
# The probe creates exactly one reminder and deletes it again.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROBE_SOURCE="$ROOT_DIR/Scripts/reminders-v1-probe/main.swift"
SERVICE_SOURCE="$ROOT_DIR/Sources/YUANNotch/AppleRemindersService.swift"
BUNDLE_ID="io.github.hy0iu.YUANNotch.reminders-probe"
EXECUTABLE_NAME="YUANNotchRemindersProbe"

BUILD_ROOT="${TMPDIR:-/tmp}/yuanotch-reminders-probe"
APP_BUNDLE="$BUILD_ROOT/$EXECUTABLE_NAME.app"

rm -rf "$BUILD_ROOT"
mkdir -p "$APP_BUNDLE/Contents/MacOS"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$EXECUTABLE_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>YUANNotch Reminders Probe</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSRemindersFullAccessUsageDescription</key>
  <string>Verifies that YUANNotch can read and write your reminders.</string>
</dict>
</plist>
PLIST

echo "Compiling probe ..."
xcrun swiftc -O \
  -o "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME" \
  "$PROBE_SOURCE" \
  "$SERVICE_SOURCE"

codesign --force --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true

echo "Running probe — macOS will ask for Reminders access, choose Allow."
echo ""

set +e
"$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
status=$?
set -e

echo ""
echo "Probe exit status: $status (0 = every check passed)"
echo "Bundle: $APP_BUNDLE"

exit "$status"
