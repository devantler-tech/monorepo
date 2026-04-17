#!/usr/bin/env python3
"""Generate a sharp, high-resolution Matrix-rain hero image.

Run from the docs/ directory:

    python3 scripts/generate-hero.py

The image is rendered at 2x the target size and downsampled with Lanczos
resampling. That supersampling pass gives crisp glyph edges on both retina
screens and large full-bleed desktop heroes, and avoids the pixelated look
that happens when the browser upscales a smaller source.
"""
import os
import random
from PIL import Image, ImageDraw, ImageFilter, ImageFont

TARGET_W, TARGET_H = 3200, 1600
SUPERSAMPLE = 2
WIDTH, HEIGHT = TARGET_W * SUPERSAMPLE, TARGET_H * SUPERSAMPLE

OUTPUT = os.path.join(os.path.dirname(__file__), "..", "src", "assets", "matrix.png")

FONT_LATIN = "/System/Library/Fonts/Menlo.ttc"
FONT_JAPANESE = "/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc"
FONT_SIZE = 28 * SUPERSAMPLE
CELL_W = 24 * SUPERSAMPLE
CELL_H = 34 * SUPERSAMPLE

# Slightly brighter heads/trails so the rain streams read clearly against
# a sparse background, without looking neon or amateur.
HEAD = (225, 255, 220)
BRIGHT = (150, 255, 140)
MID = (65, 220, 80)
DIM = (30, 140, 50)
FAINT = (14, 70, 26)
BG = (3, 7, 5)

# Use only the standard katakana block and skip the handful of codepoints
# that are diacritics or combining marks so the font renders cleanly.
KATAKANA = [chr(c) for c in range(0x30A1, 0x30FB)]
DIGITS = list("0123456789")
SYMBOLS = list("+=-*<>|:.%#$")
POOL = KATAKANA * 4 + DIGITS * 2 + SYMBOLS


def load_font(path, size):
    try:
        return ImageFont.truetype(path, size)
    except OSError:
        return ImageFont.load_default()


def pick_font(ch, latin, jp):
    return jp if ord(ch[0]) > 0x2000 else latin


def draw_background(draw, rows, cols, latin, jp):
    # Sparse faint texture — higher skip rate keeps the canvas readable.
    for r in range(rows):
        for c in range(cols):
            if random.random() < 0.82:
                continue
            ch = random.choice(POOL)
            font = pick_font(ch, latin, jp)
            alpha = random.randint(18, 55)
            draw.text((c * CELL_W, r * CELL_H), ch, font=font, fill=(25, 95, 35, alpha))


def draw_drops(draw, cols, rows, latin, jp):
    # One rain column per grid column, but some columns are empty so the
    # composition doesn't feel like a uniform wall of characters.
    for c in range(cols):
        if random.random() < 0.25:
            continue
        head_row = random.randint(-rows, rows)
        trail_len = random.randint(10, rows + 6)
        x = c * CELL_W
        for i in range(trail_len):
            r = head_row - i
            if r < 0 or r >= rows:
                continue
            ch = random.choice(POOL)
            font = pick_font(ch, latin, jp)
            y = r * CELL_H
            if i == 0:
                color = HEAD
            elif i < 2:
                color = BRIGHT
            elif i < 6:
                color = MID
            elif i < 12:
                color = DIM
            else:
                color = FAINT
            draw.text((x, y), ch, font=font, fill=color)


def apply_vignette(img):
    vignette = Image.new("RGBA", img.size, (0, 0, 0, 0))
    vdraw = ImageDraw.Draw(vignette)
    w, h = img.size
    steps = 80
    for i in range(steps):
        a = int(110 * (i / steps) ** 2)
        vdraw.rectangle(
            [i * (w // (steps * 2)), i * (h // (steps * 2)),
             w - i * (w // (steps * 2)), h - i * (h // (steps * 2))],
            outline=(0, 0, 0, a),
        )
    vignette = vignette.filter(ImageFilter.GaussianBlur(radius=8 * SUPERSAMPLE))
    return Image.alpha_composite(img, vignette)


def main():
    random.seed(42)

    img = Image.new("RGBA", (WIDTH, HEIGHT), BG + (255,))
    draw = ImageDraw.Draw(img)

    latin = load_font(FONT_LATIN, FONT_SIZE)
    jp = load_font(FONT_JAPANESE, FONT_SIZE)

    cols = WIDTH // CELL_W
    rows = HEIGHT // CELL_H

    draw_background(draw, rows, cols, latin, jp)
    draw_drops(draw, cols, rows, latin, jp)
    img = apply_vignette(img)

    # Supersample downscale → crisp antialiased glyphs.
    img = img.resize((TARGET_W, TARGET_H), Image.LANCZOS)

    out = os.path.abspath(OUTPUT)
    img.convert("RGB").save(out, optimize=True)
    print(f"Wrote {out} ({img.size[0]}x{img.size[1]})")


if __name__ == "__main__":
    main()
