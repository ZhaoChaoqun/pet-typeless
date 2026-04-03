#!/usr/bin/env bash
# Build Pet Typeless as a .app bundle and package for distribution.
#
# Usage:
#   ./scripts/release.sh 1.0.0
#
# Output:
#   client/build/Pet-Typeless-<version>.zip
#
# The zip can be uploaded to a GitHub Release. The update-homebrew.yml
# workflow will automatically update the Homebrew cask on release.

set -euo pipefail

VERSION="${1:?Usage: $0 <version>  (e.g. 1.0.0)}"
APP_NAME="Pet Typeless"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CLIENT_DIR="$PROJECT_ROOT/client"
BUILD_DIR="$CLIENT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "🔨 Building Pet Typeless v${VERSION}..."

# ── 1. Build release binary ──────────────────────────────────────
cd "$CLIENT_DIR"
swift build -c release 2>&1

BINARY="$CLIENT_DIR/.build/release/PetTypeless"
if [[ ! -f "$BINARY" ]]; then
    echo "❌ Binary not found at $BINARY"
    exit 1
fi

# ── 2. Create .app bundle ────────────────────────────────────────
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/"

# Copy Info.plist and substitute version
cp "$CLIENT_DIR/Sources/Info.plist" "$APP_BUNDLE/Contents/"
sed -i '' "s/\$(MARKETING_VERSION)/${VERSION}/g" "$APP_BUNDLE/Contents/Info.plist"

# Copy icon
cp "$CLIENT_DIR/Sources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"

# Create PkgInfo (standard macOS app identifier)
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

echo "📦 App bundle created at: $APP_BUNDLE"

# ── 3. Ad-hoc code sign ──────────────────────────────────────────
codesign --force --deep --sign - \
    --entitlements "$CLIENT_DIR/Sources/PetTypeless.entitlements" \
    "$APP_BUNDLE"
echo "🔏 Code signed (ad-hoc)"

# ── 4. Package as zip ────────────────────────────────────────────
cd "$BUILD_DIR"
ZIP_NAME="Pet-Typeless-${VERSION}.zip"
rm -f "$ZIP_NAME"
zip -r -q "$ZIP_NAME" "$APP_NAME.app"

echo ""
echo "✅ Done! Package: $BUILD_DIR/$ZIP_NAME"
echo ""
echo "Next steps:"
echo "  1. Test the app:  open \"$APP_BUNDLE\""
echo "  2. Create GitHub release:"
echo "     git tag v${VERSION}"
echo "     git push origin v${VERSION}"
echo "     gh release create v${VERSION} \"$BUILD_DIR/$ZIP_NAME\" --title \"Pet Typeless v${VERSION}\""
