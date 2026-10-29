#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEBUG_DIR="$ROOT_DIR/.build/debug"
MODULE_DIR="$DEBUG_DIR/Modules"
OBJECT_DIR="$DEBUG_DIR/MarkdownEngine.build"
SCRIPT_DIR="$ROOT_DIR/Scripts/note-rendering-probe"
TEMP_ROOT="${TMPDIR:-/tmp}"
TEMP_ROOT="${TEMP_ROOT%/}"
OUTPUT_DIR="$TEMP_ROOT/yuanotch-note-rendering-probe"
EXECUTABLE="$OUTPUT_DIR/note-rendering-probe"
ENGINE_OBJECTS=("$OBJECT_DIR/"*.swift.o)

if [[ ! -f "$MODULE_DIR/MarkdownEngine.swiftmodule" || ! -e "${ENGINE_OBJECTS[0]}" ]]; then
  echo "MarkdownEngine's prebuilt module or object files are missing from $DEBUG_DIR; run 'swift build' first." >&2
  exit 2
fi

mkdir -p "$OUTPUT_DIR"
echo "Compiling against the existing MarkdownEngine build artifacts ..."
xcrun swiftc -swift-version 5 \
  -I "$MODULE_DIR" \
  -o "$EXECUTABLE" \
  "$SCRIPT_DIR/main.swift" \
  "${ENGINE_OBJECTS[@]}"

echo ""
"$EXECUTABLE" "$OUTPUT_DIR"
