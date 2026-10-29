#!/usr/bin/env bash
# Exercise note typography observation and teardown without showing a window.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/Sources/YUANNotch"
BUILD_ROOT="${TMPDIR:-/tmp}/yuannotch-note-font-probe"
mkdir -p "$BUILD_ROOT"
xcrun swiftc -swift-version 6 -parse-as-library \
  -o "$BUILD_ROOT/note-font-probe" \
  "$ROOT_DIR/Scripts/note-font-probe/main.swift" \
  "$SOURCE_DIR/AppTypography.swift" \
  "$SOURCE_DIR/AppSettingsStore.swift" \
  "$SOURCE_DIR/DrawerMode.swift" \
  "$SOURCE_DIR/NoteEditorTypography.swift" \
  "$SOURCE_DIR/EditorInteractionState.swift"
"$BUILD_ROOT/note-font-probe"
