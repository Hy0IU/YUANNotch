# Repository Guidelines

## Project Structure & Module Organization

YUANNotch is a Swift Package Manager macOS 14+ menu-bar application. Application code lives in `Sources/YUANNotch/`: `main.swift` starts the accessory app, `AppDelegate.swift` wires menus and lifecycle, `NotchPanelController.swift` manages per-display panels, and the SwiftUI views and stores are split into focused files such as `NotebookView.swift` and `NoteStore.swift`. The local Markdown dependency is maintained under `Vendor/swift-markdown-engine/`; avoid modifying vendored code unless the change is intentionally upstreamable. App artwork is in `Resources/`, while `docs/` contains website and downloadable release assets. Packaging logic lives in `Scripts/package-app.sh`.

## Build, Test, and Development Commands

- `swift build`: compile the debug executable and resolve local package dependencies.
- `swift run YUANNotch`: build and launch the app from the terminal.
- `swift build -c release`: produce the optimized binary used for distribution.
- `swift test`: run all SwiftPM tests once test targets are added; currently the package has no test target.
- `bash Scripts/package-app.sh`: create, ad-hoc sign, and copy `YUANNotch.app` to `/Applications`. This script replaces existing YUANNotch and legacy NotchNotes app bundles, so use it only when installation is intended. Set `SIGN_IDENTITY` to override ad-hoc signing.

## Coding Style & Naming Conventions

Follow standard Swift API design guidelines and the existing four-space indentation. Use `UpperCamelCase` for types, `lowerCamelCase` for methods and properties, and descriptive filenames matching their primary type. Keep UI-bound controllers and observable stores `@MainActor`. Prefer small SwiftUI views, private helpers, early `guard` exits, and extensions when separating a type by responsibility. No formatter or linter is configured; keep changes consistent with surrounding code and ensure `swift build` is warning-free.

## Testing Guidelines

Add tests under `Tests/YUANNotchTests/` and declare a `.testTarget` in `Package.swift`. Name XCTest files `<Type>Tests.swift` and methods `test_<behavior>()`. Prioritize persistence migrations, selection/range clamping, notch geometry, file-shelf operations, and multi-display state transitions. For AppKit behavior that is difficult to automate, document manual checks on macOS 14+, including activation, collapse/expand animation, and display handoff.

## Commit & Pull Request Guidelines

Recent history uses concise imperative subjects, sometimes with Conventional Commit prefixes such as `fix:`, `feat:`, `refactor:`, or `chore:`. Keep each commit focused. Pull requests should explain the user-visible effect, testing performed, and any migration or packaging impact; link relevant issues and include screenshots or a short recording for UI changes. Do not commit `.build/`, `YUANNotch.app/`, `DerivedData/`, or local runtime data.
