#!/bin/bash
# Builds MacShanti and assembles a proper .app bundle. UNUserNotification
# requires a bundled, ideally code-signed app — running the bare SPM binary will
# build and launch, but notifications work most reliably from a .app bundle.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "▶ Building ($CONFIG)…"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/MacShanti"
APP="$ROOT/build/MacShanti.app"

echo "▶ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacShanti"
cp "$ROOT/Sources/MacShanti/Resources/Info.plist" "$APP/Contents/Info.plist"

# Ad-hoc sign so notifications and the menubar item behave.
codesign --force --deep --sign - "$APP" || echo "⚠ codesign skipped (no signing identity)"

echo "✓ Built $APP"
echo "  Launch with: open \"$APP\""
