#!/usr/bin/env bash
# Hermetic checks for typography preferences. Uses an isolated defaults suite.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/Sources/YUANNotch"
BUILD_ROOT="${TMPDIR:-/tmp}/yuannotch-typography-probe"
mkdir -p "$BUILD_ROOT"

xcrun swiftc -swift-version 6 -parse-as-library \
  -o "$BUILD_ROOT/typography-probe" \
  "$ROOT_DIR/Scripts/typography-probe/main.swift" \
  "$SOURCE_DIR/AppTypography.swift" \
  "$SOURCE_DIR/AppSettingsStore.swift" \
  "$SOURCE_DIR/DrawerMode.swift"

"$BUILD_ROOT/typography-probe"
