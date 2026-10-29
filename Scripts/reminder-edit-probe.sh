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
# Checks title and date edits, exact timestamp preservation, clearing dates and
# alerts, repeat saves, date grouping, cancellation, and failure/retry behavior.
# --model-only skips the foreground text-focus check; --render-ui additionally
# renders the real date editor offscreen at three widths in all three states.
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
  "$SOURCE_DIR/AppTypography.swift" \
  "$SOURCE_DIR/ReminderOrdering.swift" \
  "$SOURCE_DIR/ReminderStore.swift" \
  "$SOURCE_DIR/ReminderComposer.swift" \
  "$SOURCE_DIR/ReminderInputParser.swift" \
  "$SOURCE_DIR/FieldCaretFocus.swift" \
  "$SOURCE_DIR/PanelWindowTypes.swift" \
  "$SOURCE_DIR/AppleRemindersService.swift" \
  "$SOURCE_DIR/AppSettingsStore.swift" \
  "$SOURCE_DIR/DrawerMode.swift" \
  "$SOURCE_DIR/NotchGeometry.swift" \
  "$SOURCE_DIR/ReminderDueEditor.swift" \
  "$SOURCE_DIR/RemindersPanelView.swift" \
  "$SOURCE_DIR/ReminderInputPreview.swift" \
  "$SOURCE_DIR/ReminderListCapsule.swift" \
  "$SOURCE_DIR/NotebookButtonStyles.swift"

echo ""

set +e
"$EXECUTABLE" "$@"
status=$?
set -e

exit "$status"
