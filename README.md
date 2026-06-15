# NotchNotes

A native macOS note app that lives at the top edge of your screen. Move the cursor to the notch/menu-bar area and it unfolds into a dark Markdown notebook.

Supports multiple displays — each screen gets its own trigger zone at the top-center.

## Quick Start

Requires macOS 14+ and Xcode Command Line Tools.

```bash
git clone <repo-url>
cd NotchNotes
bash ./Scripts/package-app.sh
```

The script will build the release binary, bundle it into `NotchNotes.app`, and copy it to `/Applications`. Launch from Launchpad or Spotlight.

On first launch, right-click the app in Finder and choose **Open** to bypass Gatekeeper.

## Exit

Quit from Activity Monitor, or run in Terminal:

```bash
killall NotchNotes
```
