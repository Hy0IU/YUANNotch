#!/usr/bin/env bash
#
# Builds and runs the Daily Plans timing and persistence probe.
# The probe compiles the shipping models, engine, persistence and store, then
# drives them with a fixed clock. It writes only to a unique temporary folder.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/Sources/YUANNotch"

BUILD_ROOT="${TMPDIR:-/tmp}/yuanotch-daily-plan-probe"
EXECUTABLE="$BUILD_ROOT/daily-plan-probe"

mkdir -p "$BUILD_ROOT"

echo "Compiling probe ..."
xcrun swiftc -swift-version 6 -parse-as-library \
  -o "$EXECUTABLE" \
  "$ROOT_DIR/Scripts/daily-plan-probe/main.swift" \
  "$SOURCE_DIR/DailyPlanModels.swift" \
  "$SOURCE_DIR/DailyPlanEngine.swift" \
  "$SOURCE_DIR/DailyPlanPersistence.swift" \
  "$SOURCE_DIR/DailyPlanStore.swift"

echo ""
"$EXECUTABLE"
