import AppKit

/// The sound the shelf makes when a file lands in it.
///
/// `NSSound(named:)` resolves against the system alert sounds, so this plays
/// through whatever output device and volume macOS is set to without any audio
/// plumbing of our own.
@MainActor
enum FileShelfSound {
    /// Swap the name to change the sound: `ls /System/Library/Sounds` lists
    /// what macOS ships (Tink, Pop, Glass, Ping, Morse, Purr, …).
    ///
    /// Resolved once. `NSSound(named:)` reads the file, and a drop is far too
    /// frequent a place to be doing file I/O.
    private static let dropSound = NSSound(named: "Tink")

    /// Call once per drop that added something — not once per file, and not at
    /// all when everything in the drop was already staged.
    static func playDrop() {
        // `play` restarts a sound that is still playing, which is what two
        // drops arriving back to back should do.
        dropSound?.play()
    }
}
