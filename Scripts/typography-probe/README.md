# Typography verification

The isolated preference probe uses its own temporary UserDefaults suite. Layout
probes render scratch data offscreen; they do not need the running app or access
to real reminders.

```bash
swift build
bash Scripts/typography-probe.sh
bash Scripts/settings-typography-probe.sh
bash Scripts/note-rendering-probe.sh
bash Scripts/note-font-probe.sh
bash Scripts/toolbar-layout-probe.sh
bash Scripts/daily-plan-layout-probe.sh
bash Scripts/reminder-edit-probe.sh --model-only --render-ui --render-input-ui
```

The note-rendering probe uses the MarkdownEngine artifacts from that debug build.
It checks that font changes preserve available undo history. Applying the undo
action itself remains a manual check: AppKit's unshown window did not apply its
reported Typing undo action even before a font change.

Manual checks on macOS 14+ after launching a development build:

- Change all three interface sizes in the minimum-size settings window. Check
  that every setting remains reachable by scrolling, and that interface and note
  previews use their separate settings.
- In a long note, change between 12, 15 and 24 pt at the start, middle and end.
  Check reading position, selection, caret, Markdown headings, nested lists,
  task boxes, code and embedded images. Undo should still undo the last text edit.
- Check Command-plus, Command-equals, Command-minus and Command-zero in the note;
  check that the same keys in settings and reminder fields do not change its size.
- Change size while composing Chinese marked text and, on macOS 15+, during
  Writing Tools. The new size should apply after the session ends without losing
  the pending text or requiring another settings change.
- Change modes and collapse/reopen a drawer with a pending font update. Check
  that the note and reminder drafts survive and that no window steals focus.
- With two displays and a detached drawer, change the setting and verify that
  every visible drawer and the floating timer update. Check 1x and 2x displays
  when available, long filenames, calendar durations and a timer above one hour.
