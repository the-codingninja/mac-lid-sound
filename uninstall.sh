#!/bin/bash

PLIST_NAME="com.hinge-sound.daemon"
PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"

echo "=== Uninstalling mac-door-hinge-sound ==="

if [ -f "$PLIST_DEST" ]; then
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
    rm "$PLIST_DEST"
    echo "Stopped daemon and removed LaunchAgent."
else
    echo "No LaunchAgent found."
fi

pkill -f hinge-daemon 2>/dev/null && echo "Killed running daemon." || true

echo "Done."
