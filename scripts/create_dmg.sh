#!/bin/bash
# Creates a distributable DMG for grabthis

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="GrabThisApp"
DMG_NAME="grabthis"
VERSION=$(grep -A1 'CFBundleShortVersionString' "$PROJECT_DIR/Support/GrabThisApp-Info.plist" | tail -1 | sed 's/.*<string>\(.*\)<\/string>.*/\1/')

echo "Building $APP_NAME v$VERSION..."

# Build the app first
"$SCRIPT_DIR/build_app_bundle.sh"

if [ ! -d "$BUILD_DIR/$APP_NAME.app" ]; then
    echo "ERROR: App bundle not found at $BUILD_DIR/$APP_NAME.app"
    exit 1
fi

# Create DMG staging directory
DMG_STAGING="$BUILD_DIR/dmg_staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"

# Copy app to staging
cp -R "$BUILD_DIR/$APP_NAME.app" "$DMG_STAGING/"

# Create symlink to Applications folder
ln -s /Applications "$DMG_STAGING/Applications"

# Create the DMG
DMG_PATH="$BUILD_DIR/${DMG_NAME}-${VERSION}.dmg"
rm -f "$DMG_PATH"

echo "Creating DMG..."
hdiutil create -volname "$DMG_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDZO \
    "$DMG_PATH"

# Cleanup
rm -rf "$DMG_STAGING"

echo ""
echo "Done! DMG created at:"
echo "  $DMG_PATH"
echo ""
echo "Share this file with friends. They should:"
echo "  1. Open the DMG"
echo "  2. Drag grabthis to Applications"
echo "  3. Right-click the app → Open (first time only)"
