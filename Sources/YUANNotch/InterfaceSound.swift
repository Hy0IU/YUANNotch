import AppKit

/// The sounds the app plays back to the user.
///
/// These are macOS's own, so they follow whatever output device and volume the
/// system is set to without any audio plumbing of ours — and they sound like the
/// rest of the system, which is the point of choosing them over our own.
@MainActor
enum InterfaceSound {
    /// Played when something actually lands in the file shelf.
    ///
    /// Swap the name to change it: `ls /System/Library/Sounds` lists what macOS
    /// ships (Tink, Pop, Glass, Ping, Morse, Purr, …). Resolved once, because
    /// `NSSound(named:)` reads the file and a drop is far too frequent a place
    /// to be doing file I/O.
    private static let stagedSound = NSSound(named: "Tink")

    /// Where macOS keeps the sound Finder plays when a file is moved to the
    /// Trash — the sound of *deleting* something, as opposed to emptying it
    /// (that one is `empty trash.aif`, a different and much shorter sound).
    ///
    /// It is outside `/System/Library/Sounds`, so it cannot be reached by name,
    /// and neither the path nor the file is a documented API. That is why the
    /// sound built from it is optional: if a future macOS moves it, the buttons
    /// go silent rather than misbehave.
    private static let moveToTrashSoundPath =
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/move to trash.aif"

    /// Played when contents are thrown away — the shelf emptied, or the editor.
    ///
    /// It is the move-to-Trash sound because that is the gesture these buttons
    /// perform: the content is deleted.
    private static let clearedSound = NSSound(
        contentsOfFile: moveToTrashSoundPath,
        byReference: true
    )

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
}
