#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"
BUILD="${2:-}"
RELEASE_ROOT="${RELEASE_ROOT:-$ROOT_DIR/.release}"
SIGNING_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
INCLUDE_ZIP="${INCLUDE_ZIP:-0}"
DMG_NAME="YUANNotch-$VERSION.dmg"
DMG_PATH="$RELEASE_ROOT/$DMG_NAME"
ARCHIVE_NAME="YUANNotch-$VERSION.zip"
ARCHIVE_PATH="$RELEASE_ROOT/$ARCHIVE_NAME"

if [[ -z "$VERSION" || -z "$BUILD" ]]; then
  echo "usage: $0 <semantic-version> <positive-build-number>" >&2
  echo "example: SIGN_IDENTITY='Developer ID Application: …' $0 1.0.1 14" >&2
  exit 1
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "error: version must use semantic versioning (got '$VERSION')" >&2
  exit 1
fi
if [[ ! "$BUILD" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: build number must be a positive integer (got '$BUILD')" >&2
  exit 1
fi
if [[ "$INCLUDE_ZIP" != "0" && "$INCLUDE_ZIP" != "1" ]]; then
  echo "error: INCLUDE_ZIP must be 0 or 1" >&2
  exit 1
fi
if [[ -n "${RELEASE_NOTES_FILE:-}" && ! -f "$RELEASE_NOTES_FILE" ]]; then
  echo "error: RELEASE_NOTES_FILE does not exist: $RELEASE_NOTES_FILE" >&2
  exit 1
fi
if [[ -n "$NOTARY_PROFILE" && "$SIGNING_IDENTITY" == "-" ]]; then
  echo "error: NOTARY_PROFILE requires a Developer ID SIGN_IDENTITY" >&2
  exit 1
fi
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  echo "warning: creating a local DMG with an ad-hoc-signed app; use Developer ID and NOTARY_PROFILE for notarized public releases" >&2
fi

mkdir -p "$RELEASE_ROOT"

APP_VERSION="$VERSION" \
BUILD_NUMBER="$BUILD" \
INSTALL_APP=0 \
SIGN_IDENTITY="$SIGNING_IDENTITY" \
bash "$ROOT_DIR/Scripts/package-app.sh"

# ZIP is optional. When requested, staple its app before creating the final ZIP
# and DMG so both forms are usable offline after successful notarization.
if [[ "$INCLUDE_ZIP" == "1" ]]; then
  rm -f "$ARCHIVE_PATH"
  ditto -c -k --sequesterRsrc --keepParent "$ROOT_DIR/YUANNotch.app" "$ARCHIVE_PATH"
  if [[ -n "$NOTARY_PROFILE" ]]; then
    xcrun notarytool submit "$ARCHIVE_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$ROOT_DIR/YUANNotch.app"
    xcrun stapler validate "$ROOT_DIR/YUANNotch.app"
    rm -f "$ARCHIVE_PATH"
    ditto -c -k --sequesterRsrc --keepParent "$ROOT_DIR/YUANNotch.app" "$ARCHIVE_PATH"
  fi
fi

SIGN_IDENTITY="$SIGNING_IDENTITY" bash "$ROOT_DIR/Scripts/make-dmg.sh" "$ROOT_DIR/YUANNotch.app" "$DMG_PATH"
if [[ -n "$NOTARY_PROFILE" ]]; then
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
fi

if [[ -n "${RELEASE_NOTES_FILE:-}" ]]; then
  cp "$RELEASE_NOTES_FILE" "$RELEASE_ROOT/YUANNotch-$VERSION.md"
fi

# Checksums cover the final, stapled deliverables and work with shasum -c.
(cd "$RELEASE_ROOT" && shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256")
if [[ "$INCLUDE_ZIP" == "1" ]]; then
  (cd "$RELEASE_ROOT" && shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256")
fi

echo ""
echo "Release artifacts are ready:"
echo "  $DMG_PATH"
echo "  $DMG_PATH.sha256"
if [[ "$INCLUDE_ZIP" == "1" ]]; then
  echo "  $ARCHIVE_PATH"
  echo "  $ARCHIVE_PATH.sha256"
fi
echo ""
echo "Next: upload the DMG and its checksum to GitHub release v$VERSION. ZIP is optional."
