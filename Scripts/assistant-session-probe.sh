#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Sources/YUANNotch"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/assistant-session.XXXXXX")"
xcrun swiftc -swift-version 6 -parse-as-library -o "$OUT/session" \
  "$ROOT/Scripts/assistant-session-probe/main.swift" "$SRC/ScheduleModels.swift" \
  "$SRC/AssistantProposal.swift" "$SRC/AssistantReplyPreview.swift" \
  "$SRC/AssistantSession.swift" "$SRC/AssistantPanelView.swift" "$SRC/AssistantComposerInput.swift"
"$OUT/session" "$OUT/panel.png"
printf 'Panel render: %s\n' "$OUT/panel.png"
