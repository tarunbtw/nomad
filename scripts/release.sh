#!/bin/bash
# ==============================================================================
# Dino Automated Release & Homebrew Distribution Script
#
# Usage:
#   ./scripts/release.sh [version]
#
# Examples:
#   ./scripts/release.sh 0.42
#   ./scripts/release.sh 0.41.1
# ==============================================================================

set -euo pipefail

# Ensure script is run from project root
cd "$(dirname "$0")/.."
PROJECT_ROOT="$(pwd)"
TAP_DIR="/Users/tarun/projects/homebrew-tap"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

RELEASE_SUCCESS=false
ZIP_PATH=""
BUILT_APP=""

cleanup_build_artifacts() {
  if [ -x "$LSREGISTER" ]; then
    for target_dir in "$PROJECT_ROOT/build" "$PROJECT_ROOT/dist/staging" "$HOME/Library/Developer/Xcode/DerivedData"/dino-*; do
      if [ -d "$target_dir" ]; then
        find "$target_dir" -name "*.app" -type d -prune 2>/dev/null | while read -r app_path; do
          if [ -n "$app_path" ]; then
            "$LSREGISTER" -u "$app_path" 2>/dev/null || true
          fi
        done
      fi
    done
    "$LSREGISTER" -gc 2>/dev/null || true
  fi

  rm -rf "$PROJECT_ROOT/dist/staging" "$PROJECT_ROOT/build"
  rm -rf "$HOME/Library/Developer/Xcode/DerivedData"/dino-*
}

rollback_on_failure() {
  if [ "$RELEASE_SUCCESS" = "false" ]; then
    echo "" >&2
    echo "⚠️  Release aborted or failed. Rolling back local changes..." >&2
    # Restore any modified version files in dino repository
    git checkout -- dino.xcodeproj/project.pbxproj dino/Services/DinoVersion.swift packaging/homebrew/dino.rb appcast.json sdks/typescript/package.json sdks/typescript/bin/dino.js sdks/python/pyproject.toml sdks/python/dino_browser/__init__.py 2>/dev/null || true
    # Restore tap repository cask
    if [ -d "$TAP_DIR" ]; then
      (cd "$TAP_DIR" && git checkout -- Casks/dino.rb 2>/dev/null || true)
    fi
    # Unregister and clean staging, build, and DerivedData directories
    cleanup_build_artifacts
    if [ -n "$ZIP_PATH" ] && [ -f "$ZIP_PATH" ]; then
      rm -f "$ZIP_PATH"
    fi
    echo "==> Working trees cleanly restored to pre-release state." >&2
  fi
}

trap rollback_on_failure EXIT

# 1. Version Detection & Determination
CURRENT_VERSION=$(grep 'version "' packaging/homebrew/dino.rb | head -n1 | sed -E 's/.*version "([^"]+)".*/\1/')

if [ -n "${1:-}" ]; then
  NEW_VERSION="$1"
else
  # Auto-bump minor version (e.g. 0.41 -> 0.42)
  MAJOR=$(echo "$CURRENT_VERSION" | cut -d. -f1)
  MINOR=$(echo "$CURRENT_VERSION" | cut -d. -f2)
  NEW_MINOR=$((MINOR + 1))
  NEW_VERSION="${MAJOR}.${NEW_MINOR}"
  echo "==> No version specified. Auto-bumping from ${CURRENT_VERSION} to ${NEW_VERSION}"
fi

echo "=========================================================="
echo "  Dino Release Pipeline: v${NEW_VERSION}"
echo "  Previous Version:      v${CURRENT_VERSION}"
echo "=========================================================="

# 2. Pre-flight Validation
if [ ! -d "$TAP_DIR/Casks" ]; then
  echo "❌ Error: Homebrew tap directory not found at $TAP_DIR" >&2
  exit 1
fi

if [ ! -f "$TAP_DIR/Casks/dino.rb" ]; then
  echo "❌ Error: $TAP_DIR/Casks/dino.rb not found" >&2
  exit 1
fi

# Ensure dino repo is clean
if [ -n "$(git status --porcelain)" ]; then
  echo "❌ Error: Dino repository has uncommitted changes. Please commit or stash them first." >&2
  exit 1
fi

# Ensure tap repo is clean
if [ -n "$(cd "$TAP_DIR" && git status --porcelain)" ]; then
  echo "❌ Error: $TAP_DIR has uncommitted changes. Please clean or commit them first." >&2
  exit 1
fi

# 3. Version Update in project.pbxproj, DinoVersion.swift, local packaging, tap, and SDKs
echo "==> Updating version numbers to ${NEW_VERSION}..."
sed -i '' -E "s/MARKETING_VERSION = [0-9.]+;/MARKETING_VERSION = ${NEW_VERSION};/g" dino.xcodeproj/project.pbxproj
sed -i '' -E "s/static let version = \"[0-9.]+\"/static let version = \"${NEW_VERSION}\"/g" dino/Services/DinoVersion.swift
sed -i '' -E "s/version \"[0-9.]+\"/version \"${NEW_VERSION}\"/g" packaging/homebrew/dino.rb
sed -i '' -E "s/version \"[0-9.]+\"/version \"${NEW_VERSION}\"/g" "$TAP_DIR/Casks/dino.rb"

# SDK versions (standardize to SemVer for npm and pip)
if [[ "$NEW_VERSION" =~ \.[0-9]+\.[0-9]+ ]]; then
  SDK_VERSION="${NEW_VERSION}"
else
  SDK_VERSION="${NEW_VERSION}.0"
fi
sed -i '' -E "s/\"version\": \"[0-9.]+\"/\"version\": \"${SDK_VERSION}\"/g" sdks/typescript/package.json
sed -i '' -E "s/const DINO_VERSION = '[0-9.]+';/const DINO_VERSION = '${NEW_VERSION}';/g" sdks/typescript/bin/dino.js
sed -i '' -E "s/version = \"[0-9.]+\"/version = \"${SDK_VERSION}\"/g" sdks/python/pyproject.toml
sed -i '' -E "s/__version__ = \"[0-9.]+\"/__version__ = \"${SDK_VERSION}\"/g" sdks/python/dino_browser/__init__.py

echo "==> Rebuilding TypeScript SDK..."
(cd "$PROJECT_ROOT/sdks/typescript" && npm run build)

# 4. Clean & Build Release via Xcode (Zero Warnings & Zero Errors Enforcement)
echo "==> Cleaning old build artifacts and preparing fresh build directory..."
cleanup_build_artifacts
BUILD_DIR="$PROJECT_ROOT/build/DerivedData"
mkdir -p "$BUILD_DIR"
BUILD_LOG="$BUILD_DIR/xcodebuild.log"

set +e
xcodebuild -project dino.xcodeproj \
  -scheme dino \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$BUILD_DIR" \
  MARKETING_VERSION="${NEW_VERSION}" \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES \
  build > "$BUILD_LOG" 2>&1
BUILD_STATUS=$?
set -e

if [ "$BUILD_STATUS" -ne 0 ]; then
  echo "❌ Error: Compilation failed with exit code ${BUILD_STATUS}." >&2
  tail -n 25 "$BUILD_LOG" >&2
  exit 1
fi

# Strict check: reject release if any compiler/code warnings occurred
CODE_WARNINGS=$(grep -E "(:[0-9]+:[0-9]+: warning:)" "$BUILD_LOG" || true)
if [ -n "$CODE_WARNINGS" ]; then
  echo "❌ Error: Release build produced compiler warnings. Aborting release." >&2
  echo "$CODE_WARNINGS" >&2
  exit 1
fi
echo "==> Build succeeded cleanly (0 warnings, 0 errors)."

BUILT_APP="$BUILD_DIR/Build/Products/Release/Dino.app"

if [ ! -d "$BUILT_APP" ]; then
  echo "❌ Error: Compilation succeeded but build artifact not found at $BUILT_APP" >&2
  exit 1
fi

# 5. Staging, Metadata Cleanup, and Codesigning
echo "==> Staging and signing application bundle..."
STAGING_DIR="$PROJECT_ROOT/dist/staging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

cp -R "$BUILT_APP" "$STAGING_DIR/Dino.app"
cp "$STAGING_DIR/Dino.app/Contents/MacOS/Dino" "$STAGING_DIR/Dino.app/Contents/MacOS/dino" 2>/dev/null || true

# Strip quarantine and AppleDouble metadata
xattr -cr "$STAGING_DIR/Dino.app" 2>/dev/null || true

# Codesign bundle with entitlements
codesign --force --deep --sign - --entitlements dino/dino.entitlements "$STAGING_DIR/Dino.app" >/dev/null 2>&1

# 6. Archive Creation with ditto (immune to AppleDouble resource forks)
echo "==> Packaging archive with ditto..."
mkdir -p "$PROJECT_ROOT/dist"
ZIP_PATH="$PROJECT_ROOT/dist/Dino-${NEW_VERSION}.zip"
rm -f "$ZIP_PATH"

ditto -c -k --keepParent --norsrc "$STAGING_DIR/Dino.app" "$ZIP_PATH"

# 7. Compute SHA-256 Digest
SHA256=$(shasum -a 256 "$ZIP_PATH" | cut -d' ' -f1)
echo "==> Computed SHA-256: ${SHA256}"

# 8. Unregister and delete uncompressed build artifacts
# Prevents macOS LaunchServices and Spotlight from indexing duplicate Dino.app instances
echo "==> Unregistering intermediate build artifacts and deleting build directories..."
cleanup_build_artifacts

# 9. Update Checksums in Casks & Sync appcast.json
echo "==> Updating checksum in packaging/homebrew/dino.rb and tap..."
sed -i '' -E "s/sha256 \"[a-f0-9]{64}\"/sha256 \"${SHA256}\"/g" packaging/homebrew/dino.rb
sed -i '' -E "s/sha256 \"[a-f0-9]{64}\"/sha256 \"${SHA256}\"/g" "$TAP_DIR/Casks/dino.rb"

echo "==> Updating appcast.json for auto-updater..."
cat <<EOF > "$PROJECT_ROOT/appcast.json"
{
  "version": "${NEW_VERSION}",
  "build": 1,
  "url": "https://github.com/tarunbtw/dino/releases/download/v${NEW_VERSION}/Dino-${NEW_VERSION}.zip",
  "sha256": "${SHA256}",
  "notes": "Dino ${NEW_VERSION} release.",
  "minimumSystemVersion": "13.0"
}
EOF

# 10. Commit & Tag in Dino repository
echo "==> Committing release changes in dino repository..."
git add .
if git diff --cached --quiet; then
  echo "==> Working directory clean, no new changes to commit in dino."
else
  git commit -m "release: v${NEW_VERSION}"
fi

if git rev-parse "v${NEW_VERSION}" >/dev/null 2>&1; then
  echo "==> Git tag v${NEW_VERSION} already exists."
else
  git tag -a "v${NEW_VERSION}" -m "Dino ${NEW_VERSION}"
fi

echo "==> Pushing commits and tags to origin main..."
git push origin main --tags

# 11. Create GitHub Release & Upload Asset via gh CLI
echo "==> Publishing release to GitHub via gh..."
if gh release view "v${NEW_VERSION}" >/dev/null 2>&1; then
  echo "==> Release v${NEW_VERSION} already exists on GitHub. Uploading archive..."
  gh release upload "v${NEW_VERSION}" "$ZIP_PATH" --clobber
else
  echo "==> Creating GitHub release v${NEW_VERSION}..."
  gh release create "v${NEW_VERSION}" "$ZIP_PATH" \
    --title "Dino ${NEW_VERSION}" \
    --generate-notes
fi

# 12. Commit & Push Homebrew Tap
echo "==> Committing and pushing Homebrew tap update..."
cd "$TAP_DIR"
git add Casks/dino.rb
git commit -m "dino: bump to ${NEW_VERSION}"
git push origin main
cd "$PROJECT_ROOT"

# 13. Publish NPM package
echo "==> Publishing NPM package dino-browser..."
if npm whoami >/dev/null 2>&1; then
  (cd "$PROJECT_ROOT/sdks/typescript" && npm publish --access public) || echo "⚠️  NPM publish encountered an error, continuing..."
else
  echo "ℹ️  NPM not logged in, skipping npm publish. Run 'npm login && npm publish' inside sdks/typescript when ready."
fi

RELEASE_SUCCESS=true

# 14. Final Summary
echo ""
echo "=========================================================="
echo "🎉 Dino v${NEW_VERSION} successfully published and distributed!"
echo "=========================================================="
echo "  Archive:   ${ZIP_PATH}"
echo "  SHA-256:   ${SHA256}"
echo "  Release:   https://github.com/tarunbtw/dino/releases/tag/v${NEW_VERSION}"
echo "  Homebrew:  Pushed to tarunbtw/homebrew-tap (brew update && brew upgrade dino)"
echo "  NPM:       dino-browser (v${SDK_VERSION})"
echo "=========================================================="
echo ""
