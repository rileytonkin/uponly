#!/usr/bin/env python3
"""Measure a screen's vertical rhythm from a capture.

    python3 measure_layout.py <capture.png> [--scale 2] [--width-pt W] [--frame x0,y0,x1,y1]

Why this exists: an audit that eyeballs spacing produces "feels cramped", which
nobody can act on. This produces "every block is 24pt apart, so nothing is
grouped", which is a fix. Apple's Layout page is a set of judgements about
grouping and emphasis; those judgements need numbers under them.

It reports content bands top to bottom, in points, with the gap between each,
and the distinct gap values. It does not measure margins; read left edges from
the capture (crop with --frame and measure the band's first ink column).

HOW IT WORKS, and the one trap: a row's "ink" is the count of pixels differing
from that row's own median colour. That is robust for text on a background and
USELESS for a full-bleed band (a photo, a filled card edge to edge), where the
median is the content itself. Such a band can go undetected, or merge with its
neighbours, so a gap next to it reads wrong. That is the detector failing, NOT
the app's spacing. Always sanity-check a surprising band or gap against the
capture before reporting it.

Defaults suit a macOS window or popover capture: the whole image is measured
and it is assumed to be Retina (2 px per pt). Pass --scale 1 for a non-Retina
capture, --width-pt to set the frame's width in points directly (overrides
--scale), and --frame to crop to the popover or window when the capture also
holds the desktop or the menu bar.
"""
import sys
from PIL import Image

def parse_args(argv):
    path = argv[1]
    width_pt = None
    scale = 2.0
    frame = None
    i = 2
    while i < len(argv):
        if argv[i] == "--width-pt":
            width_pt = float(argv[i + 1]); i += 2
        elif argv[i] == "--scale":
            scale = float(argv[i + 1]); i += 2
        elif argv[i] == "--frame":
            frame = tuple(int(v) for v in argv[i + 1].split(",")); i += 2
        else:
            i += 1
    return path, width_pt, scale, frame

def main():
    if len(sys.argv) < 2:
        print(__doc__); return 1
    path, width_pt, scale, frame = parse_args(sys.argv)
    F = Image.open(path).convert("RGB")
    if frame is not None:
        F = F.crop(frame)
    W, H = F.size
    ppp = W / width_pt if width_pt else scale
    print(f"frame {W}x{H}px  ->  {ppp:.3f} px per pt  ({W / ppp:.0f}pt wide)\n")

    def row_ink(y):
        px = [F.getpixel((x, y)) for x in range(W)]
        med = sorted(px, key=sum)[len(px) // 2]
        return sum(1 for p in px
                   if abs(p[0]-med[0]) + abs(p[1]-med[1]) + abs(p[2]-med[2]) > 60)

    bands, cur = [], None
    for y in range(H):
        if row_ink(y) > 3:
            cur = [y, y] if cur is None else [cur[0], y]
        else:
            if cur and cur[1] - cur[0] >= 2:
                bands.append(tuple(cur))
            cur = None
    if cur:
        bands.append(tuple(cur))

    print("VERTICAL RHYTHM  (gaps are ink-to-ink, so a control's own padding")
    print("is not included; add ~half a control's height to get its box edge)\n")
    print(f"  {'gap above':>12}   band (pt)            height")
    prev = None
    gaps = []
    for a, b in bands:
        gap = (a - prev) / ppp if prev is not None else None
        if gap is not None:
            gaps.append(gap)
        gs = f"{gap:9.1f}pt" if gap is not None else "        -"
        print(f"  {gs}   {a/ppp:6.1f} .. {b/ppp:6.1f}   {(b-a+1)/ppp:5.1f}pt")
        prev = b

    if gaps:
        uniq = sorted({round(g) for g in gaps if g > 8})
        print(f"\n  distinct gaps over 8pt: {uniq}")
        if len(uniq) <= 2:
            print("  ⚠ one or two spacing values for the whole screen means negative")
            print("    space is grouping NOTHING. Apple, Layout: 'Group related items...")
            print("    use negative space'. Related blocks want a smaller gap than the")
            print("    gap to the next idea.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
