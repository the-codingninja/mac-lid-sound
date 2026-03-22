#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Building hinge-daemon..."

swiftc "$SCRIPT_DIR/Sources/main.swift" \
    -o "$SCRIPT_DIR/hinge-daemon" \
    -framework IOKit \
    -framework AVFoundation \
    -framework Foundation \
    -O

echo "Built: $SCRIPT_DIR/hinge-daemon"
echo ""
echo "To create a release archive:"
echo "  tar czf hinge-daemon-macos-arm64.tar.gz hinge-daemon sounds/"
