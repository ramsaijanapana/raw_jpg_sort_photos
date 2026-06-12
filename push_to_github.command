#!/bin/bash
# push_to_github.command
# Double-click this on macOS to push all changes to GitHub.
# Works for both first-time pushes and subsequent updates.

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

# ── Remove stale lock file if present ─────────────────────────────
[ -f .git/index.lock ] && rm -f .git/index.lock

# ── First push vs update ───────────────────────────────────────────
if [ -d .git ]; then
    echo "Existing git repo detected — committing and pushing updates..."
    git add -A
    git commit -m "Update: loupe viewer, screenshots, README" || echo "(nothing new to commit)"
    git push
else
    echo "Initialising new git repo..."
    git init -b main
    git add -A
    git commit -m "Initial commit: photo sorter + review app with screenshots"
    git remote add origin "$REPO_URL"
    git push -u origin main --force
fi

if [ $? -eq 0 ]; then
    echo ""
    echo "✓ Done! Repo is live at:"
    echo "  $REPO_URL"
else
    echo ""
    echo "Push failed. If prompted for credentials, use your GitHub username"
    echo "and a Personal Access Token (not your password) from:"
    echo "  https://github.com/settings/tokens/new  (scope: repo)"
fi

echo ""
read -n 1 -s -r -p "Press any key to close..."
