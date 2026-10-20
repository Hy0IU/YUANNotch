#!/usr/bin/env bash
# Pure fixed-clock checks. No EventKit access or foreground windows.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/Sources/YUANNotch"
BUILD_ROOT="${TMPDIR:-/tmp}/yuannotch-reminder-input-probe"
mkdir -p "$BUILD_ROOT"
xcrun swiftc -swift-version 6 -parse-as-library \
  -o "$BUILD_ROOT/input-probe" \
  "$ROOT_DIR/Scripts/reminder-input-probe/main.swift" \
  "$SOURCE_DIR/ReminderInputParser.swift" \
  "$SOURCE_DIR/ReminderComposer.swift"
"$BUILD_ROOT/input-probe"
