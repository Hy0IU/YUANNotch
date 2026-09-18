# Repository Guidelines

## Project Structure & Module Organization

YUANNotch is a Swift Package Manager macOS 14+ menu-bar application. Application code lives in `Sources/YUANNotch/`: `main.swift` starts the accessory app, `AppDelegate.swift` wires menus and lifecycle, `NotchPanelController.swift` manages per-display panels, and the SwiftUI views and stores are split into focused files such as `NotebookView.swift` and `NoteStore.swift`. The local Markdown dependency is maintained under `Vendor/swift-markdown-engine/`; avoid modifying vendored code unless the change is intentionally upstreamable. App artwork is in `Resources/`: `AppIcon.png` is the master for the Finder icon, `Glyph.png` the master for the app mark. Packaging logic lives in `Scripts/package-app.sh`.

## Note storage

`Sources/YUANNotch/NotesLibrary.swift` owns the notes folder and the Markdown files inside it: one file per page, named after the page's first line, plus an `index.json` holding only what a file cannot carry (tab order, the active tab, caret positions). `Sources/YUANNotch/LegacyNotesSource.swift` reads the pre-file storage — first `workspace.json`, then the `UserDefaults` blobs — and is asked exactly once, guarded by `yuanNotch.didMigrateNotesIntoFiles`.

The folder is fixed, not chosen at launch: `NotesLibrary.directoryAtLaunch()` returns the recorded folder or the app's own support folder and never asks anything. Changing it is a deliberate act from the settings page (`setDirectory`, `copyNotes`), so a stored folder that has gone missing is recreated rather than silently replaced.

The files are the notes and the index is a cache. Three rules follow, and none of them is a preference:

- A Markdown file the app did not write is never modified. New pages take a numbered name instead of a name already on disk.
- A file the app cannot read is never written over; it is moved aside as `<name>.unreadable-<timestamp>.md` if a write is unavoidable.
- Deleting a page moves its file to the system Trash, never `removeItem`.

## Images

`Sources/YUANNotch/LocalImageStore.swift` writes embedded images to `<notes folder>/attachments/`, one file per image, named after the name it arrived with (Finder-style numbering on a collision). A note refers to one as `![[attachments/<name>.png]]`.

That reference carries no identifier on purpose. Obsidian reads everything after `|` in an image embed as a size rather than as a label, so an app-private id cannot travel inside it — and a reference only this app can resolve is worth less than a file name both tools understand. Two consequences follow:

- The file name is the image's identity. Renaming one in Finder breaks the note that embeds it; re-linking is not attempted, unlike the notes, which can be found again by title.
- The images are inside the notes folder, so anything that moves that folder must carry `attachments/` with it — `NotesLibrary.copyNotes` is where that happens, and a folder switch that skipped it would leave every embed broken.

Names are constrained by the reference format rather than by the file system: Obsidian documents `# | ^ : %% [[ ]]` as characters that "may not work as a link", so `sanitizedDisplayName` replaces them instead of writing a reference that resolves to nothing.

## The app mark

`Sources/YUANNotch/AppGlyph.swift` is the single source of truth for how the mark is *loaded and tinted* — no call site names the artwork, its point size, or its tint. The mark's *geometry* is the single source in `Scripts/make-glyph/main.swift`, run through `Scripts/make-glyph.sh`.

The mark is a monoline drawing built from five primitives, so its stroke weight, the inner ring's radius and its height are each one number in that file. The tool draws the geometry at each target size and writes all three tracked PNGs — `Resources/Glyph.png` (989 px, the reference rendering), `Sources/YUANNotch/Glyph/Glyph.png` (18 px) and `Glyph@2x.png` (36 px) — monochrome on transparent, with the mark's outer edge pinned so it always fills 16 of the 18 points. The reps are rendered **at their own size**, not resampled from the master: downscaling 989 px by 29x erodes the strokes, and at 18/36 px a native render puts more of each stroke on full pixels.

It prints every clearance between parts before writing anything, so a weight change can be judged before it is drawn. The two dashes run out of room first — at the current 1.25 pt they are what constrains the weight, which is why they rise with the inner ring rather than staying put.

`AppGlyph` deliberately does not use `Bundle.module`. SwiftPM generates its lookup as `Bundle.main.bundleURL + "<name>.bundle"`, which inside a `.app` resolves to the bundle root — a location macOS allows only `Contents` in. The code looks beside the executable instead, so `Scripts/package-app.sh` must copy `YUANNotch_YUANNotch.bundle` into `Contents/MacOS/`, and ship it as a well-formed bundle (`Contents/Info.plist` plus the payload under `Contents/Resources/`) or `codesign` rejects the whole app. Without that copy the app still launches wherever its build tree survives, and crashes elsewhere.

## Build, Test, and Development Commands

- `swift build`: compile the debug executable and resolve local package dependencies.
- `swift run YUANNotch`: build and launch the app from the terminal.
- `swift build -c release`: produce the optimized binary used for distribution.
- `swift test`: run all SwiftPM tests once test targets are added; currently the package has no test target.
- `bash Scripts/make-glyph.sh`: regenerate the app mark's three PNGs from the geometry in `Scripts/make-glyph/main.swift`. Pass `--baseline --out-dir <dir>` to re-render the pre-existing weight, which is how the fitted geometry is re-verified.
- `bash Scripts/package-app.sh`: create, ad-hoc sign, and copy `YUANNotch.app` to `/Applications`. This script replaces existing YUANNotch and legacy NotchNotes app bundles, so use it only when installation is intended. Set `SIGN_IDENTITY` to override ad-hoc signing. It also ships the SwiftPM resource bundle holding the app mark, and aborts if `swift build` did not produce one.

## Coding Style & Naming Conventions

Follow standard Swift API design guidelines and the existing four-space indentation. Use `UpperCamelCase` for types, `lowerCamelCase` for methods and properties, and descriptive filenames matching their primary type. Keep UI-bound controllers and observable stores `@MainActor`. Prefer small SwiftUI views, private helpers, early `guard` exits, and extensions when separating a type by responsibility. No formatter or linter is configured; keep changes consistent with surrounding code and ensure `swift build` is warning-free.

## Testing Guidelines

Add tests under `Tests/YUANNotchTests/` and declare a `.testTarget` in `Package.swift`. Name XCTest files `<Type>Tests.swift` and methods `test_<behavior>()`. Prioritize persistence migrations, selection/range clamping, notch geometry, file-shelf operations, and multi-display state transitions. For AppKit behavior that is difficult to automate, document manual checks on macOS 14+, including activation, collapse/expand animation, and display handoff.

There is no test target yet, and `YUANNotch` is an executable target with top-level code, so nothing can be `@testable import`ed. Until that changes, storage logic is exercised by a standalone harness compiled from these sources — which is why the naming rules in `NotesLibrary` are `static` and free of instance state, and why `NotesLibrary` takes its folder as an `init` argument rather than resolving it internally. Keep both properties when editing that file.

Layout is exercised the same way: `bash Scripts/toolbar-layout-probe.sh` compiles `NotebookToolbar`, `TabPagerControl`, `DrawerModeToggle`, `HorizontalWheelScroll` and `NotebookToolbarLayout` with stand-ins for the store, then measures the rendered row at every drawer width and tab count. It fails if the strip's `NSView` is narrower than the layout asked for (the row used to squeeze it, and the dots painted over the buttons beside it), if any two parts of the row intersect, if the widths `NotebookToolbarLayout` reserves for the mode toggle drift from the real control, or if a wheel notch fails to slide exactly one dot. That is why the row lives in its own file and why the layout states the row's parts as numbers: both files are compiled by that probe, and a change that makes them unmeasurable there is a change that cannot be checked.

State that has to outlive a view is checked from both ends: `bash Scripts/reminder-composer-probe.sh` compiles `ReminderComposer.swift` and runs the due-date table against a fixed clock, the compose pipeline, and a hosted view with the drawer's own shape — one surface or the other, never both — measuring what a switch to the notes side does to a half-typed reminder. It also reads `RemindersPanelView.swift` to assert the view declares none of the state the composer owns, because a view-owned copy is how that bug returns. The rule behind both probes is the same one: anything the drawer can throw away must not own anything the user would miss — which is why the reminders panel reports only its visible lifetime and its draft belongs to the store.

## Commit & Pull Request Guidelines

Recent history uses concise imperative subjects, sometimes with Conventional Commit prefixes such as `fix:`, `feat:`, `refactor:`, or `chore:`. Keep each commit focused. Pull requests should explain the user-visible effect, testing performed, and any migration or packaging impact; link relevant issues and include screenshots or a short recording for UI changes. Do not commit `.build/`, `YUANNotch.app/`, `DerivedData/`, or local runtime data.
