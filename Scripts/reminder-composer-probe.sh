#!/usr/bin/env bash
#
# Builds and runs the reminder composer probe
# (Scripts/reminder-composer-probe/main.swift).
#
# The probe is compiled together with the shipping ReminderComposer.swift, so the
# due-date rules and the compose pipeline it checks are the ones the app runs. It
# also hosts a view with the drawer's own shape — one surface or the other, never
# both — and measures what a switch to the notes side does to the draft, because
# that is where the bug was.
#
# The panel's source is passed to the probe so it can assert the view declares
# none of the state the composer owns; a view-owned copy is how the bug returns.
#
# It needs no permissions and writes nothing. Exit status 0 means every check
# passed.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/Sources/YUANNotch"

BUILD_ROOT="${TMPDIR:-/tmp}/yuanotch-reminder-composer-probe"
EXECUTABLE="$BUILD_ROOT/composer-probe"

mkdir -p "$BUILD_ROOT"

echo "Compiling probe ..."
xcrun swiftc -swift-version 5 \
  -o "$EXECUTABLE" \
  "$ROOT_DIR/Scripts/reminder-composer-probe/main.swift" \
  "$SOURCE_DIR/ReminderComposer.swift" \
  "$SOURCE_DIR/FieldCaretFocus.swift"

echo ""

set +e
"$EXECUTABLE" "$SOURCE_DIR/RemindersPanelView.swift"
status=$?
set -e

exit "$status"
