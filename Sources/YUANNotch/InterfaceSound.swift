import AppKit

/// The sounds the app plays back to the user.
///
/// Most are macOS's own, so they follow the system's output device and volume.
/// The focus completion cue is bundled with the app so it stays consistent.
@MainActor
enum InterfaceSound {
    /// Played when something actually lands in the file shelf.
    ///
    /// Swap the name to change it: `ls /System/Library/Sounds` lists what macOS
    /// ships (Tink, Pop, Glass, Ping, Morse, Purr, …). Resolved once, because
    /// `NSSound(named:)` reads the file and a drop is far too frequent a place
    /// to be doing file I/O.
    private static let stagedSound = NSSound(named: "Tink")
    private static let focusCompletedSound = loadFocusCompletedSound()

    /// Where macOS keeps the sound of something going *into* the Trash: the one
    /// the Dock plays as an item is dropped on it (0.50 s).
    ///
    /// It is not the only candidate macOS ships for this gesture — the Finder's
    /// "Move to Trash" is 2.19 s and its "Empty Trash" 0.83 s, both under
    /// `SystemSounds/finder/`. The Dock's is the one that was chosen, by ear
    /// against the other two, because it reads as the thing going in rather than
    /// as a longer ceremony around it.
    ///
    /// It is outside `/System/Library/Sounds`, so it cannot be reached by name,
    /// and neither the path nor the file is a documented API. That is why the
    /// sound built from it is optional: if a future macOS moves it, the buttons
    /// go silent rather than misbehave.
    private static let trashSoundPath =
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/drag to trash.aif"

    /// Played when contents are thrown away — the shelf emptied, or the editor.
    ///
    /// It is the into-the-Trash sound because that is the gesture these buttons
    /// perform: the content is deleted.
    private static let clearedSound = NSSound(
        contentsOfFile: trashSoundPath,
        byReference: true
    )

    /// Loads the approved focus cue from the SwiftPM resource bundle. The
    /// package script places the same bundle beside the executable in the app.
    private static func loadFocusCompletedSound() -> NSSound? {
        let executableURL = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let bundleURL = executableURL.deletingLastPathComponent()
            .appendingPathComponent("YUANNotch_YUANNotch.bundle")

        guard let bundle = Bundle(url: bundleURL),
              let soundURL = bundle.url(
                forResource: "PlanComplete",
                withExtension: "wav",
                subdirectory: "Sounds"
              )
        else {
            return NSSound(named: "Glass")
        }

        return NSSound(contentsOf: soundURL, byReference: false)
            ?? NSSound(named: "Glass")
    }

    /// A file landed in the shelf.
    static func fileStaged() {
        // `play` restarts a sound that is still playing, which is what two drops
        // arriving back to back should do.
        stagedSound?.play()
    }

    /// Contents were cleared. Only call this when something was actually there:
    /// a clear that removed nothing has nothing to confirm.
    static func cleared() {
        clearedSound?.play()
    }

    /// A focus or break interval reached its boundary.
    static func focusPhaseCompleted() {
        focusCompletedSound?.play()
    }
}
