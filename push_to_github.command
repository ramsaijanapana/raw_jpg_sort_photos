#!/bin/bash
# push_to_github.command
# Double-click this on macOS to push the photo sorter scripts to GitHub.

cd "$(dirname "$0")"

REPO_URL="https://github.com/ramsaijanapana/raw_jpg_sort_photos.git"

echo "======================================="
echo "   Photo Sorter — Push to GitHub"
echo "======================================="
echo ""
echo "Remote: $REPO_URL"
echo ""

# ── Dependency check ──────────────────────────────────────────────
if ! command -v git &>/dev/null; then
    echo "ERROR: git is not installed."
    echo "Install via: xcode-select --install"
    read -n 1 -s -r -p "Press any key to exit..."; exit 1
fi

# ── Git init & commit ─────────────────────────────────────────────
echo "Initialising git..."
rm -rf .git
git init -b main
git add .
git commit -m "Initial commit: cross-platform photo sorter scripts"

# ── Set remote & push ─────────────────────────────────────────────
echo ""
echo "Pushing to GitHub..."
git remote add origin "$REPO_URL"
git push -u origin main

if [ $? -eq 0 ]; then
    echo ""
    echo "✓ Done! Scripts are live at:"
    echo "  $REPO_URL"
else
    echo ""
    echo "Push failed. If prompted for credentials, use your GitHub username"
    echo "and a Personal Access Token (not your password) from:"
    echo "  https://github.com/settings/tokens/new  (scope: repo)"
fi

echo ""
read -n 1 -s -r -p "Press any key to close..."
