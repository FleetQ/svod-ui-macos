# Svod icon

The mark is a masonry **arch** (Bulgarian *свод* = vault) built from discrete
stones (voussoirs), with the top-center **keystone** illuminated in a warm accent.

**Why this, not a generic icon**
- The arch holds and does not collapse — Svod's promise to **never lose files**.
- The illuminated keystone locks the whole structure — the **single source of
  truth / single writer** that the engine guarantees.
- The discrete voussoirs are accumulated **commits / notes**, resting on a plinth.

## Palette
- Tile: graphite squircle, vertical gradient `#252A37 → #13151B` (dark-mode native).
- Stones: two close graphite tones `#535B6A` / `#454D5B`, dark mortar gaps. Stones
  sit a clear step above the tile so the arch silhouette survives at 16px.
- Keystone: warm amber gradient `#F4CC84 → #CF8A34`, a bright apex facet, and a soft
  amber glow so it reads as *illuminated*. It is the only accent — everything else
  is neutral.

## Files
- `svod-icon.svg` — full arch tile, 1024 macOS artboard. **Rasterization source of truth.**
- `svod-keystone.svg` — the keystone wedge alone (brand mark: menu bar / CLI / favicon / README).
- `svod-keystone-template.svg` — black silhouette of the wedge (macOS menu-bar template).
- `build-svg.py` — geometry generator that emits the three SVGs. Edit the constants
  at the top (radii, voussoir count, palette) and re-run to restyle.
- `generate-icons.sh` — renders every raster from the SVGs into the asset catalog.

## Regenerate
```sh
brew install librsvg          # one-time: provides rsvg-convert
design/generate-icons.sh      # re-runs build-svg.py, then renders the full set
```
This rewrites:
- `Svod/Resources/Assets.xcassets/AppIcon.appiconset/` — 16/32/128/256/512 @1x/2x
  (10 PNGs) + `Contents.json` (validated against the produced filenames).
- `Svod/Resources/Assets.xcassets/StatusItemTemplate.imageset/` — 18pt @1x/2x menu-bar
  template (`template-rendering-intent: template`).

Each size is rendered straight from the SVG at its target pixel size — never
upscaled from a smaller raster.

## Wiring
- `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` is set on the Svod target; the
  build compiles `AppIcon.icns` + `Assets.car` into the bundle.
- The menu-bar mark is ready as `StatusItemTemplate`. To show it on a status item:
  ```swift
  let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  item.button?.image = NSImage(named: "StatusItemTemplate")   // isTemplate via render intent
  ```
  (No live status item is installed by the app — the asset is provided for when one is.)
