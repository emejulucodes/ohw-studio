#!/usr/bin/env python3
""""Pro" watch face for the OHW-11: true-black, thin large time, accent date line and four rounded
complication cards (steps / heart / calories / distance) with custom anti-aliased glyphs.

Uses the container/encoder from face.py; all imagery is generated here (no CO FIT assets).

usage: pro_face.py OUT.bin [--preview P.png] [--accent RRGGBB] [--wallpaper IMG]
"""
import argparse, math, os, sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont
sys.path.insert(0, os.path.dirname(__file__))
import face as F

W, H = F.SCREEN_W, F.SCREEN_H
SS = 4                                   # supersampling factor for smooth edges
HN = "/System/Library/Fonts/HelveticaNeue.ttc"
THIN, LIGHT, REG, MED, BOLD = 12, 7, 0, 10, 1   # HelveticaNeue.ttc face indices

WHITE = (255, 255, 255)
GREY = (142, 142, 147)
CARD = (28, 28, 30)
COLORS = {"step": (48, 209, 88), "hr": (255, 69, 58), "kcal": (255, 159, 10), "dist": (100, 210, 255)}
WEEK = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]       # element index 0 = Sunday


def font(idx, px):
    return ImageFont.truetype(HN, px * SS, index=idx)


def down(img):
    return img.resize((img.width // SS, img.height // SS), Image.LANCZOS)


def glyph_set(chars, fidx, px, color, cell_w=None, pad=0):
    """Render each string in `chars` into same-size RGBA cells (monospaced, baseline-aligned)."""
    f = font(fidx, px)
    boxes = [f.getbbox(c) for c in chars]
    top = min(b[1] for b in boxes); bot = max(b[3] for b in boxes)
    cw = cell_w * SS if cell_w else max(b[2] - b[0] for b in boxes) + 2 * pad * SS
    ch = bot - top + 2 * pad * SS
    out = []
    for c, b in zip(chars, boxes):
        im = Image.new("RGBA", (cw, ch), (0, 0, 0, 0))
        d = ImageDraw.Draw(im)
        x = (cw - (b[2] - b[0])) // 2 - b[0]
        d.text((x, pad * SS - top), c, font=f, fill=color + (255,))
        out.append(down(im))
    return out


def rrect(d, box, r, fill):
    d.rounded_rectangle([v * SS for v in box], radius=r * SS, fill=fill)


# ---------------------------------------------------------------- vector icons (drawn at SS scale)
def icon_ss(name, s, color):
    """Simple flat icons, drawn directly at supersampled size s (downsampled with the bg)."""
    im = Image.new("RGBA", (s, s), (0, 0, 0, 0)); d = ImageDraw.Draw(im); c = color + (255,)
    hole = (0, 0, 0, 0)
    if name == "hr":                                   # heart: two lobes + point
        pts = []
        for k in range(361):
            t = math.radians(k)
            x = 16 * math.sin(t) ** 3
            y = 13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t)
            pts.append((s * (0.5 + x / 36), s * (0.47 - y / 36)))
        d.polygon(pts, fill=c)
    elif name == "kcal":                               # flame: teardrop with inner cut
        def bez(p0, p1, p2, p3, n=40):
            return [((1-t)**3*p0[0]+3*(1-t)**2*t*p1[0]+3*(1-t)*t*t*p2[0]+t**3*p3[0],
                     (1-t)**3*p0[1]+3*(1-t)**2*t*p1[1]+3*(1-t)*t*t*p2[1]+t**3*p3[1]) for t in (i/n for i in range(n+1))]
        outer = (bez((0.5, 0.96), (0.18, 0.96), (0.12, 0.6), (0.32, 0.4)) +
                 bez((0.32, 0.4), (0.42, 0.3), (0.44, 0.18), (0.5, 0.03)) +
                 bez((0.5, 0.03), (0.68, 0.2), (0.88, 0.45), (0.84, 0.68)) +
                 bez((0.84, 0.68), (0.82, 0.88), (0.68, 0.96), (0.5, 0.96)))
        d.polygon([(x * s, y * s) for x, y in outer], fill=c)
        inner = (bez((0.5, 0.9), (0.36, 0.9), (0.34, 0.74), (0.43, 0.64)) +
                 bez((0.43, 0.64), (0.48, 0.58), (0.5, 0.52), (0.52, 0.46)) +
                 bez((0.52, 0.46), (0.62, 0.58), (0.68, 0.7), (0.64, 0.8)) +
                 bez((0.64, 0.8), (0.61, 0.88), (0.56, 0.9), (0.5, 0.9)))
        d.polygon([(x * s, y * s) for x, y in inner], fill=hole)
    elif name == "step":                               # two footprints
        for ox, oy in ((0.2, 0.08), (0.54, 0.34)):
            d.ellipse([s * ox, s * oy, s * (ox + 0.24), s * (oy + 0.38)], fill=c)
            d.ellipse([s * (ox + 0.04), s * (oy + 0.42), s * (ox + 0.2), s * (oy + 0.58)], fill=c)
    elif name == "dist":                               # location pin
        d.ellipse([s * 0.2, s * 0.04, s * 0.8, s * 0.64], fill=c)
        d.polygon([(s * 0.24, s * 0.46), (s * 0.76, s * 0.46), (s * 0.5, s * 0.97)], fill=c)
        d.ellipse([s * 0.38, s * 0.22, s * 0.62, s * 0.46], fill=hole)
    return im


def build(out, preview_path=None, accent=(255, 159, 10), wallpaper=None):
    # ------------------------------------------------ background (drawn at SS)
    bg = Image.new("RGBA", (W * SS, H * SS), (0, 0, 0, 255))
    if wallpaper:                                       # optional dimmed, blurred photo behind
        wp = F.fit_background(wallpaper).filter(ImageFilter.GaussianBlur(6)).convert("RGBA")
        wp = Image.blend(Image.new("RGBA", wp.size, (0, 0, 0, 255)), wp, 0.35)
        bg = wp.resize(bg.size, Image.LANCZOS)
    else:                                               # subtle top glow so the black isn't flat
        glow = Image.new("L", (W * SS, H * SS), 0); gd = ImageDraw.Draw(glow)
        gd.ellipse([-W * SS * 0.3, -H * SS * 0.55, W * SS * 1.3, H * SS * 0.45], fill=38)
        glow = glow.filter(ImageFilter.GaussianBlur(60 * SS))
        tint = Image.new("RGBA", bg.size, accent + (255,)); bg = Image.composite(tint, bg, glow)
    d = ImageDraw.Draw(bg)

    M = 26                                              # side margin
    # time block metrics
    tdig = glyph_set([str(i) for i in range(10)], THIN, 132, WHITE, pad=0)
    tw, th = tdig[0].size
    colon_w = 30
    time_w = 4 * tw + colon_w
    tx = (W - time_w) // 2
    ty = 74
    hx, mx = tx, tx + 2 * tw + colon_w
    # colon baked into bg (two soft dots)
    cx = tx + 2 * tw + colon_w // 2
    for cy in (ty + th * 0.33, ty + th * 0.72):
        r = 6.2
        d.ellipse([(cx - r) * SS, (cy - r) * SS, (cx + r) * SS, (cy + r) * SS], fill=WHITE + (255,))

    # date line: "THU" (accent) + day number (white), AM/PM on the right
    week = glyph_set(WEEK, MED, 26, accent, pad=1)
    ddig = glyph_set([str(i) for i in range(10)], MED, 26, WHITE, pad=1)
    ampm = glyph_set(["AM", "PM"], MED, 22, GREY, pad=1)
    wx, wy = M + 8, 34
    dx = wx + week[0].size[0] + 8
    ax, ay = W - M - 8 - ampm[0].size[0], wy + (week[0].size[1] - ampm[0].size[1]) // 2

    # hairline divider
    dv = ty + th + 22
    d.rounded_rectangle([M * SS, dv * SS, (W - M) * SS, dv * SS + 2 * SS], radius=SS, fill=(58, 58, 60, 255))

    # complication cards (2 x 2)
    gap = 12
    cw = (W - 2 * M - gap) // 2
    top = dv + 16
    chh = (H - 36 - top - gap) // 2
    cards = [("step", "STEPS", 0, 0), ("hr", "BPM", 1, 0), ("kcal", "KCAL", 0, 1), ("dist", "KM", 1, 1)]
    label_f = font(MED, 15)
    elements, pv_draw = [], []
    for key, label, col, row in cards:
        x0 = M + col * (cw + gap); y0 = top + row * (chh + gap)
        rrect(d, (x0, y0, x0 + cw, y0 + chh), 24, CARD + (255,))
        ic_s = 30 * SS; ic = Image.new("RGBA", (ic_s, ic_s)); ic.alpha_composite(icon_ss(key, ic_s, COLORS[key]))
        bg.alpha_composite(ic, ((x0 + 14) * SS, (y0 + 12) * SS))
        lb = label_f.getbbox(label)
        d.text(((x0 + cw - 16) * SS - (lb[2] - lb[0]), (y0 + 18) * SS - lb[1]), label, font=label_f, fill=GREY + (255,))
        # digits 0-9 + "." (index 10) share one cell size and baseline
        vals = glyph_set([str(i) for i in range(10)] + ["."], MED, 42, COLORS[key] if key != "step" else WHITE, pad=0)
        vw, vh = vals[0].size
        vcx, vcy = x0 + cw // 2, y0 + chh - 14 - vh // 2
        elements.append(F.Element({"step": F.STEP, "hr": F.HEART, "kcal": F.CALORIE, "dist": F.DISTANCE}[key],
                                  1, vw, vh, F.GRAVITY_CENTER, vcx, vcy, [F.jl_convert(v, alpha=True) for v in vals]))
        demo = {"step": "8412", "hr": "72", "kcal": "326", "dist": "5.4"}[key]
        def pv(img, vals=vals, demo=demo, vcx=vcx, vcy=vcy, vw=vw, vh=vh):
            idx = [10 if ch == "." else int(ch) for ch in demo]
            x = vcx - vw * len(idx) // 2
            for q, k in enumerate(idx): img.alpha_composite(vals[k], (x + q * vw, vcy - vh // 2))
        pv_draw.append(pv)

    bg = down(bg)

    # time / date elements
    elements += [
        F.Element(F.WEEKDAY, 1, *week[0].size, F.GRAVITY_TL, wx, wy, [F.jl_convert(i, alpha=True) for i in week]),
        F.Element(F.DAY, 1, *ddig[0].size, F.GRAVITY_TL, dx, wy, [F.jl_convert(i, alpha=True) for i in ddig]),
        F.Element(F.AMPM, 1, *ampm[0].size, F.GRAVITY_TL, ax, ay, [F.jl_convert(i, alpha=True) for i in ampm]),
        F.Element(F.HOUR, 1, tw, th, F.GRAVITY_TL, hx, ty, [F.jl_convert(i, alpha=True) for i in tdig]),
        F.Element(F.MINUTE, 1, tw, th, F.GRAVITY_TL, mx, ty, [F.jl_convert(i, alpha=True) for i in tdig]),
    ]

    # preview at 10:09, THU 05
    pv = bg.copy()
    pv.alpha_composite(week[4], (wx, wy))
    for q, ch in enumerate("05"): pv.alpha_composite(ddig[int(ch)], (dx + q * ddig[0].size[0], wy))
    pv.alpha_composite(ampm[0], (ax, ay))
    for q, ch in enumerate("10"): pv.alpha_composite(tdig[int(ch)], (hx + q * tw, ty))
    for q, ch in enumerate("09"): pv.alpha_composite(tdig[int(ch)], (mx + q * tw, ty))
    for f in pv_draw: f(pv)

    preview = pv.convert("RGB").resize((F.PREVIEW_W, F.PREVIEW_H), Image.LANCZOS)
    head = [F.Element(F.PREVIEW, 0, F.PREVIEW_W, F.PREVIEW_H, 0, 0, 0, [F.jl_convert(preview, alpha=False)]),
            F.Element(F.BACKGROUND, 0, W, H + 1, F.GRAVITY_TL, 0, 0, [F.jl_convert(bg, alpha=False)])]
    data = F.build_container(head + elements)
    open(out, "wb").write(data)
    if preview_path:
        # show the rounded screen mask so the preview matches what the glass shows
        mask = Image.new("L", (W, H), 0); ImageDraw.Draw(mask).rounded_rectangle([0, 0, W - 1, H - 1], radius=80, fill=255)
        shown = Image.new("RGB", (W, H), (60, 60, 60)); shown.paste(pv.convert("RGB"), (0, 0), mask)
        shown.save(preview_path)
    print(f"wrote {out}: {len(data)} bytes, {len(elements) + 2} elements")


def shadowed(glyphs, radius=3, strength=170):
    """Add a soft dark drop shadow into each glyph's alpha so text reads over photos."""
    out = []
    for g in glyphs:
        a = g.getchannel("A")
        sh = Image.new("RGBA", g.size, (0, 0, 0, 0))
        sh.putalpha(a.filter(ImageFilter.GaussianBlur(radius)).point(lambda v: min(255, v * strength // 255 * 2)))
        sh.alpha_composite(g)
        out.append(sh)
    return out


def build_photo(out, photo, preview_path=None, accent=(255, 159, 10), focus=0.35):
    """Photo-forward layout: sharp full-screen photo, info block over a bottom gradient."""
    from PIL import ImageOps
    src = ImageOps.exif_transpose(Image.open(photo)).convert("RGB")
    sw, sh = src.size; tr = W / H
    if sw / sh > tr:
        nw = int(sh * tr); x0 = int((sw - nw) * 0.5); src = src.crop((x0, 0, x0 + nw, sh))
    else:
        nh = int(sw / tr); y0 = int((sh - nh) * focus); src = src.crop((0, y0, sw, y0 + nh))
    bg = src.resize((W, H), Image.LANCZOS).convert("RGBA")

    # bottom gradient for legibility
    grad = Image.new("L", (1, H), 0)
    for y in range(H):
        t = max(0.0, (y - H * 0.5) / (H * 0.5)); grad.putpixel((0, y), int(215 * t ** 1.4))
    shade = Image.new("RGBA", (W, H), (0, 0, 0, 255)); shade.putalpha(grad.resize((W, H)))
    bg.alpha_composite(shade)

    M = 34
    tdig = shadowed(glyph_set([str(i) for i in range(10)], LIGHT, 112, WHITE))
    tw, th = tdig[0].size
    colon_w = 26
    tx, ty = M - 4, H - 64 - th - 34
    hx, mx = tx, tx + 2 * tw + colon_w
    # colon dots (with shadow) baked into the bg
    dots = Image.new("RGBA", (W * SS, H * SS), (0, 0, 0, 0)); dd = ImageDraw.Draw(dots)
    ccx = tx + 2 * tw + colon_w / 2
    for cy in (ty + th * 0.36, ty + th * 0.72):
        r = 5.5; dd.ellipse([(ccx - r) * SS, (cy - r) * SS, (ccx + r) * SS, (cy + r) * SS], fill=(255, 255, 255, 255))
    dots = down(dots)
    bg.alpha_composite(shadowed([dots])[0])

    week = shadowed(glyph_set(WEEK, BOLD, 24, accent, pad=1))
    ddig = shadowed(glyph_set([str(i) for i in range(10)], BOLD, 24, WHITE, pad=1))
    ampm = shadowed(glyph_set(["AM", "PM"], MED, 22, (230, 230, 235), pad=1))
    wx, wy = M, ty - week[0].size[1] - 4
    dx = wx + week[0].size[0] + 6
    ax, ay = mx + 2 * tw + 8, ty + th - ampm[0].size[1] - 6

    # compact complications row: heart + steps
    row_y = H - 60
    elements, pvs = [], []
    small = [("hr", F.HEART, "72"), ("step", F.STEP, "8412")]
    x = M + 6
    for key, etype, demo in small:
        ic = Image.new("RGBA", (24 * SS, 24 * SS)); ic.alpha_composite(icon_ss(key, 24 * SS, COLORS[key]))
        ic = shadowed([down(ic)], radius=2)[0]
        bg.alpha_composite(ic, (x, row_y - 12))
        vals = shadowed(glyph_set([str(i) for i in range(10)] + ["."], MED, 26, WHITE), radius=2)
        vw, vh = vals[0].size
        vcx = x + 32 + (vw * len(demo)) // 2           # left-ish anchor; value is centred by the watch
        elements.append(F.Element(etype, 1, vw, vh, F.GRAVITY_CENTER, vcx, row_y, [F.jl_convert(v, alpha=True) for v in vals]))
        def pv(img, vals=vals, demo=demo, vcx=vcx, vw=vw, vh=vh):
            sx = vcx - vw * len(demo) // 2
            for q, ch in enumerate(demo): img.alpha_composite(vals[int(ch)], (sx + q * vw, row_y - vh // 2))
        pvs.append(pv)
        x += 32 + vw * 4 + 34

    elements += [
        F.Element(F.WEEKDAY, 1, *week[0].size, F.GRAVITY_TL, wx, wy, [F.jl_convert(i, alpha=True) for i in week]),
        F.Element(F.DAY, 1, *ddig[0].size, F.GRAVITY_TL, dx, wy, [F.jl_convert(i, alpha=True) for i in ddig]),
        F.Element(F.AMPM, 1, *ampm[0].size, F.GRAVITY_TL, ax, ay, [F.jl_convert(i, alpha=True) for i in ampm]),
        F.Element(F.HOUR, 1, tw, th, F.GRAVITY_TL, hx, ty, [F.jl_convert(i, alpha=True) for i in tdig]),
        F.Element(F.MINUTE, 1, tw, th, F.GRAVITY_TL, mx, ty, [F.jl_convert(i, alpha=True) for i in tdig]),
    ]
    pv = bg.copy()
    pv.alpha_composite(week[4], (wx, wy))
    for q, ch in enumerate("05"): pv.alpha_composite(ddig[int(ch)], (dx + q * ddig[0].size[0], wy))
    pv.alpha_composite(ampm[0], (ax, ay))
    for q, ch in enumerate("10"): pv.alpha_composite(tdig[int(ch)], (hx + q * tw, ty))
    for q, ch in enumerate("09"): pv.alpha_composite(tdig[int(ch)], (mx + q * tw, ty))
    for f in pvs: f(pv)
    preview = pv.convert("RGB").resize((F.PREVIEW_W, F.PREVIEW_H), Image.LANCZOS)
    head = [F.Element(F.PREVIEW, 0, F.PREVIEW_W, F.PREVIEW_H, 0, 0, 0, [F.jl_convert(preview, alpha=False)]),
            F.Element(F.BACKGROUND, 0, W, H + 1, F.GRAVITY_TL, 0, 0, [F.jl_convert(bg, alpha=False)])]
    data = F.build_container(head + elements)
    open(out, "wb").write(data)
    if preview_path:
        mask = Image.new("L", (W, H), 0); ImageDraw.Draw(mask).rounded_rectangle([0, 0, W - 1, H - 1], radius=80, fill=255)
        shown = Image.new("RGB", (W, H), (60, 60, 60)); shown.paste(pv.convert("RGB"), (0, 0), mask)
        shown.save(preview_path)
    print(f"wrote {out}: {len(data)} bytes, {len(elements) + 2} elements")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("out"); ap.add_argument("--preview")
    ap.add_argument("--accent", default="FF9F0A", help="accent colour RRGGBB for weekday + glow")
    ap.add_argument("--wallpaper", help="optional photo, blurred and dimmed behind the UI")
    ap.add_argument("--photo", help="photo layout: sharp full-screen photo, time over a bottom gradient")
    ap.add_argument("--focus", type=float, default=0.35, help="photo layout: vertical crop position 0=top 1=bottom")
    a = ap.parse_args()
    acc = tuple(int(a.accent[i:i + 2], 16) for i in (0, 2, 4))
    if a.photo:
        build_photo(a.out, a.photo, a.preview, acc, a.focus)
    else:
        build(a.out, a.preview, acc, a.wallpaper)
