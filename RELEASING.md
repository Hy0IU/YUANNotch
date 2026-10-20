# Releasing YUANNotch

YUANNotch checks GitHub's latest stable Release once per day. When it finds a
newer semantic version, it offers to open that Release in the user's browser;
the app never downloads or installs an update itself.

## Versioning

Use a semantic Git tag such as `v1.0.0`. Drafts and prereleases are not returned
by GitHub's `releases/latest` endpoint, so publish a normal Release when it
should become visible to the app.

Increase both values for each release:

- the semantic version is shown to users and compared with the GitHub tag;
- the positive integer build number is stored in `CFBundleVersion`.

## Build and publish

The release script builds without installing. By default, it creates a DMG with
the app, an Applications link and a Finder window that guides users to drag the
app into Applications. It also creates a SHA-256 checksum. ZIP is optional.

```bash
RELEASE_NOTES_FILE=/path/to/notes.md \
bash Scripts/make-release.sh 1.0.0 13
```

The script writes artifacts into `.release/`:

- `YUANNotch-1.0.0.dmg` and its `.sha256` checksum;
- the release notes as `YUANNotch-1.0.0.md` when supplied;
- ZIP and its checksum when `INCLUDE_ZIP=1`.

Before publishing, check the image and checksum:

```bash
bash Scripts/dmg-probe.sh .release/YUANNotch-1.0.0.dmg
(cd .release && shasum -a 256 -c YUANNotch-1.0.0.dmg.sha256)
```

Then create a normal GitHub Release with tag `v1.0.0`, use the release notes as
its description, and upload the DMG and checksum. The Finder layout preview is
a generated composite image, not a screenshot of Finder.

An ad-hoc signature and an installer DMG do not identify the developer to
Gatekeeper. Public releases that should open without the manual security
override need a Developer ID Application certificate and Apple notarization.

## Developer ID and notarization

Save App Store Connect credentials once with `notarytool`:

```bash
xcrun notarytool store-credentials YUANNotch
```

Then sign, notarize and staple the app and DMG during packaging:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE=YUANNotch \
RELEASE_NOTES_FILE=/path/to/notes.md \
bash Scripts/make-release.sh 1.0.0 13
```

For a release that also retains ZIP, set `INCLUDE_ZIP=1`.
