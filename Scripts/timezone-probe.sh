#!/usr/bin/env bash
# Fixed-clock, explicit-zone checks only. No UI, EventKit reads/writes or OS timezone changes.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/Sources/YUANNotch"
BUILD_ROOT="${TMPDIR:-/tmp}/yuannotch-timezone-probe"
mkdir -p "$BUILD_ROOT"
xcrun swiftc -swift-version 6 -parse-as-library \
  "$ROOT_DIR/Scripts/timezone-probe/main.swift" \
  "$SOURCE_DIR/ReminderComposer.swift" \
  "$SOURCE_DIR/ReminderInputParser.swift" \
  "$SOURCE_DIR/AppleRemindersService.swift" \
  "$SOURCE_DIR/AppleRemindersService+Schedule.swift" \
  "$SOURCE_DIR/ScheduleModels.swift" \
  "$SOURCE_DIR/DailyPlanModels.swift" \
  "$SOURCE_DIR/DailyPlanEngine.swift" \
  "$SOURCE_DIR/DailyPlanPersistence.swift" \
  "$SOURCE_DIR/DailyPlanStore.swift" \
  -o "$BUILD_ROOT/timezone-probe"
"$BUILD_ROOT/timezone-probe"
