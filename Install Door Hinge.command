#!/bin/bash
# Door Hinge Installer
# Double-click this file to install the app

set -e

APP_NAME="Door Hinge"
DMG_MOUNT="$(dirname "$0")"
APP_SRC="$DMG_MOUNT/$APP_NAME.app"
APP_DEST="/Applications/$APP_NAME.app"

echo "==============================="
echo "  Door Hinge Installer"
echo "==============================="
echo ""

if [ ! -d "$APP_SRC" ]; then
    echo "Error: $APP_NAME.app not found next to this installer."
    echo "Make sure you're running this from the DMG."
    echo ""
    read -p "Press Enter to close..."
    exit 1
fi

# Remove old version if present
if [ -d "$APP_DEST" ]; then
    echo "Removing previous installation..."
    rm -rf "$APP_DEST"
fi

echo "Installing $APP_NAME to /Applications..."
cp -R "$APP_SRC" "$APP_DEST"

echo "Clearing quarantine (bypasses Gatekeeper warning)..."
xattr -cr "$APP_DEST"

echo ""
echo "Done! Launching $APP_NAME..."
open "$APP_DEST"

echo ""
echo "$APP_NAME is now running in your menu bar."
echo "You can close this window."
echo ""
read -p "Press Enter to close..."
