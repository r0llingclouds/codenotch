#!/usr/bin/env python3
"""Generates the app icon (a white notch, tilted, with two usage rings, on a mint rounded square) into
Sources/Assets.xcassets, and the same icon for the Windows port into windows/codenotch/icons.
Drawn entirely in code; no third-party artwork. Requires Pillow. Usage: Scripts/make_icon.py"""
import math, os
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Sources", "Assets.xcassets", "AppIcon.appiconset")
WINDOWS = os.path.join(ROOT, "windows", "codenotch", "icons")

INK = (0x10, 0xA8, 0x84, 255)
PALE = (0xC3, 0xF0, 0xE2, 255)
USAGE = (0.73, 0.30)                        # how full each ring is

def ring(d, cx, cy, r, w, used):
    """A usage ring as the notch draws it: a full track, then the reading clockwise from 12 o'clock with round caps."""
    box = (cx - r - w / 2, cy - r - w / 2, cx + r + w / 2, cy + r + w / 2)
    d.arc(box, 0, 360, fill=PALE, width=round(w))
    start, end = -90, -90 + 360 * used
    d.arc(box, start, end, fill=INK, width=round(w))
    for a in (start, end):
        px, py = cx + r * math.cos(math.radians(a)), cy + r * math.sin(math.radians(a))
        d.ellipse((px - w / 2, py - w / 2, px + w / 2, py + w / 2), fill=INK)

def notch(n, s):
    """The notch on its own transparent layer: a white pill holding one ring per provider, each over its percentage."""
    layer = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    cx = 512 * s
    d.rounded_rectangle((357 * s, 212 * s, 667 * s, 812 * s), radius=100 * s, fill=(255, 255, 255, 255))
    y = 269 * s                             # top of the first ring
    for used in USAGE:
        ring(d, cx, y + 85 * s, 70 * s, 30 * s, used)
        d.rounded_rectangle((cx - 48 * s, y + 192 * s, cx + 48 * s, y + 218 * s), radius=13 * s, fill=PALE)
        y += 268 * s
    return layer.rotate(7, resample=Image.BICUBIC, center=(n / 2, n / 2))

def render():
    s = 4                                   # supersampling
    n = 1024 * s
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    # vertical gradient, masked by the macOS icon squircle (824pt body inside a 1024 canvas)
    top, bottom = (0x4F, 0xE3, 0xB4), (0x0C, 0x9E, 0x7E)
    grad = Image.new("RGBA", (1, n))
    for y in range(n):
        t = y / (n - 1)
        grad.putpixel((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,))
    grad = grad.resize((n, n))
    mask = Image.new("L", (n, n), 0)
    inset, radius = 100 * s, 186 * s
    ImageDraw.Draw(mask).rounded_rectangle((inset, inset, n - inset, n - inset), radius=radius, fill=255)
    img.paste(grad, (0, 0), mask)
    pill = notch(n, s)
    # soft shadow under the notch, clipped to the squircle
    shadow = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    shadow.paste((0x03, 0x45, 0x38, 115), (0, 18 * s), pill.split()[3])
    shadow = shadow.filter(ImageFilter.GaussianBlur(22 * s))
    clipped = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    clipped.paste(shadow, (0, 0), mask)
    img = Image.alpha_composite(img, clipped)
    return Image.alpha_composite(img, pill)

master = render()
for size in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
        px = size * scale
        master.resize((px, px), Image.LANCZOS).save(os.path.join(OUT, name))
# Windows: the installer's icon, and its 32x32 frame as the tray mark (see trayicon.rs)
ico = os.path.join(WINDOWS, "icon.ico")
master.resize((1024, 1024), Image.LANCZOS).save(ico, sizes=[(n, n) for n in (16, 24, 32, 48, 64, 128, 256)])
Image.open(ico).ico.getimage((32, 32)).save(os.path.join(WINDOWS, "tray-color.png"))
print(OUT)
print(WINDOWS)
