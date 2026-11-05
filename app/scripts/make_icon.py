"""Render the OHW Studio app icon (1024px master + .iconset sizes). usage: make_icon.py OUT_DIR"""
import math, os, sys
from PIL import Image, ImageDraw, ImageFilter

S = 1024
out = sys.argv[1]
os.makedirs(out, exist_ok=True)

def icon():
    im = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    # macOS squircle-ish base with gradient
    base = Image.new("RGBA", (S, S))
    g = ImageDraw.Draw(base)
    for y in range(S):
        t = y / S
        g.line([(0, y), (S, y)], fill=(int(28 + 20 * t), int(22 + 10 * t), int(48 + 30 * t), 255))
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([90, 90, S - 90, S - 90], radius=190, fill=255)
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse([180, 120, 860, 760], fill=(255, 150, 20, 150))
    gd.ellipse([300, 420, 980, 1000], fill=(94, 92, 230, 140))
    glow = glow.filter(ImageFilter.GaussianBlur(120))
    base.alpha_composite(glow)
    im.paste(base, (0, 0), mask)
    d = ImageDraw.Draw(im)
    # watch body
    cx, cy = S // 2, S // 2 + 10
    d.rounded_rectangle([cx - 120, cy - 330, cx + 120, cy - 200], radius=40, fill=(20, 20, 24, 255))
    d.rounded_rectangle([cx - 120, cy + 200, cx + 120, cy + 330], radius=40, fill=(20, 20, 24, 255))
    d.rounded_rectangle([cx - 210, cy - 250, cx + 210, cy + 250], radius=110, fill=(58, 58, 64, 255))
    d.rounded_rectangle([cx - 190, cy - 230, cx + 190, cy + 230], radius=96, fill=(6, 6, 8, 255))
    d.rounded_rectangle([cx + 205, cy - 90, cx + 235, cy - 10], radius=12, fill=(110, 110, 118, 255))
    # pulse line on the screen
    pts = [(cx - 150, cy + 20), (cx - 70, cy + 20), (cx - 40, cy - 70), (cx - 5, cy + 110), (cx + 35, cy - 130),
           (cx + 65, cy + 20), (cx + 150, cy + 20)]
    line = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ld = ImageDraw.Draw(line)
    ld.line(pts, fill=(255, 159, 10, 255), width=34, joint="curve")
    blur = line.filter(ImageFilter.GaussianBlur(18))
    im.alpha_composite(blur); im.alpha_composite(line)
    for p in (pts[0], pts[-1]):
        d.ellipse([p[0] - 17, p[1] - 17, p[0] + 17, p[1] + 17], fill=(255, 159, 10, 255))
    return im

master = icon()
master.save(os.path.join(out, "icon_1024.png"))
iconset = os.path.join(out, "AppIcon.iconset")
os.makedirs(iconset, exist_ok=True)
for s in (16, 32, 128, 256, 512):
    master.resize((s, s), Image.LANCZOS).save(os.path.join(iconset, f"icon_{s}x{s}.png"))
    master.resize((s * 2, s * 2), Image.LANCZOS).save(os.path.join(iconset, f"icon_{s}x{s}@2x.png"))
print("icon ok")
