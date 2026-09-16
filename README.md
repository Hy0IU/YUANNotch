# YUANNotch

A native macOS note app that lives at the top edge of your screen. Move the cursor to the notch/menu-bar area and it unfolds into a dark Markdown notebook.

Supports multiple displays — each screen gets its own trigger zone at the top-center.

## Quick Start

Requires macOS 14+ and Xcode Command Line Tools.

```bash
git clone <repo-url>
cd YUANNotch
bash ./Scripts/package-app.sh
```

The script will build the release binary, bundle it into `YUANNotch.app`, and copy it to `/Applications`. Launch from Launchpad or Spotlight.

On first launch, right-click the app in Finder and choose **Open** to bypass Gatekeeper.

## Exit

Quit from Activity Monitor, or run in Terminal:

```bash
killall YUANNotch
```

## Apple Reminders integration

YUANNotch can write the reminders you create onto your Mac's **Reminders** database through EventKit. When the selected list is an iCloud list, Apple syncs it to your iPhone, iPad and Apple Watch — the app runs no sync of its own and never talks to a server.

Enable it under **Settings → Integrations**. macOS asks for Reminders access once; the app must be in the foreground for that dialog to appear.

Two things worth knowing:

- **The app cannot report iCloud sync status.** Writing to the Reminders database succeeds even offline; whether a reminder has reached your other devices is decided by iCloud and is not readable. The UI therefore never claims anything is "synced".
- **A list stored only on this Mac will not reach your other devices.** This is flagged in the list picker as `this Mac only`. Pick an iCloud list if you want cross-device reminders.

### Development notes

The integration can only be tested from the packaged app — a bare `swift run` executable has no `Info.plist`, and macOS terminates the process outright when `NSRemindersFullAccessUsageDescription` is missing. Always verify through:

```bash
bash Scripts/package-app.sh
```

Because the app is ad-hoc signed, every rebuild changes its code signature and macOS treats it as a new app, prompting for Reminders access again. Use a stable identity to avoid that:

```bash
SIGN_IDENTITY="<your signing identity>" bash Scripts/package-app.sh
```

`Scripts/reminders-v1-probe.sh` builds a small signed probe app that exercises the shipping service code against your real reminders database (authorization, list enumeration, create/read/delete round-trip, and a check for whether reminders without a due date are returned by the incomplete query). It creates exactly one reminder and deletes it again. It is a development tool and is not part of the app.
