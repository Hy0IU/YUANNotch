#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"
BUILD="${2:-}"
RELEASE_ROOT="${RELEASE_ROOT:-$ROOT_DIR/.release}"
SIGNING_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
ARCHIVE_NAME="YUANNotch-$VERSION.zip"
ARCHIVE_PATH="$RELEASE_ROOT/$ARCHIVE_NAME"
CHECKSUM_PATH="$ARCHIVE_PATH.sha256"

if [[ -z "$VERSION" || -z "$BUILD" ]]; then
  echo "usage: $0 <semantic-version> <positive-build-number>" >&2
  echo "example: SIGN_IDENTITY='Developer ID Application: …' $0 0.3.3 8" >&2
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
if [[ -n "$NOTARY_PROFILE" && "$SIGNING_IDENTITY" == "-" ]]; then
  echo "error: NOTARY_PROFILE requires a Developer ID SIGN_IDENTITY" >&2
  exit 1
fi
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  echo "warning: creating an ad-hoc-signed archive; use Developer ID and NOTARY_PROFILE for public releases" >&2
fi

mkdir -p "$RELEASE_ROOT"

APP_VERSION="$VERSION" \
BUILD_NUMBER="$BUILD" \
INSTALL_APP=0 \
SIGN_IDENTITY="$SIGNING_IDENTITY" \
bash "$ROOT_DIR/Scripts/package-app.sh"

rm -f "$ARCHIVE_PATH"
ditto -c -k --sequesterRsrc --keepParent "$ROOT_DIR/YUANNotch.app" "$ARCHIVE_PATH"

if [[ -n "$NOTARY_PROFILE" ]]; then
  xcrun notarytool submit "$ARCHIVE_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
  xcrun stapler staple "$ROOT_DIR/YUANNotch.app"
  xcrun stapler validate "$ROOT_DIR/YUANNotch.app"

  # Stapling changes the app, so recreate the archive before calculating its checksum.
  rm -f "$ARCHIVE_PATH"
  ditto -c -k --sequesterRsrc --keepParent "$ROOT_DIR/YUANNotch.app" "$ARCHIVE_PATH"
fi

if [[ -n "${RELEASE_NOTES_FILE:-}" ]]; then
  if [[ ! -f "$RELEASE_NOTES_FILE" ]]; then
    echo "error: RELEASE_NOTES_FILE does not exist: $RELEASE_NOTES_FILE" >&2
    exit 1
  fi
  cp "$RELEASE_NOTES_FILE" "$RELEASE_ROOT/YUANNotch-$VERSION.md"
fi

checksum="$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')"
printf '%s  %s\n' "$checksum" "$ARCHIVE_NAME" > "$CHECKSUM_PATH"

echo ""
echo "Release artifacts are ready:"
echo "  $ARCHIVE_PATH"
echo "  $CHECKSUM_PATH"
echo ""
echo "Next: create a GitHub release tagged v$VERSION and upload both files."
