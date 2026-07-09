#!/usr/bin/env python3
"""Regenerate the Nod DMG background (scripts/dmg/background.tiff).

Takes the source sky art (background-src.png), fits it to the 640×400 pt install
window, bakes in an elegant periwinkle "drag → Applications" arrow (supersampled
for smooth edges, with a soft glow echoing the sky's flowing lines), and writes a
hidpi TIFF (@1x + @2x) that Finder renders crisply on Retina.

    python3 scripts/dmg/make-background.py

Icon-row geometry here must stay in sync with the icon positions in
scripts/make-dmg.sh (NOD_*/APP_* at y=200, so the arrow sits on the same row).
"""
import math
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

HERE = Path(__file__).resolve().parent
SRC = HERE / "background-src.png"
OUT_1X = HERE / "background.png"
OUT_2X = HERE / "background@2x.png"
OUT_TIFF = HERE / "background.tiff"

W2, H2 = 1280, 800  # @2x of the 640×400 pt window


def main() -> None:
    src = Image.open(SRC).convert("RGB")
    sw, sh = src.size
    scale = max(W2 / sw, H2 / sh)  # cover-fit, crop center
    rw, rh = round(sw * scale), round(sh * scale)
    img = src.resize((rw, rh), Image.LANCZOS)
    left, top = (rw - W2) // 2, (rh - H2) // 2
    img = img.crop((left, top, left + W2, top + H2)).convert("RGBA")

    # Draw the arrow supersampled, then downscale → anti-aliased edges.
    ss = 4
    arrow = Image.new("RGBA", (W2 * ss, H2 * ss), (0, 0, 0, 0))
    ad = ImageDraw.Draw(arrow)
    col = (126, 134, 214, 205)
    p0, p1, p2 = (512, 404), (642, 380), (772, 404)  # bezier: bows gently up
    w = 3 * ss

    pts = []
    for i in range(121):
        t = i / 120
        x = (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t * t * p2[0]
        y = (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t * t * p2[1]
        pts.append((x * ss, y * ss))
    ad.line(pts, fill=col, width=w, joint="curve")

    ang = math.atan2(2 * (p2[1] - p1[1]), 2 * (p2[0] - p1[0]))
    head = 24 * ss
    for a in (ang + math.radians(148), ang - math.radians(148)):
        ad.line(
            [(p2[0] * ss, p2[1] * ss), (p2[0] * ss + head * math.cos(a), p2[1] * ss + head * math.sin(a))],
            fill=col,
            width=w,
            joint="curve",
        )
    for p in (p0, p2):  # round caps
        r = 1.5 * ss
        ad.ellipse([p[0] * ss - r, p[1] * ss - r, p[0] * ss + r, p[1] * ss + r], fill=col)
    g = 6 * ss  # faint tail spark
    ad.ellipse([p0[0] * ss - g, p0[1] * ss - g, p0[0] * ss + g, p0[1] * ss + g], fill=(150, 158, 225, 70))

    arrow = arrow.resize((W2, H2), Image.LANCZOS)
    img = Image.alpha_composite(img, arrow.filter(ImageFilter.GaussianBlur(5)))
    img = Image.alpha_composite(img, arrow).convert("RGB")

    img.save(OUT_2X)
    img.resize((640, 400), Image.LANCZOS).save(OUT_1X)
    subprocess.run(
        ["tiffutil", "-cathidpicheck", str(OUT_1X), str(OUT_2X), "-out", str(OUT_TIFF)],
        check=True,
    )
    print(f"wrote {OUT_TIFF.name} (hidpi @1x+@2x)")


if __name__ == "__main__":
    main()
