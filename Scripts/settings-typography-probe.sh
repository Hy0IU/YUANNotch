#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/Sources/YUANNotch"
TEMP_ROOT="${TMPDIR:-/tmp}"
TEMP_ROOT="${TEMP_ROOT%/}"
BUILD_ROOT="$TEMP_ROOT/yuanotch-settings-typography-probe"
EXTRACTED="$BUILD_ROOT/appearance-settings.swift"
COMBINED="$BUILD_ROOT/main.swift"
EXECUTABLE="$BUILD_ROOT/settings-typography-probe"

mkdir -p "$BUILD_ROOT"

# Compile the shipping Appearance form and numeric controls in isolation. The
# neighboring settings tabs and app services are intentionally left out.
awk '
  /^\/\/ MARK: - Appearance$/ { include = 1 }
  /^\/\/ MARK: - Trigger$/ { include = 0 }
  include { print }
' "$SOURCE_DIR/SettingsWindowController.swift" > "$EXTRACTED"
cat "$EXTRACTED" "$ROOT_DIR/Scripts/settings-typography-probe/main.swift" > "$COMBINED"

echo "Compiling offscreen Appearance probe ..."
xcrun swiftc -swift-version 5 \
  -o "$EXECUTABLE" \
  "$COMBINED" \
  "$SOURCE_DIR/AppTypography.swift" \
  "$SOURCE_DIR/AppSettingsStore.swift" \
  "$SOURCE_DIR/DrawerMode.swift"

echo ""
"$EXECUTABLE" "$BUILD_ROOT"
