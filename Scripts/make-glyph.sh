#!/usr/bin/env bash
#
# Builds and runs the app-mark generator (Scripts/make-glyph/main.swift).
#
# The mark is drawn from geometry, not resampled from a master bitmap: the two
# reps shipped in Sources/YUANNotch/Glyph/ are rendered at 18 px and 36 px
# directly, so the stroke lands on the right sub-pixel grid at each size.
#
# Running it rewrites Resources/Glyph.png (the 989 px master, kept as the
# reference rendering) and both reps. It prints the weight, the inner ring's
# size and height, and every clearance between parts first — read those before
# committing a parameter change.
#
#   bash Scripts/make-glyph.sh                      # write the tracked PNGs
#   bash Scripts/make-glyph.sh --baseline --out-dir /tmp/base
#                                                   # re-render the pre-existing
#                                                   # weight, to re-verify the fit

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT_DIR/Scripts/make-glyph/main.swift"
BUILD_DIR="${TMPDIR:-/tmp}/yuanotch-make-glyph"
BINARY="$BUILD_DIR/make-glyph"

mkdir -p "$BUILD_DIR"
xcrun swiftc -O -o "$BINARY" "$SOURCE"
"$BINARY" "$ROOT_DIR" "$@"
