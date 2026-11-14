#!/bin/bash
# ==============================================================================
# Dino SDK Distribution & Rollout Pipeline
#
# Builds, validates, and publishes client SDKs for Dino:
#   - TypeScript / Node.js: dino-browser (NPM)
#   - Python: dino-browser (PyPI)
#
# Usage:
#   ./scripts/sdks.sh          # Build and publish both NPM and Python
#   ./scripts/sdks.sh --npm    # Publish only NPM package
#   ./scripts/sdks.sh --python # Publish only Python package
#   ./scripts/sdks.sh --dry-run # Validate and preview packaging without publishing
# ==============================================================================

set -euo pipefail

# Ensure script runs from project root
cd "$(dirname "$0")/.."
PROJECT_ROOT="$(pwd)"

TARGET_NPM=true
TARGET_PYTHON=true
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --npm)
      TARGET_NPM=true
      TARGET_PYTHON=false
      ;;
    --python)
      TARGET_NPM=false
      TARGET_PYTHON=true
      ;;
    --dry-run)
      DRY_RUN=true
      ;;
    --help|-h)
      echo "Usage: ./scripts/sdks.sh [--npm | --python] [--dry-run]"
      exit 0
      ;;
  esac
done

# 1. Resolve Current Version
DINO_VERSION=$(grep 'static let version' dino/Services/DinoVersion.swift | head -n1 | sed -E 's/.*"([^"]+)".*/\1/')
if [[ "$DINO_VERSION" =~ \.[0-9]+\.[0-9]+ ]]; then
  SDK_VERSION="${DINO_VERSION}"
else
  SDK_VERSION="${DINO_VERSION}.0"
fi

echo "=========================================================="
echo "  Dino SDKs Rollout Pipeline"
echo "  Native Engine Version: v${DINO_VERSION}"
echo "  SDK Package Version:   v${SDK_VERSION}"
echo "  Dry Run:               ${DRY_RUN}"
echo "=========================================================="

# 2. Synchronize Version Metadata
sed -i '' -E "s/\"version\": \"[0-9.]+\"/\"version\": \"${SDK_VERSION}\"/g" sdks/typescript/package.json
sed -i '' -E "s/const DINO_VERSION = '[0-9.]+';/const DINO_VERSION = '${DINO_VERSION}';/g" sdks/typescript/bin/dino.js
sed -i '' -E "s/version = \"[0-9.]+\"/version = \"${SDK_VERSION}\"/g" sdks/python/pyproject.toml
sed -i '' -E "s/__version__ = \"[0-9.]+\"/__version__ = \"${SDK_VERSION}\"/g" sdks/python/dino_browser/__init__.py

# ==============================================================================
# NPM Package (dino-browser)
# ==============================================================================
if [ "$TARGET_NPM" = "true" ]; then
  echo ""
  echo "----------------------------------------------------------"
  echo "📦 TypeScript / Node.js SDK: dino-browser (v${SDK_VERSION})"
  echo "----------------------------------------------------------"
  
  cd "$PROJECT_ROOT/sdks/typescript"

  # Validate authentication
  echo "==> Verifying NPM authentication..."
  if ! NPM_USER=$(npm whoami 2>/dev/null); then
    echo "⚠️  You are not logged in to npm."
    echo "👉 Please run 'npm login' in your terminal and re-run this script."
    exit 1
  fi
  echo "==> Authenticated as: ${NPM_USER}"

  # Build TypeScript
  echo "==> Compiling TypeScript..."
  npm run build

  if [ ! -f "dist/index.js" ] || [ ! -f "dist/index.d.ts" ]; then
    echo "❌ Error: Build output missing in sdks/typescript/dist" >&2
    exit 1
  fi

  # Preview Tarball
  echo "==> Previewing package tarball..."
  npm pack --dry-run

  if [ "$DRY_RUN" = "true" ]; then
    echo "✅ Dry run complete for dino-browser. Skipping publish."
  else
    echo "==> Publishing dino-browser to NPM (interactive 2FA)..."
    npm publish --access public
    echo "🎉 Successfully published dino-browser@${SDK_VERSION} to NPM!"
  fi
  cd "$PROJECT_ROOT"
fi

# ==============================================================================
# Python Package (dino-browser)
# ==============================================================================
if [ "$TARGET_PYTHON" = "true" ]; then
  echo ""
  echo "----------------------------------------------------------"
  echo "🐍 Python SDK: dino-browser (v${SDK_VERSION})"
  echo "----------------------------------------------------------"

  cd "$PROJECT_ROOT/sdks/python"
  rm -rf dist build *.egg-info

  # Check if build tool is available
  if python3 -m build --version >/dev/null 2>&1; then
    echo "==> Building Python sdist and wheel via python3 -m build..."
    python3 -m build
  else
    echo "==> Building Python sdist and wheel via setup.py..."
    python3 -c "import setuptools; setuptools.setup()" sdist bdist_wheel 2>/dev/null || {
      python3 -m pip install --user --upgrade build
      python3 -m build
    }
  fi

  echo "==> Generated distributions:"
  ls -la dist/

  if [ "$DRY_RUN" = "true" ]; then
    echo "✅ Dry run complete for Python dino-browser. Skipping publish."
  else
    if command -v twine >/dev/null 2>&1; then
      echo "==> Uploading distributions to PyPI via twine..."
      twine upload dist/*
      echo "🎉 Successfully published dino-browser==${SDK_VERSION} to PyPI!"
    else
      echo "ℹ️  'twine' not found. To upload to PyPI manually, run:"
      echo "   cd sdks/python && pip install twine && twine upload dist/*"
    fi
  fi
  cd "$PROJECT_ROOT"
fi

echo ""
echo "=========================================================="
echo "✅ SDK rollout process complete!"
echo "=========================================================="
