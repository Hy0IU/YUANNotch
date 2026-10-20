#!/usr/bin/env bash
# Render the shipping focus-time editor offscreen, using scratch data only.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/Sources/YUANNotch"
BUILD_ROOT="${TMPDIR:-/tmp}/yuannotch-daily-plan-layout-probe"
mkdir -p "$BUILD_ROOT"

xcrun swiftc -swift-version 6 -parse-as-library \
  -o "$BUILD_ROOT/layout-probe" \
  "$ROOT_DIR/Scripts/daily-plan-layout-probe/main.swift" \
  "$SOURCE_DIR/DailyPlanModels.swift" \
  "$SOURCE_DIR/DailyPlanEngine.swift" \
  "$SOURCE_DIR/DailyPlanPersistence.swift" \
  "$SOURCE_DIR/DailyPlanStore.swift" \
  "$SOURCE_DIR/DailyPlansPanelView.swift" \
  "$SOURCE_DIR/DailyPlanHistoryView.swift" \
  "$SOURCE_DIR/DailyPlanTimeEditor.swift" \
  "$SOURCE_DIR/NotebookButtonStyles.swift"

"$BUILD_ROOT/layout-probe" "$BUILD_ROOT"
