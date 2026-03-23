#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
APP_NAME="Door Hinge"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
DMG_NAME="Door-Hinge.dmg"

# --- CLI daemon (backward compatible) ---
echo "Building hinge-daemon (CLI)..."

swiftc "$SCRIPT_DIR/Sources/main.swift" \
    -o "$SCRIPT_DIR/hinge-daemon" \
    -framework IOKit \
    -framework AVFoundation \
    -framework Cocoa \
    -framework ServiceManagement \
    -O

echo "Built: $SCRIPT_DIR/hinge-daemon"

# --- macOS App Bundle ---
echo ""
echo "Building $APP_NAME.app..."

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources/sounds"

# Compile the app binary
swiftc "$SCRIPT_DIR/Sources/main.swift" \
    -o "$APP_BUNDLE/Contents/MacOS/door-hinge" \
    -framework IOKit \
    -framework AVFoundation \
    -framework Cocoa \
    -framework ServiceManagement \
    -O

# Copy resources
cp "$SCRIPT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$SCRIPT_DIR/sounds/"*.wav "$APP_BUNDLE/Contents/Resources/sounds/"

# Ad-hoc code sign (required for running on other machines)
codesign --force --deep --sign - "$APP_BUNDLE"

echo "Built: $APP_BUNDLE"

# --- DMG ---
echo ""
echo "Creating $DMG_NAME..."

DMG_STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_BUNDLE" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

rm -f "$SCRIPT_DIR/$DMG_NAME"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDZO \
    "$SCRIPT_DIR/$DMG_NAME" \
    -quiet

rm -rf "$DMG_STAGING"

echo "Created: $SCRIPT_DIR/$DMG_NAME"
echo ""
echo "Done! Distribution files:"
echo "  App:    $APP_BUNDLE"
echo "  DMG:    $SCRIPT_DIR/$DMG_NAME"
echo "  CLI:    $SCRIPT_DIR/hinge-daemon"
