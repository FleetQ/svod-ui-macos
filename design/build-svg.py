#!/usr/bin/env python3
"""
Geometry generator for the Svod icon — the masonry ARCH (svod = "свод" = vault)
with an illuminated KEYSTONE.

It emits three SVGs that are the rasterization source of truth:
  - svod-icon.svg            full arch tile (1024 macOS app-icon artboard)
  - svod-keystone.svg        the keystone wedge alone (brand mark)
  - svod-keystone-template.svg  black silhouette of the wedge (menu-bar template)

Concept encoded here (not a generic icon):
  • the arch holds and does not collapse  -> "never loses files"
  • the highlighted keystone locks the structure -> single source of truth / single writer
  • discrete voussoirs = accumulated commits/notes

Edit the constants below and re-run to regenerate the SVGs, then run
generate-icons.sh to rasterize the whole set.
"""
import math

# ── canvas / tile (macOS icon keyline: ~824 body in a 1024 artboard) ──────────
CANVAS = 1024
BODY = 832
MARGIN = (CANVAS - BODY) / 2          # 96
CORNER = 186

# ── arch geometry ─────────────────────────────────────────────────────────────
CX = 512
CY = 644                              # springing line (arch feet sit here)
R_OUT = 300                           # outer radius of the voussoir ring
R_IN = 170                            # inner radius (opening)
N_SIDE = 6                            # voussoirs per side
KEY_DEG = 21.0                        # angular width of the keystone
GAP_DEG = 1.2                         # mortar gap between stones (angular)
RAD_INSET = 3.0                       # mortar gap on inner/outer edges (px)

# ── palette ───────────────────────────────────────────────────────────────────
# Stones sit a clear step above the tile so the arch silhouette survives at 16px.
TILE_TOP = "#252A37"
TILE_BOT = "#13151B"
STONE_A = "#535B6A"
STONE_B = "#454D5B"
MORTAR = "#15171D"
KEY_TOP = "#F4CC84"
KEY_BOT = "#CF8A34"
KEY_EDGE = "#FCE3B0"
KEY_LINE = "#9A6526"
GLOW = "#F0A94A"


def pt(theta_deg, radius):
    t = math.radians(theta_deg)
    return (CX + radius * math.cos(t), CY - radius * math.sin(t))


def fmt(p):
    return f"{p[0]:.2f},{p[1]:.2f}"


def voussoir_path(lo, hi, r_in, r_out):
    """Annular sector between angles [lo, hi] (deg) and radii r_in..r_out."""
    o_hi, o_lo = pt(hi, r_out), pt(lo, r_out)
    i_lo, i_hi = pt(lo, r_in), pt(hi, r_in)
    return (f"M{fmt(o_hi)} "
            f"A{r_out},{r_out} 0 0 1 {fmt(o_lo)} "
            f"L{fmt(i_lo)} "
            f"A{r_in},{r_in} 0 0 0 {fmt(i_hi)} Z")


def side_segments():
    """Angular [lo,hi] for each side voussoir, both sides, outermost→springing."""
    half_key = KEY_DEG / 2
    span = (180 - KEY_DEG) / 2          # degrees available per side
    step = span / N_SIDE
    segs = []
    # right side: 0 .. (90-half_key)
    for k in range(N_SIDE):
        segs.append((k * step, (k + 1) * step))
    # left side: (90+half_key) .. 180
    base = 90 + half_key
    for k in range(N_SIDE):
        segs.append((base + k * step, base + (k + 1) * step))
    return segs


def keystone_seg():
    return (90 - KEY_DEG / 2, 90 + KEY_DEG / 2)


def stones_svg():
    g = []
    inset = GAP_DEG / 2
    for idx, (lo, hi) in enumerate(side_segments()):
        fill = STONE_A if idx % 2 == 0 else STONE_B
        d = voussoir_path(lo + inset, hi - inset, R_IN + RAD_INSET, R_OUT - RAD_INSET)
        g.append(f'<path d="{d}" fill="{fill}"/>')
    return "\n    ".join(g)


def keystone_svg(lo, hi, r_in, r_out, with_glow=True):
    d = voussoir_path(lo, hi, r_in, r_out)
    parts = []
    if with_glow:
        parts.append(f'<path d="{d}" fill="{GLOW}" opacity="0.55" filter="url(#glow)"/>')
    parts.append(f'<path d="{d}" fill="url(#key)" stroke="{KEY_LINE}" stroke-width="2"/>')
    # bright apex facet along the outer edge
    o_hi, o_lo = pt(hi, r_out), pt(lo, r_out)
    f_hi, f_lo = pt(hi, r_out - 26), pt(lo, r_out - 26)
    facet = (f"M{fmt(o_hi)} A{r_out},{r_out} 0 0 1 {fmt(o_lo)} "
             f"L{fmt(f_lo)} A{r_out-26},{r_out-26} 0 0 0 {fmt(f_hi)} Z")
    parts.append(f'<path d="{facet}" fill="{KEY_EDGE}" opacity="0.7"/>')
    return "\n    ".join(parts)


def icon_svg():
    ks_lo, ks_hi = keystone_seg()
    inset = GAP_DEG / 2
    plinth_x0, plinth_x1 = 188, 836
    plinth_y = CY
    plinth_h = 38
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}" viewBox="0 0 {CANVAS} {CANVAS}">
  <defs>
    <linearGradient id="tile" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{TILE_TOP}"/>
      <stop offset="1" stop-color="{TILE_BOT}"/>
    </linearGradient>
    <radialGradient id="sheen" cx="0.5" cy="0.16" r="0.7">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.06"/>
      <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="key" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{KEY_TOP}"/>
      <stop offset="1" stop-color="{KEY_BOT}"/>
    </linearGradient>
    <linearGradient id="plinth" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{STONE_A}"/>
      <stop offset="1" stop-color="{STONE_B}"/>
    </linearGradient>
    <filter id="glow" x="-60%" y="-60%" width="220%" height="220%">
      <feGaussianBlur stdDeviation="16"/>
    </filter>
  </defs>

  <!-- tile -->
  <rect x="{MARGIN}" y="{MARGIN}" width="{BODY}" height="{BODY}" rx="{CORNER}" ry="{CORNER}" fill="url(#tile)"/>
  <rect x="{MARGIN}" y="{MARGIN}" width="{BODY}" height="{BODY}" rx="{CORNER}" ry="{CORNER}" fill="url(#sheen)"/>

  <!-- plinth (grounds the arch) -->
  <rect x="{plinth_x0}" y="{plinth_y}" width="{plinth_x1-plinth_x0}" height="{plinth_h}" rx="14" fill="url(#plinth)"/>

  <!-- voussoirs -->
  <g>
    {stones_svg()}
  </g>

  <!-- illuminated keystone -->
  <g>
    {keystone_svg(ks_lo + inset, ks_hi - inset, R_IN + RAD_INSET, R_OUT - RAD_INSET)}
  </g>
</svg>
'''


def keystone_mark_svg(black=False):
    """Standalone keystone wedge, centered in a 512 viewBox with padding."""
    size = 512
    # Build the wedge from the same angular slice, then translate/scale to center.
    ks_lo, ks_hi = keystone_seg()
    # widen a touch so the solo mark has presence
    lo, hi = 90 - 17, 90 + 17
    r_in, r_out = 150, 300
    d = voussoir_path(lo, hi, r_in, r_out)
    # the wedge as authored sits around (CX, CY); compute its bbox to recenter
    pts = [pt(lo, r_out), pt(hi, r_out), pt(lo, r_in), pt(hi, r_in)]
    xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
    bw = max(xs) - min(xs); bh = max(ys) - min(ys)
    pad = 70
    scale = (size - 2 * pad) / max(bw, bh)
    cx_b = (max(xs) + min(xs)) / 2; cy_b = (max(ys) + min(ys)) / 2
    tx = size / 2 - cx_b * scale
    ty = size / 2 - cy_b * scale
    if black:
        body = f'<path d="{d}" fill="#000000"/>'
        defs = ""
    else:
        defs = f'''<defs>
    <linearGradient id="key" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{KEY_TOP}"/><stop offset="1" stop-color="{KEY_BOT}"/>
    </linearGradient>
  </defs>'''
        body = f'<path d="{d}" fill="url(#key)" stroke="{KEY_LINE}" stroke-width="3"/>'
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 {size} {size}">
  {defs}
  <g transform="translate({tx:.2f},{ty:.2f}) scale({scale:.4f})">
    {body}
  </g>
</svg>
'''


if __name__ == "__main__":
    import os
    here = os.path.dirname(os.path.abspath(__file__))
    open(os.path.join(here, "svod-icon.svg"), "w").write(icon_svg())
    open(os.path.join(here, "svod-keystone.svg"), "w").write(keystone_mark_svg(black=False))
    open(os.path.join(here, "svod-keystone-template.svg"), "w").write(keystone_mark_svg(black=True))
    print("wrote svod-icon.svg, svod-keystone.svg, svod-keystone-template.svg")
