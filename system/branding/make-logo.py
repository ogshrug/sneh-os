#!/usr/bin/env python3
"""The स्नेह wordmark: the word set in Noto Sans Devanagari Bold, nothing added
but colour - the word in the text colour and the vowel sign े in the accent
(dusk: lavender and peach).

Shaped with HarfBuzz from system/fonts/NotoSansDevanagari.ttf (SIL OFL 1.1, see
OFL-NotoSansDevanagari.txt), so every curve is the font's own. Writes:
  sneh-mark.svg       the word in currentColor, the े in peach (CSS / README)
  sneh-mark-dusk.svg  lavender + peach
  sneh-icon.svg       app icon: lavender + peach on a night-navy rounded square
  ../templates/sneh__logo.svg   the bar logo, coloured by `sne theme set`
Dev tool only (needs fonttools + uharfbuzz): python3 make-logo.py
"""
import io
import os

import uharfbuzz as hb
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

HERE = os.path.dirname(os.path.abspath(__file__))
FONT = os.path.join(HERE, "..", "fonts", "NotoSansDevanagari.ttf")
WORD = "स्नेह"
WGHT = 700                                           # Bold
NIGHT, FG, PEACH = "#080a18", "#e6e2f7", "#efb2a4"   # dusk: bg, fg, accent2
ACCENT_GLYPHS = {"uni0947"}                          # े, the vowel sign above न


def bold_font():
    f = TTFont(FONT)
    if "fvar" in f:
        f = instancer.instantiateVariableFont(f, {"wght": WGHT, "wdth": 100})
    buf = io.BytesIO()
    f.save(buf)
    return TTFont(io.BytesIO(buf.getvalue())), buf.getvalue()


def shaped_paths():
    """SVG paths of WORD (y down, baseline at 0): word, vowel sign, bounds."""
    font, data = bold_font()
    buf = hb.Buffer()
    buf.add_str(WORD)
    buf.guess_segment_properties()
    hb.shape(hb.Font(hb.Face(data)), buf, {})
    gs = font.getGlyphSet()
    order = font.getGlyphOrder()
    fmt = lambda v: f"{v:.1f}".rstrip("0").rstrip(".")
    pen, apen, bpen = SVGPathPen(gs, ntos=fmt), SVGPathPen(gs, ntos=fmt), BoundsPen(gs)
    x = 0
    for info, pos in zip(buf.glyph_infos, buf.glyph_positions):
        name = order[info.codepoint]
        t = (1, 0, 0, -1, x + pos.x_offset, -pos.y_offset)    # flip y for SVG
        gs[name].draw(TransformPen(apen if name in ACCENT_GLYPHS else pen, t))
        gs[name].draw(TransformPen(bpen, t))
        x += pos.x_advance
    return pen.getCommands(), apen.getCommands(), bpen.bounds


def write(name, text):
    with open(os.path.join(HERE, name), "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def main():
    d, da, (x0, y0, x1, y1) = shaped_paths()
    pad = 20
    vb = f"{x0 - pad:.0f} {y0 - pad:.0f} {x1 - x0 + 2 * pad:.0f} {y1 - y0 + 2 * pad:.0f}"
    w, h = x1 - x0, y1 - y0

    def svg(fill, accent):
        return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vb}" width="{w / 4 + 10:.0f}" height="{h / 4 + 10:.0f}">'
                f'<title>{WORD}</title><path fill="{fill}" d="{d}"/><path fill="{accent}" d="{da}"/></svg>\n')

    write("sneh-mark.svg", svg("currentColor", PEACH))
    write("sneh-mark-dusk.svg", svg(FG, PEACH))
    write(os.path.join("..", "templates", "sneh__logo.svg"), svg("#{{fg}}", "#{{accent2}}"))

    S = 512                                  # icon: the word at 78% of the width
    k = S * 0.78 / w
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    write("sneh-icon.svg",
          f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {S} {S}" width="{S}" height="{S}"><title>{WORD}</title>'
          f'<rect width="{S}" height="{S}" rx="112" fill="{NIGHT}"/>'
          f'<g transform="translate({S / 2:.1f},{S / 2:.1f}) scale({k:.5f}) translate({-cx:.1f},{-cy:.1f})">'
          f'<path fill="{FG}" d="{d}"/><path fill="{PEACH}" d="{da}"/></g></svg>\n')
    write(".mark-path", f"{vb}\n{d}\n{da}\n")
    print("bounds", (x0, y0, x1, y1))


if __name__ == "__main__":
    main()
