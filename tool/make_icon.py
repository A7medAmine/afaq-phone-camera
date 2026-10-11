"""Usage: python tool/make_icon.py android/app/src/main/res

Draws the AFAQ Booth Camera launcher icon in the app colors and writes all Android densities."""
import os
import sys
from PIL import Image, ImageDraw

NAVY = (3, 10, 46)
BLUE = (36, 96, 231)
SUN = (255, 210, 63)
PINK = (255, 95, 162)
WHITE = (255, 255, 255)
S = 1024


def bolt(d, cx, cy, r, fill):
    pts = [(-0.18, -0.95), (0.42, -0.95), (0.08, -0.15), (0.45, -0.15), (-0.25, 0.98), (-0.05, 0.12), (-0.42, 0.12)]
    d.polygon([(cx + x * r, cy + y * r) for x, y in pts], fill=fill)


def foreground(scale=1.0, size=S):
    """Camera glyph centered on a transparent canvas; scale shrinks it for adaptive-icon safe zone."""
    im = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    k = size / S * scale
    o = size / 2

    def p(x, y):
        return (o + (x - 512) * k, o + (y - 512) * k)

    def box(x0, y0, x1, y1):
        a, b = p(x0, y0), p(x1, y1)
        return [a[0], a[1], b[0], b[1]]

    ink = max(2, round(26 * k))
    # top hump and flash
    d.rounded_rectangle(box(330, 250, 560, 360), radius=40 * k, fill=SUN, outline=NAVY, width=ink)
    d.rounded_rectangle(box(640, 280, 760, 350), radius=22 * k, fill=PINK, outline=NAVY, width=ink)
    # body with drop shadow
    d.rounded_rectangle(box(190, 340, 860, 790), radius=90 * k, fill=NAVY)
    d.rounded_rectangle(box(160, 310, 830, 760), radius=90 * k, fill=SUN, outline=NAVY, width=ink)
    # lens
    cx, cy = p(495, 535)
    for r, fill in ((190, NAVY), (160, WHITE), (130, BLUE)):
        rr = r * k
        d.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], fill=fill, outline=NAVY, width=ink if r < 190 else 0)
    bolt(d, cx, cy, 95 * k, SUN)
    # shine
    hx, hy = p(745, 395)
    d.ellipse([hx - 28 * k, hy - 28 * k, hx + 28 * k, hy + 28 * k], fill=WHITE, outline=NAVY, width=max(2, round(14 * k)))
    return im


def legacy(size):
    big = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(big)
    d.rounded_rectangle([24, 24, S - 24, S - 24], radius=230, fill=BLUE, outline=NAVY, width=28)
    big.alpha_composite(foreground(0.86))
    return big.resize((size, size), Image.LANCZOS)


def main(res):
    dens = {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}
    for name, f in dens.items():
        folder = os.path.join(res, f'mipmap-{name}')
        os.makedirs(folder, exist_ok=True)
        legacy(round(48 * f)).save(os.path.join(folder, 'ic_launcher.png'))
        fg = foreground(0.62).resize((round(108 * f),) * 2, Image.LANCZOS)
        fg.save(os.path.join(folder, 'ic_launcher_foreground.png'))


if __name__ == '__main__':
    main(sys.argv[1])
