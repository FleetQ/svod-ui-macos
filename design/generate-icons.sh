#!/usr/bin/env bash
#
# Regenerate the entire Svod icon set from the SVG sources.
#   design/svod-icon.svg              -> AppIcon.appiconset (all macOS sizes)
#   design/svod-keystone-template.svg -> StatusItemTemplate.imageset (menu bar)
#
# Each raster is rendered straight from the SVG at its target pixel size (never
# upscaled from a smaller raster), so the set stays crisp. Requires librsvg:
#   brew install librsvg
#
# Usage:  design/generate-icons.sh        (run from anywhere)
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
SRC="$DIR/svod-icon.svg"
TMPL="$DIR/svod-keystone-template.svg"
ASSETS="$ROOT/Svod/Resources/Assets.xcassets"
APPICON="$ASSETS/AppIcon.appiconset"
STATUS="$ASSETS/StatusItemTemplate.imageset"

command -v rsvg-convert >/dev/null || { echo "error: rsvg-convert not found (brew install librsvg)"; exit 1; }

# Refresh the SVG sources from the geometry generator if Python is present.
if command -v python3 >/dev/null; then python3 "$DIR/build-svg.py" >/dev/null; fi

mkdir -p "$APPICON" "$STATUS"

render() { rsvg-convert -w "$1" -h "$1" "$2" -o "$3"; }

echo "AppIcon ->"
# size  scale  px   filename
appicon_rows="
16 1 16  icon_16x16.png
16 2 32  icon_16x16@2x.png
32 1 32  icon_32x32.png
32 2 64  icon_32x32@2x.png
128 1 128 icon_128x128.png
128 2 256 icon_128x128@2x.png
256 1 256 icon_256x256.png
256 2 512 icon_256x256@2x.png
512 1 512 icon_512x512.png
512 2 1024 icon_512x512@2x.png
"

entries=""
while read -r size scale px file; do
  [ -z "${size:-}" ] && continue
  render "$px" "$SRC" "$APPICON/$file"
  echo "  $file (${px}px)"
  entries="$entries{\"filename\":\"$file\",\"idiom\":\"mac\",\"scale\":\"${scale}x\",\"size\":\"${size}x${size}\"},"
done <<< "$appicon_rows"

cat > "$APPICON/Contents.json" <<JSON
{
  "images" : [
    ${entries%,}
  ],
  "info" : { "author" : "svod", "version" : 1 }
}
JSON

echo "StatusItemTemplate ->"
render 18 "$TMPL" "$STATUS/StatusItemTemplate.png"
render 36 "$TMPL" "$STATUS/StatusItemTemplate@2x.png"
echo "  StatusItemTemplate.png (18px), @2x (36px)"

cat > "$STATUS/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "StatusItemTemplate.png", "idiom" : "mac", "scale" : "1x" },
    { "filename" : "StatusItemTemplate@2x.png", "idiom" : "mac", "scale" : "2x" }
  ],
  "info" : { "author" : "svod", "version" : 1 },
  "properties" : { "template-rendering-intent" : "template" }
}
JSON

# Validate the AppIcon Contents.json (catch any filename/JSON drift early).
python3 - "$APPICON" <<'PY'
import json, os, sys
d = sys.argv[1]
c = json.load(open(os.path.join(d, "Contents.json")))
missing = [i["filename"] for i in c["images"] if not os.path.exists(os.path.join(d, i["filename"]))]
assert not missing, f"missing rasters: {missing}"
print(f"  Contents.json OK ({len(c['images'])} images)")
PY

echo "Done."
