#!/usr/bin/env python3
"""Generate the Wave app icon set with Pillow.

Draws a 1024x1024 master (dark background, teal equaliser bars) and scales
it to every size the AppIcon.appiconset Contents.json references.
Run from the repo root: python3 scripts/make_icon.py
"""
import os
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "Wave", "Resources", "Assets.xcassets",
                   "AppIcon.appiconset")
SIZES = [40, 58, 60, 80, 87, 120, 180, 1024]


def draw_master(size: int = 1024) -> Image.Image:
    img = Image.new("RGB", (size, size), (10, 14, 16))
    d = ImageDraw.Draw(img, "RGBA")
    # Soft teal glow in the upper half.
    for r in range(0, size // 2, 4):
        alpha = max(0, 46 - r // 12)
        d.ellipse(
            [size // 2 - r, size // 4 - r // 2, size // 2 + r, size // 4 + r // 2],
            fill=(0, 212, 184, alpha // 6),
        )
    # Five equaliser bars, teal gradient by height.
    bar_w = size // 9
    gap = size // 18
    total = 5 * bar_w + 4 * gap
    x = (size - total) // 2
    heights = [0.42, 0.72, 1.0, 0.58, 0.34]
    for i, h in enumerate(heights):
        bh = int(size * 0.52 * h)
        y0 = size // 2 + size // 4 - bh
        y1 = size // 2 + size // 4
        # Vertical teal gradient, drawn as stacked strips.
        steps = 24
        for s in range(steps):
            t = s / steps
            g = int(150 + 105 * t)
            b = int(140 + 90 * t)
            yy0 = y0 + (y1 - y0) * s // steps
            yy1 = y0 + (y1 - y0) * (s + 1) // steps
            d.rectangle([x, yy0, x + bar_w, yy1], fill=(0, g, b))
        # Rounded caps: redraw the bar as a rounded rectangle outline pass.
        d.rounded_rectangle([x, y0, x + bar_w, y1], radius=bar_w // 2,
                            outline=(0, 212, 184), width=max(2, size // 256))
        x += bar_w + gap
    return img


def main() -> None:
    os.makedirs(OUT, exist_ok=True)
    master = draw_master()
    for px in SIZES:
        path = os.path.join(OUT, f"icon-{px}.png")
        if px == 1024:
            master.save(path)
        else:
            master.resize((px, px), Image.LANCZOS).save(path)
        print("wrote", path)


if __name__ == "__main__":
    main()
