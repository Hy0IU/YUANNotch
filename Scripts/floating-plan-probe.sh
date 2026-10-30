#!/usr/bin/env bash
# Render floating timer and drawer pin states offscreen; never control desktop input.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/Sources/YUANNotch"
BUILD_ROOT="${TMPDIR:-/tmp}/yuannotch-floating-plan-probe"
mkdir -p "$BUILD_ROOT"
xcrun swiftc -swift-version 6 -parse-as-library \
  -o "$BUILD_ROOT/floating-plan-probe" \
  "$ROOT_DIR/Scripts/floating-plan-probe/main.swift" \
  "$SOURCE_DIR/AppTypography.swift" \
  "$SOURCE_DIR/AppSettingsStore.swift" \
  "$SOURCE_DIR/DrawerMode.swift" \
  "$SOURCE_DIR/PanelWindowTypes.swift" \
  "$SOURCE_DIR/DailyPlanModels.swift" \
  "$SOURCE_DIR/DailyPlanEngine.swift" \
  "$SOURCE_DIR/DailyPlanPersistence.swift" \
  "$SOURCE_DIR/DailyPlanStore.swift" \
  "$SOURCE_DIR/DailyPlansPanelView.swift" \
  "$SOURCE_DIR/DailyPlanHistoryView.swift" \
  "$SOURCE_DIR/DailyPlanTimeEditor.swift" \
  "$SOURCE_DIR/NotebookButtonStyles.swift" \
  "$SOURCE_DIR/FloatingPlanWindowController.swift"
"$BUILD_ROOT/floating-plan-probe" "$BUILD_ROOT"
