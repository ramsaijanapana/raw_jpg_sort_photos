#!/bin/bash
# build_mac.sh — Builds PhotoSorter.app for macOS (no prerequisites needed to run)
# Run this ONCE on your Mac. Requires Python 3 + pip.

set -e
cd "$(dirname "$0")"

echo "======================================="
echo "   Photo Sorter — Mac Build"
echo "======================================="
echo ""

# Install build dependencies
echo "Installing dependencies..."
pip3 install --quiet --upgrade customtkinter Pillow pyinstaller

echo ""
echo "Building PhotoSorter.app..."

pyinstaller \
    --noconfirm \
    --windowed \
    --onedir \
    --name "PhotoSorter" \
    --collect-data customtkinter \
    --collect-data darkdetect \
    --hidden-import PIL \
    photo_sorter_app.py

echo ""
echo "======================================="
echo "✓  Build complete!"
echo ""
echo "   Your app is at:  dist/PhotoSorter.app"
echo ""
echo "   To distribute: drag PhotoSorter.app anywhere."
echo "   First launch: right-click → Open (bypasses Gatekeeper)."
echo "======================================="
echo ""

open dist/
