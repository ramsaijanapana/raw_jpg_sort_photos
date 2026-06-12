#!/bin/bash
# sort_photos.command — Double-click this on macOS to sort photos.
# Drop this file (along with sort_photos.py) into any photo folder and double-click.

# Move to the folder this script lives in
cd "$(dirname "$0")"

echo "==============================="
echo "   Photo Sorter — macOS"
echo "==============================="
echo ""

# Check for Python 3
if command -v python3 &>/dev/null; then
    python3 sort_photos.py
elif command -v python &>/dev/null && python --version 2>&1 | grep -q "Python 3"; then
    python sort_photos.py
else
    echo "Python 3 is not installed."
    echo ""
    echo "Install it from https://www.python.org/downloads/"
    echo "or via Homebrew:  brew install python"
fi

echo ""
echo "Press any key to close..."
read -n 1 -s
