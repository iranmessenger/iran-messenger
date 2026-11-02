"""Draws every IRAN Messenger icon and splash image from code, so the
artwork has no outside source.

    python scripts/make-icons.py
"""
from pathlib import Path

from PIL import Image, ImageDraw

APP = Path(__file__).resolve().parent.parent / 'app'
NAVY = (11, 31, 58)
GREEN = (14, 107, 78)
FLAG_GREEN = (35, 159, 64)
FLAG_RED = (218, 0, 0)
WHITE = (255, 255, 255)
BIG = 2048  # drawn large, then scaled down for smooth edges


def gradient(size):
    """Diagonal navy-to-green background."""
    img = Image.new('RGB', (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * (size - 1))
            px[x, y] = tuple(round(a + (b - a) * t) for a, b in zip(NAVY, GREEN))
    return img


def bubble(scale, white=True):
    """A speech bubble with three dots (green, navy, red), centred on a
    transparent square; [scale] is the bubble's width as part of the side."""
    img = Image.new('RGBA', (BIG, BIG), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    w = BIG * scale
    h = w * 0.72
    x0 = (BIG - w) / 2
    y0 = (BIG - h) / 2 - w * 0.06
    fill = WHITE if white else (255, 255, 255)
    d.rounded_rectangle([x0, y0, x0 + w, y0 + h], radius=h * 0.38, fill=fill)
    # The tail, at the lower right (the side a right-to-left reader ends on).
    d.polygon([(x0 + w * 0.66, y0 + h * 0.8), (x0 + w * 0.9, y0 + h * 1.22),
               (x0 + w * 0.86, y0 + h * 0.7)], fill=fill)
    if white:
        r = w * 0.075
        cy = y0 + h / 2
        for i, c in enumerate([FLAG_GREEN, NAVY, FLAG_RED]):
            cx = x0 + w * (0.29 + 0.21 * i)
            d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=c)
    return img


def tile(rounded, scale):
    """The full icon: background plus bubble."""
    bg = gradient(256).resize((BIG, BIG), Image.BICUBIC).convert('RGBA')
    if rounded:
        mask = Image.new('L', (BIG, BIG), 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, BIG, BIG], radius=BIG * 0.22, fill=255)
        bg.putalpha(mask)
    bg.alpha_composite(bubble(scale))
    return bg


def centered(img, part):
    """[img] shrunk to [part] of a transparent square."""
    out = Image.new('RGBA', (BIG, BIG), (0, 0, 0, 0))
    side = round(BIG * part)
    out.alpha_composite(img.resize((side, side), Image.LANCZOS), ((BIG - side) // 2,) * 2)
    return out


def save(img, path):
    path = APP / path
    size = Image.open(path).size if path.exists() else (BIG, BIG)
    out = img.resize(size, Image.LANCZOS)
    if path.suffix == '.webp':
        out.save(path, 'WEBP', quality=90)
    elif out.mode == 'RGBA' and path.name == 'icon.webp':
        out.convert('RGB').save(path)
    else:
        out.save(path, optimize=True)


def badge():
    """White silhouette for the notification badge."""
    img = bubble(0.8, white=False)
    return img


if __name__ == '__main__':
    full = tile(rounded=True, scale=0.58)
    bleed = tile(rounded=False, scale=0.5)
    res = APP / 'android/app/src/main/res'
    for p in res.glob('mipmap-*/ic_launcher.png'):
        save(full, p.relative_to(APP))
    save(bubble(0.42), 'android/app/src/main/res/drawable-xxxhdpi/ic_launcher_fg.png')
    for p in res.glob('drawable*/splash.webp'):
        save(centered(full, 0.62), p.relative_to(APP))
    for p in res.glob('drawable*/android12splash.webp'):
        save(centered(full, 0.5), p.relative_to(APP))
    save(centered(full, 0.62), 'branding/splash.png')
    save(centered(full, 0.5), 'branding/splash_android12.png')
    full_rgb = tile(rounded=False, scale=0.58)
    full_rgb.convert('RGB').resize((1024, 1024), Image.LANCZOS).save(APP / 'assets/brand/icon.webp', 'WEBP', quality=92)
    for name in ['Icon-192.png', 'Icon-512.png']:
        save(full, f'web/icons/{name}')
    for name in ['Icon-maskable-192.png', 'Icon-maskable-512.png', 'apple-touch-icon.png']:
        save(bleed, f'web/icons/{name}')
    save(full, 'web/favicon.png')
    save(badge(), 'web/icons/badge.png')
    print('done')
