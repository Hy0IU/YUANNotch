# Releasing YUANNotch

YUANNotch checks GitHub's latest stable Release once per day. When it finds a
newer semantic version, it offers to open that Release in the user's browser;
the app never downloads or installs an update itself.

## Versioning

Use a semantic Git tag such as `v0.2.0`. Drafts and prereleases are not returned
by GitHub's `releases/latest` endpoint, so publish a normal Release when it
should become visible to the app.

Both values passed to the release script should increase:

- the semantic version is shown to users and compared with the GitHub tag;
- the positive integer build number is stored in `CFBundleVersion`.

## Create a release

For a small trusted group, an ad-hoc-signed archive is sufficient for testing:

```bash
RELEASE_NOTES_FILE=/path/to/notes.md \
bash Scripts/make-release.sh 0.2.0 3
```

The script builds without installing and produces:

- `.release/YUANNotch-0.2.0.zip`
- `.release/YUANNotch-0.2.0.zip.sha256`
- `.release/YUANNotch-0.2.0.md` when release notes were supplied

Create a GitHub Release whose tag exactly matches `v<version>`, paste the release
notes, upload the ZIP and checksum, then publish it. Existing packaged builds
will detect it during their next daily check; users can also choose **Check for
Updates…** from the menu.

Because an ad-hoc-signed app is not identified or notarized by Apple, friends
may need to use **System Settings → Privacy & Security → Open Anyway** after
downloading a new build.

## Optional Developer ID and notarization

If distribution grows later, install a Developer ID Application certificate and
save App Store Connect credentials once:

```bash
xcrun notarytool store-credentials YUANNotch
```

Then the same script can sign, notarize, staple, and package the app:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE=YUANNotch \
RELEASE_NOTES_FILE=/path/to/notes.md \
bash Scripts/make-release.sh 0.2.0 3
```

Before publishing, verify the result:

```bash
codesign --verify --deep --strict --verbose=2 YUANNotch.app
spctl --assess --type execute --verbose=2 YUANNotch.app
```
