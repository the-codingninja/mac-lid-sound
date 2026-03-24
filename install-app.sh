#!/bin/bash
# Door Hinge — one-line installer
# Usage: curl -sL https://raw.githubusercontent.com/the-codingninja/mac-lid-sound/main/install-app.sh | bash
set -e

APP_NAME="Door Hinge"
APP_DEST="/Applications/$APP_NAME.app"
DMG_PATH="/tmp/Door-Hinge.dmg"
MOUNT_POINT="/Volumes/$APP_NAME"
REPO="the-codingninja/mac-lid-sound"

echo "=== Door Hinge Installer ==="
echo ""

# Get latest release tag and download DMG
echo "Fetching latest release..."
TAG=$(curl -sI "https://github.com/$REPO/releases/latest" \
    | grep -i "^location:" \
    | sed 's|.*/tag/||' \
    | tr -d '[:space:]')

if [ -z "$TAG" ]; then
    echo "Error: Could not determine latest release."
    exit 1
fi

DMG_URL="https://github.com/$REPO/releases/download/$TAG/Door-Hinge.dmg"
echo "Downloading $TAG..."
curl -sL "$DMG_URL" -o "$DMG_PATH"

if [ ! -s "$DMG_PATH" ]; then
    echo "Error: Download failed."
    exit 1
fi

# Mount DMG
hdiutil attach "$DMG_PATH" -quiet -nobrowse

# Kill existing instance
pkill -f "$APP_NAME.app" 2>/dev/null || true
sleep 1

# Install
echo "Installing to /Applications..."
rm -rf "$APP_DEST"
cp -R "$MOUNT_POINT/$APP_NAME.app" "$APP_DEST"

# Clear quarantine — bypasses Gatekeeper
xattr -cr "$APP_DEST"

# Cleanup
hdiutil detach "$MOUNT_POINT" -quiet
rm -f "$DMG_PATH"

echo "Launching $APP_NAME..."
open "$APP_DEST"

echo ""
echo "Done! $APP_NAME is running in your menu bar."
