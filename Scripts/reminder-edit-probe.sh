#!/usr/bin/env bash
#
# Builds and runs the reminder editing probe
# (Scripts/reminder-edit-probe/main.swift).
#
# The probe is compiled together with the shipping ReminderStore.swift (and the
# service it talks to), driven through a stand-in RemindersServing: the same seam
# ReminderStore was designed around, so the editing flow is exercised without
# EventKit, without permissions and without touching the user's reminders.
#
# It checks what a commit is willing to write, the begin → draft → commit flow
# (the service receives update(id:title:due:) with the title only, the row shows
# the new title at once, the edit closes), that a restated or cleared draft writes
# nothing, that a failed write reverts the optimistic title by re-reading, that a
# refresh which loses the row ends the edit, and that a pending local row offers
# no edit.
#
# Hermetic: the write queue lives in a scratch file, and the two UserDefaults keys
# the store touches are saved and restored around the run. Exit status 0 means
# every check passed.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/Sources/YUANNotch"

BUILD_ROOT="${TMPDIR:-/tmp}/yuanotch-reminder-edit-probe"
EXECUTABLE="$BUILD_ROOT/reminder-edit-probe"

mkdir -p "$BUILD_ROOT"

echo "Compiling probe ..."
xcrun swiftc -swift-version 5 \
  -o "$EXECUTABLE" \
  "$ROOT_DIR/Scripts/reminder-edit-probe/main.swift" \
  "$SOURCE_DIR/ReminderStore.swift" \
  "$SOURCE_DIR/ReminderComposer.swift" \
  "$SOURCE_DIR/AppleRemindersService.swift" \
  "$SOURCE_DIR/AppSettingsStore.swift" \
  "$SOURCE_DIR/DrawerMode.swift" \
  "$SOURCE_DIR/NotchGeometry.swift"

echo ""

set +e
"$EXECUTABLE"
status=$?
set -e

exit "$status"
