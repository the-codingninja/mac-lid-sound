#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_NAME="com.hinge-sound.daemon"
PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"

echo "=== mac-door-hinge-sound ==="
echo ""

# Check compatibility
if ! hidutil list --matching '{"VendorID":0x5ac,"ProductID":0x8104,"PrimaryUsagePage":32,"PrimaryUsage":138}' 2>/dev/null | grep -q "0x8104"; then
    echo "Error: Lid angle sensor not found on this Mac."
    echo "This only works on M4 MacBooks and MacBook Pro 16\" 2019."
    exit 1
fi
echo "Lid angle sensor detected."

# Build if binary doesn't exist
if [ ! -f "$SCRIPT_DIR/hinge-daemon" ]; then
    if ! command -v swiftc >/dev/null 2>&1; then
        echo "Error: No pre-built binary found and swiftc not available."
        echo "Either download a release binary or install Xcode Command Line Tools:"
        echo "  xcode-select --install"
        exit 1
    fi
    echo "Compiling..."
    swiftc "$SCRIPT_DIR/Sources/main.swift" \
        -o "$SCRIPT_DIR/hinge-daemon" \
        -framework IOKit \
        -framework AVFoundation \
        -framework Foundation \
        -O
    echo "Done."
else
    echo "Using existing binary."
fi

# Stop existing daemon if running
if launchctl list 2>/dev/null | grep -q "$PLIST_NAME"; then
    echo "Stopping existing daemon..."
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
fi

# Install LaunchAgent plist
mkdir -p "$HOME/Library/LaunchAgents"
sed "s|__INSTALL_DIR__|$SCRIPT_DIR|g" "$SCRIPT_DIR/com.hinge-sound.daemon.plist" > "$PLIST_DEST"

# Load and start
launchctl load "$PLIST_DEST"

echo ""
echo "Installed. Your MacBook lid now creaks like an old door."
echo ""
echo "  Mute:    touch ~/.hinge_mute"
echo "  Unmute:  rm ~/.hinge_mute"
echo "  Logs:    cat ~/.hinge_sound.log"
echo "  Stop:    launchctl unload $PLIST_DEST"
echo "  Start:   launchctl load $PLIST_DEST"
echo "  Remove:  ./uninstall.sh"
