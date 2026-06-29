#!/usr/bin/env bash
#
# Package a built Svod.app into a drag-to-install DMG. Mirrors the Lattice app's
# make-dmg.sh. Run after the app is built + Developer-ID signed.
#
#   Scripts/make-dmg.sh <path/to/Svod.app> <out.dmg>
set -euo pipefail

APP="${1:?usage: make-dmg.sh <Svod.app> <out.dmg>}"
DMG="${2:?usage: make-dmg.sh <Svod.app> <out.dmg>}"
STAGE="$(dirname "$DMG")/dmg-stage"

[ -d "$APP" ] || { echo "ERROR: $APP not found." >&2; exit 1; }

echo "==> staging"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> hdiutil create $DMG"
hdiutil create -volname "Svod" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "==> done: $DMG ($(/usr/bin/du -h "$DMG" | cut -f1))"
