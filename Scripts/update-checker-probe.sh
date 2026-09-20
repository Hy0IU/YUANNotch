#!/usr/bin/env bash
#
# Compiles the shipping version parser with a compact semantic-version table.
# Exit status 0 means every comparison used by the GitHub update checker passed.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${TMPDIR:-/tmp}/yuannotch-update-checker-probe"
EXECUTABLE="$BUILD_ROOT/update-checker-probe"

mkdir -p "$BUILD_ROOT"

echo "Compiling probe ..."
xcrun swiftc -swift-version 6 \
  -o "$EXECUTABLE" \
  "$ROOT_DIR/Scripts/update-checker-probe/main.swift" \
  "$ROOT_DIR/Sources/YUANNotch/UpdateChecker.swift"

echo ""
"$EXECUTABLE"
