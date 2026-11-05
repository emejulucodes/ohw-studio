#!/usr/bin/env python3
"""Build a custom watch face for the OHW-11 (SMA protocol, JieLi AC701N / "JL" platform).

Reimplemented from CO FIT 2.1.4.6 (static analysis, see docs/FINDINGS.md):
  * container  = libsmawatchface.so  buildWatchFace()   (old/"watchface1" path, mSupportWatchface2=0)
  * images     = libjl_bmp_convert.so br28_png_to_res / br28_bmp_to_res, no-pack mode
                 (BmpConvert type 4 = ARGB w/ alpha, type 3 = RGB)
  * layout     = DialCustomize410_502Activity (prototype AM08): 410x502 screen, 260x300 preview,
                 imageFormat 2, ignoreBlack 4, digit assets from dial_customize_360.

usage:
  face.py build BG.png OUT.bin [--color 0-6] [--hands 0-5] [--no-digital] [--ticks]
                [--widgets step,hr,kcal,dist] [--value-color 0-6] [--preview P.png]
  face.py render FACE.bin OUT_DIR        (decode a face file back to PNGs, for checking)
"""
import argparse, os, struct, sys
from PIL import Image, ImageDraw

SCREEN_W, SCREEN_H = 410, 502
PREVIEW_W, PREVIEW_H = 260, 300
IMAGE_FORMAT = 2          # WatchFaceBuilder.BMP_565, set by DialCustomize410_502Activity
IGNORE_BLACK = 4          # isSupportConvertPng -> 4
GRAVITY_TL = 9            # GRAVITY_X_LEFT(1) | GRAVITY_Y_TOP(8)
ASSETS = os.path.join(os.path.dirname(__file__), "..", "re", "apk", "raw", "assets", "dial_customize_360")

# element types (WatchFaceBuilder.ELEMENT_*)
PREVIEW, BACKGROUND, MONTH, DAY, HOUR, MINUTE, AMPM, WEEKDAY = 1, 2, 7, 8, 9, 10, 12, 13
NEEDLE_HOUR, NEEDLE_MIN, NEEDLE_SEC = 3, 4, 5
STEP, HEART, CALORIE, DISTANCE = 14, 15, 16, 17
GRAVITY_CENTER = 2 | 16    # DialCustomize410_502Activity X_CENTER=2, Y_CENTER=16
WIDGETS = {"step": (STEP, "step/step_0.png", "18564"), "hr": (HEART, "heart_rate/heart_rate_0.png", "90"),
           "kcal": (CALORIE, "calories/calories_0.png", "50"), "dist": (DISTANCE, "distance/distance_0.png", "6")}


# ---------------------------------------------------------------- JieLi RLE (Rle_Encode)
def rle_encode(row: bytes, unit: int, thr: int = 3) -> bytes:
    """Byte-exact port of libjl_bmp_convert Rle_Encode(src, len, dst, max, unit, thr)."""
    px = [row[i:i + unit] for i in range(0, len(row) - len(row) % unit, unit)]
    out, i, n = bytearray(), 0, len(px)
    while n > 0:
        first = px[i]
        # run lookahead: first `thr` units equal?
        streak, j = 0, 0
        while True:
            streak = streak + 1 if px[i + j] == first else 0
            if streak >= thr: break
            j += 1
            if j == thr or j >= n: break
        if streak >= thr:                          # run
            cnt = 0
            while cnt < n and cnt < 127 and px[i + cnt] == first:
                cnt += 1
            out.append(0x80 | cnt); out += first
        else:                                      # literal
            prev, rep, cnt, k = first, 0, None, 0
            while True:
                if k == n: cnt = n; break
                if px[i + k] == prev:
                    rep += 1
                    if rep == thr: cnt = k + 1 - thr; break
                else:
                    prev, rep = px[i + k], 1
                k += 1
                if k == 127: cnt = 127; break
            out.append(cnt)
            for q in range(cnt): out += px[i + q]
        i += cnt; n -= cnt
    return bytes(out)


def rle_decode(data: bytes, unit: int, npx: int) -> bytes:
    out, p = bytearray(), 0
    while len(out) < npx * unit and p < len(data):
        c = data[p]; p += 1
        if c & 0x80:
            out += data[p:p + unit] * (c & 0x7f); p += unit
        else:
            out += data[p:p + unit * c]; p += unit * c
    return bytes(out)


def rgb565(r, g, b) -> bytes:
    v = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
    return bytes([v >> 8, v & 0xff])


def jl_convert(img: Image.Image, alpha: bool) -> bytes:
    """br28_*_to_res (pack=0): [h x u32 offset|len<<21][RLE rows]; padded to 4 bytes."""
    img = img.convert("RGBA")
    w, h = img.size
    px = img.load()
    unit = 3 if alpha else 2
    rows = []
    for y in range(h):
        row = bytearray()
        for x in range(w):
            r, g, b, a = px[x, y]
            row += (bytes([a]) if alpha else b"") + rgb565(r, g, b)
        rows.append(rle_encode(bytes(row), unit))
    table, off = bytearray(), 4 * h
    for r in rows:
        assert len(r) < 2048, "row too long for 11-bit length field"
        table += struct.pack("<I", (off & 0x1FFFFF) | (len(r) << 21)); off += len(r)
    out = bytes(table) + b"".join(rows)
    return out + b"\0" * (-len(out) % 4)


def raw_argb8565(img: Image.Image) -> bytes:
    """getPointer2 (JL platform): uncompressed [A][RGB565 hi][lo] per pixel, rows padded to 4."""
    img = img.convert("RGBA"); w, h = img.size; px = img.load()
    stride = (w * 3 + 3) // 4 * 4
    out = bytearray()
    for y in range(h):
        row = bytearray()
        for x in range(w):
            r, g, b, a = px[x, y]; row += bytes([a]) + rgb565(r, g, b)
        out += row + b"\0" * (stride - len(row))
    return bytes(out)


def raw_decode(data: bytes, w: int, h: int) -> Image.Image:
    stride = (w * 3 + 3) // 4 * 4; img = Image.new("RGBA", (w, h))
    for y in range(h):
        for x in range(w):
            a, hi, lo = data[y * stride + 3 * x:y * stride + 3 * x + 3]; v = (hi << 8) | lo
            img.putpixel((x, y), (((v >> 11) & 31) << 3, ((v >> 5) & 63) << 2, (v & 31) << 3, a))
    return img


def jl_decode(data: bytes, w: int, h: int, alpha: bool) -> Image.Image:
    unit = 3 if alpha else 2
    img = Image.new("RGBA", (w, h))
    for y in range(h):
        e = struct.unpack_from("<I", data, 4 * y)[0]
        off, ln = e & 0x1FFFFF, e >> 21
        row = rle_decode(data[off:off + ln], unit, w)
        for x in range(min(w, len(row) // unit)):
            u = row[x * unit:(x + 1) * unit]
            a = u[0] if alpha else 255
            v = (u[-2] << 8) | u[-1]
            img.putpixel((x, y), (((v >> 11) & 31) << 3, ((v >> 5) & 63) << 2, (v & 31) << 3, a))
    return img


# ---------------------------------------------------------------- container (buildWatchFace)
class Element:
    def __init__(self, type_, has_alpha, w, h, gravity, x, y, images, ignore_black=IGNORE_BLACK,
                 play_interval=0, bottom_offset=0, left_offset=0):
        self.__dict__.update(locals()); del self.__dict__["self"]


def build_container(elements, image_format=IMAGE_FORMAT) -> bytes:
    n = len(elements)
    total_imgs = sum(len(e.images) for e in elements)
    head = struct.pack("<HBB", total_imgs, n, image_format)
    data_off = 4 + 20 * n + 4 * total_imgs
    recs, sizes, blobs, idx = bytearray(), bytearray(), bytearray(), 0
    for e in elements:
        t = e.type_ | (0x80 if e.has_alpha == 1 else 0)
        b18 = e.play_interval if e.play_interval else e.bottom_offset
        recs += struct.pack("<IHHHHHBBBBBB", data_off, idx, e.w, e.h, e.x, e.y,
                            len(e.images), t, e.gravity, e.ignore_black, b18, e.left_offset)
        for im in e.images:
            sizes += struct.pack("<I", len(im)); blobs += im; data_off += len(im)
        idx += len(e.images)
    return head + bytes(recs) + bytes(sizes) + bytes(blobs)


def parse_container(buf: bytes):
    total, n, fmt = struct.unpack_from("<HBB", buf, 0)
    els = []
    for i in range(n):
        off, idx, w, h, x, y, cnt, t, g, ib, b18, lo = struct.unpack_from("<IHHHHHBBBBBB", buf, 4 + 20 * i)
        els.append(dict(off=off, idx=idx, w=w, h=h, x=x, y=y, count=cnt, type=t & 0x7f,
                        alpha=bool(t & 0x80), gravity=g, ignore_black=ib))
    sizes = struct.unpack_from(f"<{total}I", buf, 4 + 20 * n)
    return dict(total=total, n=n, format=fmt, elements=els, sizes=sizes)


# ---------------------------------------------------------------- face layout
def asset(color, *parts):
    return Image.open(os.path.join(ASSETS, "time", "digital", str(color), *parts)).convert("RGBA")


def fit_background(path) -> Image.Image:
    src = Image.open(path).convert("RGB")
    # cover-crop to the screen aspect, like the app's crop step
    sw, sh = src.size; tr = SCREEN_W / SCREEN_H
    if sw / sh > tr:
        nw = int(sh * tr); src = src.crop(((sw - nw) // 2, 0, (sw - nw) // 2 + nw, sh))
    else:
        nh = int(sw / tr); src = src.crop((0, (sh - nh) // 2, sw, (sh - nh) // 2 + nh))
    return src.resize((SCREEN_W, SCREEN_H), Image.LANCZOS)


def control_asset(rel):
    return Image.open(os.path.join(ASSETS, "control", rel)).convert("RGBA")


def value_asset(color, d):
    return Image.open(os.path.join(ASSETS, "value", str(color), f"{d}.png")).convert("RGBA")


def hand_asset(kind, style):
    return Image.open(os.path.join(ASSETS, "time", "pointer", "pointer", kind, f"{style}.png")).convert("RGBA")


def draw_ticks(img, color=(255, 255, 255)):
    """Minute/hour tick ring around the hand pivot (the app bakes its scale image into the bg)."""
    d = ImageDraw.Draw(img); cx, cy = SCREEN_W / 2, SCREEN_H / 2
    import math
    for k in range(60):
        a = math.radians(k * 6); big = k % 5 == 0
        r0, r1 = (172 if big else 182), 192
        d.line([(cx + r0 * math.sin(a), cy - r0 * math.cos(a)), (cx + r1 * math.sin(a), cy - r1 * math.cos(a))],
               fill=color, width=5 if big else 2)


def build_face(bg_path, color=0, digital=True, hands=None, widgets=(), value_color=0, ticks=False,
               sample=(10, 9, 30)):
    """digital: show digital time/date; hands: pointer style 0-5 or None; widgets: subset of WIDGETS."""
    bg = fit_background(bg_path).convert("RGBA")
    if ticks: draw_ticks(bg)
    elements, previews = [], []          # previews: callables drawing a sample value on the preview

    # ---- widgets (getControl2 + addControlBitmap): icon baked into bg, live value element
    vals = [value_asset(value_color, d) for d in range(11)]
    vw, vh = vals[0].size
    analog = hands is not None
    n = len(widgets)
    row_y = (SCREEN_H - 128) if analog or not digital else 372
    span = 300 if n > 2 else 180
    for k, name in enumerate(widgets):
        t, icon_rel, demo = WIDGETS[name]
        icon = control_asset(icon_rel)
        cx = SCREEN_W // 2 if n == 1 else int(SCREEN_W / 2 - span / 2 + span * k / (n - 1))
        ix, iy = cx - icon.size[0] // 2, row_y
        bg.alpha_composite(icon, (ix, iy))
        vcx, vcy = cx, iy + icon.size[1] + 1 + vh // 2
        elements.append(Element(t, 1, vw, vh, GRAVITY_CENTER, vcx, vcy, [jl_convert(v, alpha=True) for v in vals]))
        def pv(img, demo=demo, vcx=vcx, vcy=vcy):
            x0 = vcx - (vw * len(demo) + len(demo) - 1) // 2
            for q, ch in enumerate(demo): img.alpha_composite(vals[int(ch)], (x0 + q * (vw + 1), vcy - vh // 2))
        previews.append(pv)

    # ---- digital time (getTimeDigital2)
    if digital:
        digits = [asset(color, "hour_minute", f"{d}.png") for d in range(10)]
        dw, dh = digits[0].size
        week = [asset(color, "week", f"{d}.png") for d in range(7)]
        date = [asset(color, "date", f"{d}.png") for d in range(10)]
        ampm = [asset(color, "am_pm", "am.png"), asset(color, "am_pm", "pm.png")]
        gap = 24
        hx, mx = SCREEN_W // 2 - gap // 2 - 2 * dw, SCREEN_W // 2 + gap // 2
        ty = 60 if analog else 190
        dy = ty + dh + 24
        spec = [(AMPM, ampm, hx, ty - ampm[0].size[1] - 12), (HOUR, digits, hx, ty), (MINUTE, digits, mx, ty),
                (MONTH, date, SCREEN_W // 2 - 2 * date[0].size[0] - 6, dy), (DAY, date, SCREEN_W // 2 + 6, dy),
                (WEEKDAY, week, (SCREEN_W - week[0].size[0]) // 2, dy + date[0].size[1] + 16)]
        if analog:   # keep the digital block small and above the pivot: time + weekday only
            spec = [e for e in spec if e[0] in (HOUR, MINUTE)]
        demo = {HOUR: f"{sample[0]:02d}", MINUTE: f"{sample[1]:02d}", MONTH: "11", DAY: "05"}
        for t, imgs, x, y in spec:
            w, h = imgs[0].size
            elements.append(Element(t, 1, w, h, GRAVITY_TL, x, y, [jl_convert(i, alpha=True) for i in imgs]))
            def pv(img, t=t, imgs=imgs, x=x, y=y):
                if t in demo:
                    for q, ch in enumerate(demo[t]): img.alpha_composite(imgs[int(ch)], (x + q * imgs[0].size[0], y))
                else: img.alpha_composite(imgs[4 if t == WEEKDAY else 0], (x, y))
            previews.append(pv)

    # ---- analog hands (getPointer2: raw ARGB8565, top 60% of the 300px asset, pivot at centre)
    if analog:
        import math
        cx, cy = SCREEN_W // 2, SCREEN_H // 2
        angles = {NEEDLE_HOUR: (sample[0] % 12 + sample[1] / 60) * 30, NEEDLE_MIN: sample[1] * 6, NEEDLE_SEC: sample[2] * 6}
        for t, kind in ((NEEDLE_HOUR, "hour"), (NEEDLE_MIN, "minute"), (NEEDLE_SEC, "second")):
            full = hand_asset(kind, hands); W, H = full.size
            h = int(H * 0.6); part = full.crop((0, 0, W, h))
            elements.append(Element(t, 1, W, h, GRAVITY_TL, cx, cy, [raw_argb8565(part)], ignore_black=1,
                                    bottom_offset=h - H // 2, left_offset=W // 2))
            def pv(img, full=full, a=angles[t]):
                W, H = full.size; sq = Image.new("RGBA", (H, H))
                sq.alpha_composite(full, ((H - W) // 2, 0))          # pad so rotation doesn't clip
                rot = sq.rotate(-a, resample=Image.BICUBIC, center=(H / 2, H / 2))
                img.alpha_composite(rot, (cx - H // 2, cy - H // 2))
            previews.append(pv)

    # ---- preview (bg + sample values) and background elements go first, like oldSendStream
    pv_img = bg.copy()
    for f in previews: f(pv_img)
    preview = pv_img.convert("RGB").resize((PREVIEW_W, PREVIEW_H), Image.LANCZOS)
    head = [Element(PREVIEW, 0, PREVIEW_W, PREVIEW_H, 0, 0, 0, [jl_convert(preview, alpha=False)]),
            Element(BACKGROUND, 0, SCREEN_W, SCREEN_H + 1, GRAVITY_TL, 0, 0, [jl_convert(bg, alpha=False)])]
    return build_container(head + elements), pv_img.convert("RGB")


def render(path, outdir):
    buf = open(path, "rb").read(); info = parse_container(buf)
    os.makedirs(outdir, exist_ok=True)
    print(f"images={info['total']} elements={info['n']} format={info['format']} bytes={len(buf)}")
    for e in info["elements"]:
        print(f"  type={e['type']:2} alpha={e['alpha']} {e['w']}x{e['h']} @({e['x']},{e['y']}) imgs={e['count']} grav={e['gravity']} off={e['off']}")
        off = e["off"]
        for k in range(e["count"]):
            sz = info["sizes"][e["idx"] + k]
            if e["type"] in (NEEDLE_HOUR, NEEDLE_MIN, NEEDLE_SEC):
                im = raw_decode(buf[off:off + sz], e["w"], e["h"])
            else:
                h = SCREEN_H if e["type"] == BACKGROUND else e["h"]
                im = jl_decode(buf[off:off + sz], e["w"], h, e["alpha"])
            im.save(f"{outdir}/t{e['type']}_{k}.png"); off += sz


if __name__ == "__main__":
    ap = argparse.ArgumentParser(); sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build"); b.add_argument("background"); b.add_argument("out")
    b.add_argument("--color", type=int, default=0, help="digital digit colour set 0-6")
    b.add_argument("--hands", type=int, choices=range(6), help="analog hand style 0-5")
    b.add_argument("--no-digital", action="store_true", help="hide digital time/date")
    b.add_argument("--widgets", default="", help="comma list of step,hr,kcal,dist")
    b.add_argument("--value-color", type=int, default=0, help="widget digit colour set 0-6")
    b.add_argument("--ticks", action="store_true", help="draw a minute tick ring")
    b.add_argument("--preview")
    r = sub.add_parser("render"); r.add_argument("face"); r.add_argument("outdir")
    a = ap.parse_args()
    if a.cmd == "build":
        ws = [w for w in a.widgets.split(",") if w]
        bad = [w for w in ws if w not in WIDGETS]
        if bad: sys.exit(f"unknown widget(s) {bad}; choose from {list(WIDGETS)}")
        data, pv = build_face(a.background, a.color, digital=not a.no_digital, hands=a.hands,
                              widgets=ws, value_color=a.value_color, ticks=a.ticks)
        open(a.out, "wb").write(data)
        if a.preview: pv.save(a.preview)
        print(f"wrote {a.out}: {len(data)} bytes")
    else:
        render(a.face, a.outdir)
