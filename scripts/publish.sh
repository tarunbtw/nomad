#!/bin/bash
# Builds, archives, computes SHA-256 digests, and generates appcast.json for Nomad releases.
# Usage:
#   ./scripts/publish.sh <version> <build_number> [release_notes]
# Example:
#   ./scripts/publish.sh 1.0.1 2 "Added native auto-updater and bug fixes"

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-}"
BUILD="${2:-}"
NOTES="${3:-Bug fixes and performance improvements.}"

if [ -z "$VERSION" ] || [ -z "$BUILD" ]; then
  echo "Usage: ./scripts/publish.sh <version> <build_number> [release_notes]"
  echo "Example: ./scripts/publish.sh 1.0.1 2 'Added native auto-updater and performance improvements'"
  exit 1
fi

OUT="build"
APP_NAME="nomad"
ZIP_NAME="Nomad.zip"
DMG_NAME="Nomad.dmg"

echo "==> Building Nomad (Version $VERSION, Build $BUILD)..."
rm -rf "$OUT"
mkdir -p "$OUT"

xcodebuild -project nomad.xcodeproj \
  -scheme nomad \
  -configuration Release \
  -derivedDataPath "$OUT/derived" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  build

BUILT_APP="$OUT/derived/Build/Products/Release/$APP_NAME.app"

if [ ! -d "$BUILT_APP" ]; then
  echo "Error: Built application not found at $BUILT_APP" >&2
  exit 1
fi

echo "==> Packaging $ZIP_NAME..."
ditto -c -k --keepParent "$BUILT_APP" "$OUT/$ZIP_NAME"

SHA256="$(shasum -a 256 "$OUT/$ZIP_NAME" | cut -d' ' -f1)"
echo "Archive SHA-256: $SHA256"

echo "==> Packaging $DMG_NAME..."
hdiutil create -volname "Nomad" -srcfolder "$BUILT_APP" -ov -format UDZO "$OUT/$DMG_NAME"
DMG_SHA256="$(shasum -a 256 "$OUT/$DMG_NAME" | cut -d' ' -f1)"

DOWNLOAD_BASE="https://github.com/tarunbtw/nomad/releases/download/v$VERSION"

cat > "$OUT/appcast.json" <<JSON
{
  "version": "$VERSION",
  "build": $BUILD,
  "url": "$DOWNLOAD_BASE/$ZIP_NAME",
  "dmg": "$DOWNLOAD_BASE/$DMG_NAME",
  "sha256": "$SHA256",
  "dmgSha256": "$DMG_SHA256",
  "notes": "$NOTES",
  "minimumSystemVersion": "13.0"
}
JSON

cp "$OUT/appcast.json" ./appcast.json

echo ""
echo "=========================================================="
echo "  Nomad $VERSION (Build $BUILD) Ready for Distribution!"
echo "  Artifacts created in: $OUT/"
echo "    - $OUT/$ZIP_NAME"
echo "    - $OUT/$DMG_NAME"
echo "    - $OUT/appcast.json"
echo "  Updated ./appcast.json at project root."
echo "=========================================================="
