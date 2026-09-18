#!/usr/bin/env bash
#
# Builds and runs the notebook toolbar probe (Scripts/toolbar-layout-probe/main.swift).
#
# The probe is compiled together with the shipping toolbar sources — the toolbar
# row, the tab pager, the mode toggle, the wheel-driven strip and the layout that
# decides their widths — so what it measures is what the app draws, not a copy.
#
# It checks that a notebook with any number of tabs lays out inside the width the
# drawer gives the row: the strip is never squeezed below what it needs, nothing
# in the row overlaps anything else, the mode toggle costs what the layout says,
# one wheel notch slides one dot and the ends clamp.
#
# It needs no permissions and writes nothing. Exit status 0 means every check
# passed.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/Sources/YUANNotch"

BUILD_ROOT="${TMPDIR:-/tmp}/yuanotch-toolbar-probe"
EXECUTABLE="$BUILD_ROOT/notebook-toolbar-probe"

mkdir -p "$BUILD_ROOT"

echo "Compiling probe ..."
xcrun swiftc -swift-version 5 \
  -o "$EXECUTABLE" \
  "$ROOT_DIR/Scripts/toolbar-layout-probe/main.swift" \
  "$SOURCE_DIR/NotchGeometry.swift" \
  "$SOURCE_DIR/DrawerMode.swift" \
  "$SOURCE_DIR/DrawerModeToggle.swift" \
  "$SOURCE_DIR/NotebookButtonStyles.swift" \
  "$SOURCE_DIR/NotebookToolbar.swift" \
  "$SOURCE_DIR/TabPagerControl.swift" \
  "$SOURCE_DIR/HorizontalWheelScroll.swift"

echo ""

set +e
"$EXECUTABLE"
status=$?
set -e

exit "$status"
