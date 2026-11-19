#!/bin/bash
# Cuts a GitHub release of MacShanti: bumps the version in Info.plist, builds
# the .app, zips it, commits + tags, and publishes a GitHub Release with the
# zip attached. The in-app updater (UpdateChecker) discovers new versions
# through these releases and downloads the attached zip.
#
# Usage:   ./Scripts/make_release.sh 1.1.0
# Needs:   Xcode command line tools (swift, codesign, ditto, PlistBuddy)
#          GitHub CLI authenticated for this repo (`gh auth login`)
#
# IMPORTANT: the zip is named MacShanti.zip on purpose. UpdateChecker looks
# for an asset with exactly that name; do not rename it without changing
# UpdateChecker.assetName to match.
set -euo pipefail

VERSION="${1:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$ROOT/Sources/MacShanti/Resources/Info.plist"
cd "$ROOT"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Usage: ./Scripts/make_release.sh <major.minor.patch>   e.g. 1.1.0" >&2
    exit 1
fi

command -v gh >/dev/null || { echo "✗ GitHub CLI (gh) not found. brew install gh" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "✗ gh is not logged in. Run: gh auth login" >&2; exit 1; }

if [[ -n "$(git status --porcelain)" ]]; then
    echo "✗ Working tree is dirty. Commit or stash first." >&2
    exit 1
fi

CURRENT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
NEWER="$(printf '%s\n%s\n' "$CURRENT" "$VERSION" | sort -V | tail -1)"
if [[ "$NEWER" != "$VERSION" || "$CURRENT" == "$VERSION" ]]; then
    echo "✗ $VERSION is not newer than the current $CURRENT." >&2
    exit 1
fi

if git rev-parse "v$VERSION" >/dev/null 2>&1; then
    echo "✗ Tag v$VERSION already exists." >&2
    exit 1
fi

echo "▶ Bumping version $CURRENT → $VERSION"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((BUILD + 1))" "$PLIST"

./Scripts/make_app.sh release

ZIP="$ROOT/build/MacShanti.zip"
echo "▶ Zipping $ZIP"
rm -f "$ZIP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$ROOT/build/MacShanti.app" "$ZIP"

echo "▶ Committing, tagging, pushing"
git add "$PLIST"
git commit -m "Release v$VERSION"
git tag "v$VERSION"
git push origin HEAD --follow-tags

echo "▶ Publishing GitHub release v$VERSION"
gh release create "v$VERSION" "$ZIP" \
    --title "MacShanti $VERSION" \
    --generate-notes

echo "✓ Released MacShanti $VERSION"
echo "  Installed copies will offer the update on their next daily check"
echo "  (or immediately via Check for Updates… in the popover)."
