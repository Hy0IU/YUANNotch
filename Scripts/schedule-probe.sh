#!/usr/bin/env bash
# Exercise real schedule models/store and render shipping SwiftUI views offscreen.
# Never requests permissions, writes EventKit data, or controls desktop input.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/Sources/YUANNotch"
BUILD_ROOT="${TMPDIR:-/tmp}/yuannotch-schedule-probe"
mkdir -p "$BUILD_ROOT"
xcrun swiftc -swift-version 6 -parse-as-library \
  "$ROOT_DIR/Scripts/schedule-probe/main.swift" \
  "$ROOT_DIR/Scripts/schedule-probe/AuthorizationScenarios.swift" \
  "$SOURCE_DIR/ScheduleModels.swift" \
  "$SOURCE_DIR/AppleRemindersService.swift" \
  "$SOURCE_DIR/AppleRemindersService+Schedule.swift" \
  "$SOURCE_DIR/ScheduleStore.swift" \
  "$SOURCE_DIR/SchedulePanelView.swift" \
  "$SOURCE_DIR/AppTypography.swift" \
  "$SOURCE_DIR/NotebookButtonStyles.swift" \
  -o "$BUILD_ROOT/schedule-probe"
"$BUILD_ROOT/schedule-probe" "$BUILD_ROOT"
