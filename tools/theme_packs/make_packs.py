"""
สร้างชุดธีม (ภาพตกแต่ง + ไอคอน + pack.json) ของ ORAVELLE

- ภาพทั้งหมดวาดด้วยโค้ดในไฟล์นี้ (ไม่ได้ใช้ภาพ/ฟอนต์/ไอคอนของคนอื่น) → ใช้เชิงพาณิชย์ได้
- ผลลัพธ์: family_api/resources/themes/packs/<slug>/v<version>/
  pack.json = ข้อมูลล้วน (สี ความโค้ง ชื่อไฟล์) + รายการไฟล์พร้อม sha256 / ขนาด / ชนิด
- รัน: python -I tools/theme_packs/make_packs.py  (ต้องมี Pillow ที่รองรับ WebP)
"""
import hashlib
import io
import json
import math
import os
import random
import sys

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, 'family_api', 'resources', 'themes', 'packs')

SS = 3  # วาดใหญ่แล้วย่อ (ขอบเนียน)

# ภาพหัว (1080x420) วางใต้แถบหัวของหน้าหลัก: ซ้าย = รูปโปรไฟล์+ชื่อหน้า, ขวา (x>680) = ปุ่มไอคอน
# → ของตกแต่งชิ้นใหญ่วางได้เฉพาะช่องกลาง x 470..690 และแถบบนสุด (ไม่บังข้อความ/ปุ่ม)
GAP_X = (470, 690)


def rgba(hex_, a=255):
    hex_ = hex_.lstrip('#')
    return (int(hex_[0:2], 16), int(hex_[2:4], 16), int(hex_[4:6], 16), a)


def canvas(w, h, color=(0, 0, 0, 0)):
    return Image.new('RGBA', (w * SS, h * SS), color)


def finish(img, w, h):
    return img.resize((w, h), Image.LANCZOS)


def save(img, folder, name, quality=82):
    path = os.path.join(folder, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if name.endswith('.webp'):
        img.save(path, 'WEBP', quality=quality, method=6)
    else:
        img.save(path, 'PNG', optimize=True)
    return name


def vertical_gradient(w, h, top, bottom):
    img = Image.new('RGBA', (w, h))
    d = ImageDraw.Draw(img)
    for y in range(h):
        t = y / max(1, h - 1)
        c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(4))
        d.line([(0, y), (w, y)], fill=c)
    return img


def wave_band(w, h, base_y, amp, length, phase, color):
    """แถบคลื่นเต็มกว้าง จาก base_y ลงไปถึงล่างสุด"""
    layer = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    pts = []
    for x in range(0, w + 8, 8):
        y = base_y + amp * math.sin((x / length) * 2 * math.pi + phase)
        pts.append((x, y))
    pts += [(w, h), (0, h)]
    d.polygon(pts, fill=color)
    return layer


def leaf(d, cx, cy, length, width, angle, color, vein=None):
    pts = []
    n = 40
    for i in range(n + 1):
        t = i / n
        x = t * length
        y = math.sin(math.pi * t) * width / 2 * (1 - 0.25 * t)
        pts.append((x, y))
    for i in range(n, -1, -1):
        t = i / n
        x = t * length
        y = -math.sin(math.pi * t) * width / 2 * (1 - 0.25 * t)
        pts.append((x, y))
    ca, sa = math.cos(angle), math.sin(angle)
    poly = [(cx + x * ca - y * sa, cy + x * sa + y * ca) for x, y in pts]
    d.polygon(poly, fill=color)
    if vein:
        d.line([(cx, cy), (cx + length * 0.92 * ca, cy + length * 0.92 * sa)], fill=vein, width=max(2, int(width * 0.06)))


def branch(d, x, y, angle, length, leaves, colors, stem, scale):
    ca, sa = math.cos(angle), math.sin(angle)
    d.line([(x, y), (x + length * ca, y + length * sa)], fill=stem, width=int(5 * scale))
    for i in range(leaves):
        t = (i + 1) / (leaves + 1)
        px, py = x + length * t * ca, y + length * t * sa
        side = 1 if i % 2 == 0 else -1
        la = angle + side * 0.75
        size = length * (0.38 - 0.12 * t)
        leaf(d, px, py, size, size * 0.42, la, colors[i % len(colors)], vein=None)
    leaf(d, x + length * ca, y + length * sa, length * 0.3, length * 0.13, angle, colors[0])


def stars(img, count, seed, max_r, color=(255, 255, 255), glow=True):
    rnd = random.Random(seed)
    w, h = img.size
    layer = Image.new('RGBA', img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    for _ in range(count):
        x, y = rnd.uniform(0, w), rnd.uniform(0, h)
        r = rnd.uniform(0.3, 1.0) ** 3 * max_r + 0.6 * SS
        a = int(rnd.uniform(90, 255))
        d.ellipse([x - r, y - r, x + r, y + r], fill=color + (a,))
    if glow:
        img.alpha_composite(layer.filter(ImageFilter.GaussianBlur(2.2 * SS)))
    img.alpha_composite(layer)


def sparkle(d, x, y, r, color):
    """ดาวแฉก 4 แฉก"""
    pts = []
    for i in range(8):
        ang = i * math.pi / 4 - math.pi / 2
        rr = r if i % 2 == 0 else r * 0.32
        pts.append((x + rr * math.cos(ang), y + rr * math.sin(ang)))
    d.polygon(pts, fill=color)


def planet(img, cx, cy, r, c1, c2, ring=None, ring_tilt=-0.35):
    w, h = img.size
    body = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(body)
    steps = 60
    for i in range(steps):
        t = i / steps
        rr = r * (1 - t)
        c = tuple(int(c1[k] + (c2[k] - c1[k]) * t) for k in range(3)) + (255,)
        ox, oy = -r * 0.35 * t, -r * 0.35 * t
        d.ellipse([cx + ox - rr, cy + oy - rr, cx + ox + rr, cy + oy + rr], fill=c)
    mask = Image.new('L', (w, h), 0)
    ImageDraw.Draw(mask).ellipse([cx - r, cy - r, cx + r, cy + r], fill=255)
    clipped = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    clipped.paste(body, (0, 0), mask)
    if ring:
        ring_layer = Image.new('RGBA', (w, h), (0, 0, 0, 0))
        rd = ImageDraw.Draw(ring_layer)
        rw, rh = r * 2.1, r * 0.55
        rd.ellipse([cx - rw, cy - rh, cx + rw, cy + rh], outline=ring, width=int(r * 0.09))
        ring_layer = ring_layer.rotate(math.degrees(ring_tilt), center=(cx, cy), resample=Image.BICUBIC)
        # ครึ่งหลังของวงแหวนอยู่หลังดาว
        back = ring_layer.copy()
        front_mask = Image.new('L', (w, h), 0)
        ImageDraw.Draw(front_mask).rectangle([0, cy, w, h], fill=255)
        front = Image.new('RGBA', (w, h), (0, 0, 0, 0))
        front.paste(ring_layer, (0, 0), front_mask)
        img.alpha_composite(back)
        img.alpha_composite(clipped)
        img.alpha_composite(front)
    else:
        img.alpha_composite(clipped)


# =======================================================
# ไอคอนอวกาศ (ภาพขาวพื้นใส แอประบายสีเอง) — รูปทรงหลักเหมือนเดิม (บ้าน ตะกร้า ฯลฯ)
# =======================================================

ICON = 96
L = 4  # ขยายตอนวาด
LW = 26  # ความหนาเส้น (ที่ 384px)


def icon_canvas():
    return Image.new('RGBA', (ICON * L, ICON * L), (0, 0, 0, 0))


def icon_finish(img):
    return img.resize((ICON, ICON), Image.LANCZOS)


W = (255, 255, 255, 255)


def rounded_line(d, pts, width=LW):
    d.line(pts, fill=W, width=width, joint='curve')
    r = width / 2
    for x, y in (pts[0], pts[-1]):
        d.ellipse([x - r, y - r, x + r, y + r], fill=W)


def icon_home():
    img = icon_canvas()
    d = ImageDraw.Draw(img)
    rounded_line(d, [(48, 196), (192, 72), (336, 196)])
    d.rounded_rectangle([92, 176, 292, 330], radius=34, outline=W, width=LW)
    d.rounded_rectangle([166, 244, 218, 330], radius=12, fill=W)
    sparkle(d, 318, 66, 40, W)
    return icon_finish(img)


def icon_shop():
    img = icon_canvas()
    d = ImageDraw.Draw(img)
    d.arc([118, 60, 266, 210], 200, 340, fill=W, width=LW)
    d.polygon([(58, 162), (326, 162), (296, 318), (88, 318)], outline=W, width=LW)
    d.line([(58, 162), (326, 162)], fill=W, width=LW)
    for x in (148, 236):
        rounded_line(d, [(x, 208), (x, 272)], width=20)
    sparkle(d, 322, 70, 34, W)
    return icon_finish(img)


def icon_group():
    img = icon_canvas()
    d = ImageDraw.Draw(img)
    d.ellipse([150, 74, 234, 158], outline=W, width=LW)
    d.arc([104, 178, 280, 360], 200, 340, fill=W, width=LW)
    d.ellipse([56, 118, 120, 182], outline=W, width=20)
    d.ellipse([264, 118, 328, 182], outline=W, width=20)
    d.arc([22, 204, 140, 330], 205, 300, fill=W, width=20)
    d.arc([244, 204, 362, 330], 240, 335, fill=W, width=20)
    sparkle(d, 192, 40, 22, W)
    return icon_finish(img)


def icon_map():
    img = icon_canvas()
    d = ImageDraw.Draw(img)
    d.ellipse([112, 52, 272, 212], outline=W, width=LW)
    d.polygon([(124, 178), (260, 178), (192, 320)], fill=W)
    d.ellipse([150, 90, 234, 174], fill=(0, 0, 0, 0))
    d.ellipse([136, 76, 248, 188], fill=W)
    d.ellipse([164, 104, 220, 160], fill=(0, 0, 0, 0))
    ring = Image.new('RGBA', img.size, (0, 0, 0, 0))
    rd = ImageDraw.Draw(ring)
    rd.ellipse([40, 286, 344, 346], outline=W, width=18)
    img.alpha_composite(ring)
    return icon_finish(img)


def icon_activity():
    img = icon_canvas()
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([60, 84, 324, 330], radius=44, outline=W, width=LW)
    d.line([(60, 150), (324, 150)], fill=W, width=LW)
    for x in (124, 260):
        rounded_line(d, [(x, 52), (x, 112)], width=LW)
    sparkle(d, 192, 242, 58, W)
    return icon_finish(img)


def icon_search():
    img = icon_canvas()
    d = ImageDraw.Draw(img)
    d.ellipse([66, 60, 260, 254], outline=W, width=LW)
    rounded_line(d, [(238, 236), (322, 320)], width=LW + 6)
    sparkle(d, 162, 156, 34, W)
    return icon_finish(img)


def icon_chat():
    img = icon_canvas()
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([50, 66, 334, 270], radius=60, outline=W, width=LW)
    d.polygon([(110, 254), (172, 260), (96, 336)], fill=W)
    sparkle(d, 192, 168, 46, W)
    return icon_finish(img)


def icon_bell():
    img = icon_canvas()
    d = ImageDraw.Draw(img)
    d.arc([96, 70, 288, 262], 180, 360, fill=W, width=LW)
    d.line([(96, 166), (96, 252)], fill=W, width=LW)
    d.line([(288, 166), (288, 252)], fill=W, width=LW)
    rounded_line(d, [(60, 270), (96, 248)])
    rounded_line(d, [(324, 270), (288, 248)])
    rounded_line(d, [(60, 276), (324, 276)])
    d.chord([150, 286, 234, 352], 0, 180, fill=W)
    sparkle(d, 192, 44, 26, W)
    return icon_finish(img)


# =======================================================
# ธีม
# =======================================================

THEMES = []


def ocean(folder):
    files = {}
    # หัว: คลื่นจาง ๆ
    for mode, top, waves in (
        ('light', rgba('#DCEBFB', 255), [rgba('#CFE4FA', 255), rgba('#E4F0FC', 255), rgba('#F3F8FD', 255)]),
        ('dark', rgba('#0E2238', 255), [rgba('#13304D', 255), rgba('#0F2740', 255), rgba('#0A1622', 255)]),
    ):
        w, h = 1080, 420
        img = canvas(w, h)
        img.alpha_composite(vertical_gradient(w * SS, h * SS, top, top[:3] + (0,)))
        for i, color in enumerate(waves):
            img.alpha_composite(wave_band(w * SS, h * SS, (190 + i * 70) * SS, 26 * SS, 760 * SS, i * 1.7, color[:3] + (150 - i * 40,)))
        d = ImageDraw.Draw(img)
        rnd = random.Random(7)
        for _ in range(9):
            x, y, r = rnd.uniform(*GAP_X) * SS, rnd.uniform(30, 200) * SS, rnd.uniform(5, 16) * SS
            c = (255, 255, 255, 120) if mode == 'light' else (120, 190, 255, 70)
            d.ellipse([x - r, y - r, x + r, y + r], outline=c, width=int(2.5 * SS))
        files['header_' + mode] = save(finish(img, w, h), folder, 'header_%s.webp' % mode)
    # พื้นหลัง: คลื่นด้านล่าง
    for mode, base, wave in (('light', rgba('#F3F8FD'), rgba('#E2EEFA')), ('dark', rgba('#0A1622'), rgba('#0F2232'))):
        w, h = 1080, 1920
        img = canvas(w, h, base)
        for i in range(3):
            img.alpha_composite(wave_band(w * SS, h * SS, (1500 + i * 120) * SS, 30 * SS, 820 * SS, i * 2.1, wave[:3] + (200 - i * 50,)))
        files['bg_' + mode] = save(finish(img, w, h), folder, 'bg_%s.webp' % mode)
    # หน้าว่าง: เรือใบ + คลื่น + พระอาทิตย์
    w, h = 600, 420
    img = canvas(w, h)
    d = ImageDraw.Draw(img)
    d.ellipse([400 * SS, 40 * SS, 500 * SS, 140 * SS], fill=rgba('#FFD166'))
    d.polygon([(290 * SS, 90 * SS), (290 * SS, 260 * SS), (190 * SS, 260 * SS)], fill=rgba('#7FB8F0'))
    d.polygon([(300 * SS, 120 * SS), (300 * SS, 260 * SS), (380 * SS, 260 * SS)], fill=rgba('#B9DAF8'))
    d.line([(295 * SS, 80 * SS), (295 * SS, 280 * SS)], fill=rgba('#3C6F9E'), width=6 * SS)
    d.polygon([(170 * SS, 280 * SS), (420 * SS, 280 * SS), (385 * SS, 320 * SS), (205 * SS, 320 * SS)], fill=rgba('#1F7AE0'))
    for i, c in enumerate([rgba('#5AA9FF', 230), rgba('#1F7AE0', 200)]):
        img.alpha_composite(wave_band(w * SS, h * SS, (318 + i * 30) * SS, 12 * SS, 180 * SS, i * 1.3, c))
    files['empty'] = save(finish(img, w, h), folder, 'empty.webp')
    # พื้นหลังแชท: ฟองอากาศจาง
    for mode, base, bubble in (('light', rgba('#EEF5FC'), (255, 255, 255, 170)), ('dark', rgba('#0B1826'), (90, 160, 230, 45))):
        w, h = 1080, 1920
        img = canvas(w, h, base)
        d = ImageDraw.Draw(img)
        rnd = random.Random(21)
        for _ in range(70):
            x, y, r = rnd.uniform(0, w) * SS, rnd.uniform(0, h) * SS, rnd.uniform(6, 26) * SS
            d.ellipse([x - r, y - r, x + r, y + r], outline=bubble, width=int(3 * SS))
        files['chat_' + mode] = save(finish(img, w, h), folder, 'chat_%s.webp' % mode)
    return files


def matcha(folder):
    files = {}
    greens = {
        'light': [rgba('#7FA868'), rgba('#A9C48E'), rgba('#5E8A4A'), rgba('#C3D6A7')],
        'dark': [rgba('#3E5A31'), rgba('#4F6E3E'), rgba('#2F4626'), rgba('#5F7D4B')],
    }
    stems = {'light': rgba('#8A6F4D'), 'dark': rgba('#4E4030')}
    for mode, top in (('light', rgba('#EEF0DA')), ('dark', rgba('#1C2416'))):
        w, h = 1080, 420
        img = canvas(w, h)
        img.alpha_composite(vertical_gradient(w * SS, h * SS, top, top[:3] + (0,)))
        layer = Image.new('RGBA', img.size, (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        branch(d, 600 * SS, -30 * SS, math.radians(118), 210 * SS, 5, greens[mode], stems[mode], SS)
        branch(d, 610 * SS, -20 * SS, math.radians(62), 170 * SS, 4, greens[mode][1:], stems[mode], SS)
        rnd = random.Random(13)
        for x in list(range(250, 430, 45)) + list(range(720, 830, 45)):
            leaf(d, x * SS, rnd.uniform(8, 34) * SS, rnd.uniform(26, 40) * SS, 12 * SS, rnd.uniform(-0.6, 0.6), greens[mode][rnd.randrange(4)])
        layer.putalpha(layer.getchannel('A').point(lambda a: int(a * (0.85 if mode == 'light' else 0.7))))
        img.alpha_composite(layer)
        files['header_' + mode] = save(finish(img, w, h), folder, 'header_%s.webp' % mode)
    for mode, base in (('light', rgba('#F7F3E8')), ('dark', rgba('#14170F'))):
        w, h = 1080, 1920
        img = canvas(w, h, base)
        layer = Image.new('RGBA', img.size, (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        branch(d, -40 * SS, 1960 * SS, math.radians(-55), 520 * SS, 8, greens[mode], stems[mode], SS)
        branch(d, 1120 * SS, 1900 * SS, math.radians(-125), 460 * SS, 7, greens[mode][1:] + greens[mode][:1], stems[mode], SS)
        layer.putalpha(layer.getchannel('A').point(lambda a: int(a * (0.55 if mode == 'light' else 0.5))))
        img.alpha_composite(layer)
        dots = ImageDraw.Draw(img)
        rnd = random.Random(5)
        dot = (180, 170, 140, 60) if mode == 'light' else (120, 140, 90, 50)
        for _ in range(140):
            x, y = rnd.uniform(0, w) * SS, rnd.uniform(0, h) * SS
            r = rnd.uniform(1.5, 3.2) * SS
            dots.ellipse([x - r, y - r, x + r, y + r], fill=dot)
        files['bg_' + mode] = save(finish(img, w, h), folder, 'bg_%s.webp' % mode)
    # หน้าว่าง: ถ้วยชาเขียว + ไอน้ำ + ใบไม้
    w, h = 600, 420
    img = canvas(w, h)
    d = ImageDraw.Draw(img)
    d.ellipse([170 * SS, 330 * SS, 430 * SS, 372 * SS], fill=rgba('#D9CDAE', 160))
    d.chord([170 * SS, 150 * SS, 430 * SS, 360 * SS], 0, 180, fill=rgba('#E9E1CB'))
    d.ellipse([170 * SS, 228 * SS, 430 * SS, 272 * SS], fill=rgba('#7FA868'))
    d.ellipse([186 * SS, 236 * SS, 414 * SS, 264 * SS], fill=rgba('#93BA79'))
    for i, x in enumerate((250, 300, 350)):
        pts = [((x + 14 * math.sin(t / 6 + i)) * SS, (210 - t * 1.6) * SS) for t in range(0, 70, 3)]
        d.line(pts, fill=rgba('#B9C7A6', 200), width=6 * SS, joint='curve')
    leaf(d, 420 * SS, 190 * SS, 120 * SS, 52 * SS, math.radians(-35), rgba('#5E8A4A'), vein=rgba('#A9C48E'))
    leaf(d, 170 * SS, 200 * SS, 96 * SS, 42 * SS, math.radians(205), rgba('#7FA868'), vein=rgba('#C3D6A7'))
    files['empty'] = save(finish(img, w, h), folder, 'empty.webp')
    for mode, base, col in (('light', rgba('#F4EFE1'), (127, 168, 104, 55)), ('dark', rgba('#151A10'), (110, 140, 90, 40))):
        w, h = 1080, 1920
        img = canvas(w, h, base)
        d = ImageDraw.Draw(img)
        rnd = random.Random(11)
        for _ in range(46):
            x, y = rnd.uniform(0, w) * SS, rnd.uniform(0, h) * SS
            size = rnd.uniform(40, 90) * SS
            leaf(d, x, y, size, size * 0.42, rnd.uniform(0, 2 * math.pi), col)
        files['chat_' + mode] = save(finish(img, w, h), folder, 'chat_%s.webp' % mode)
    return files


def cosmic(folder):
    files = {}
    w, h = 1080, 1920
    img = canvas(w, h, rgba('#070A1A'))
    neb = Image.new('RGBA', img.size, (0, 0, 0, 0))
    nd = ImageDraw.Draw(neb)
    for cx, cy, r, c in ((200, 520, 420, rgba('#3B2A8C', 110)), (900, 1250, 480, rgba('#123A7A', 100)), (520, 1700, 380, rgba('#4A1E6E', 90))):
        nd.ellipse([(cx - r) * SS, (cy - r) * SS, (cx + r) * SS, (cy + r) * SS], fill=c)
    img.alpha_composite(neb.filter(ImageFilter.GaussianBlur(140 * SS)))
    stars(img, 520, 3, 2.6 * SS)
    d = ImageDraw.Draw(img)
    d.ellipse([-300 * SS, 1350 * SS, 1380 * SS, 2250 * SS], outline=(140, 124, 255, 45), width=int(3 * SS))
    files['bg_dark'] = save(finish(img, w, h), folder, 'bg_dark.webp')
    # หัว: ดาวเคราะห์มีวงแหวน มุมขวา
    w, h = 1080, 420
    img = canvas(w, h)
    img.alpha_composite(vertical_gradient(w * SS, h * SS, rgba('#15123A', 230), rgba('#15123A', 0)))
    stars(img, 90, 9, 2.2 * SS)
    planet(img, 585 * SS, 112 * SS, 46 * SS, (255, 190, 120), (140, 90, 220), ring=(200, 180, 255, 210))
    sp = ImageDraw.Draw(img)
    sparkle(sp, 488 * SS, 50 * SS, 13 * SS, (255, 230, 170, 230))
    sparkle(sp, 668 * SS, 196 * SS, 9 * SS, (190, 210, 255, 200))
    files['header_dark'] = save(finish(img, w, h), folder, 'header_dark.webp')
    # หน้าว่าง: ดาวเคราะห์ + ดาวเทียม
    w, h = 600, 420
    img = canvas(w, h)
    stars(img, 40, 4, 2.0 * SS, glow=False)
    planet(img, 300 * SS, 220 * SS, 110 * SS, (130, 220, 255), (90, 70, 210), ring=(255, 200, 120, 230), ring_tilt=-0.25)
    d = ImageDraw.Draw(img)
    d.ellipse([470 * SS, 90 * SS, 500 * SS, 120 * SS], fill=rgba('#FFD166'))
    sparkle(d, 120 * SS, 90 * SS, 18 * SS, (255, 255, 255, 230))
    sparkle(d, 510 * SS, 330 * SS, 12 * SS, (200, 210, 255, 220))
    files['empty'] = save(finish(img, w, h), folder, 'empty.webp')
    # แชท: ดาวจาง
    w, h = 1080, 1920
    img = canvas(w, h, rgba('#090D20'))
    stars(img, 260, 17, 1.8 * SS)
    files['chat_dark'] = save(finish(img, w, h), folder, 'chat_dark.webp')
    # ไอคอน
    for key, fn in (('nav_home', icon_home), ('nav_shop', icon_shop), ('nav_group', icon_group), ('nav_map', icon_map),
                    ('nav_activity', icon_activity), ('search', icon_search), ('chat', icon_chat), ('bell', icon_bell)):
        files['icon_' + key] = save(fn(), folder, 'icons/%s.png' % key)
    return files


def tokens(**kw):
    return {k: v for k, v in kw.items()}


PACKS = [
    {
        'slug': 'ocean-blue', 'version': 2, 'name': 'Ocean Blue', 'maker': ocean,
        'modes': {
            'light': tokens(primary='#1F7AE0', primary_dark='#155DB0', secondary='#10B6C9', background='#F3F8FD',
                            surface='#FFFFFF', fill='#EEF4FA', border='#DCE8F5', soft_primary='#E6F1FD',
                            soft_secondary='#E2F7FA', text='#0B2540', text_muted='#5B7188', text_subtle='#2B4560',
                            market='#0E86A0', shadow='#140B2540'),
            'dark': tokens(primary='#5AA9FF', primary_dark='#3D8FEA', secondary='#38C5D9', background='#0A1622',
                           surface='#10202F', fill='#172A3C', border='#213547', soft_primary='#13304D',
                           soft_secondary='#0F3340', text='#EAF3FC', text_muted='#8FA6BD', text_subtle='#C5D6E6',
                           market='#38C5D9', on_primary='#06182A'),
        },
        'shape': {'corner_scale': 1.0},
        'icon_style': 'outlined',
        'decor': lambda f: {
            'background': {'light': f['bg_light'], 'dark': f['bg_dark']},
            'header': {'light': f['header_light'], 'dark': f['header_dark']},
            'empty': f['empty'],
            'chat_background': {'light': f['chat_light'], 'dark': f['chat_dark']},
        },
    },
    {
        'slug': 'matcha-garden', 'version': 2, 'name': 'Matcha Garden', 'maker': matcha,
        'modes': {
            'light': tokens(primary='#4E7D3A', primary_dark='#3B6129', secondary='#8FA84F', background='#F7F3E8',
                            surface='#FFFDF7', fill='#F1ECDD', border='#E6DFCB', soft_primary='#EAF1E1',
                            soft_secondary='#EFF3DF', text='#2A3122', text_muted='#6E7461', text_subtle='#4A5240',
                            market='#A8651F', warning='#D9A441', soft_warning='#FAF0D9', shadow='#142A3122'),
            'dark': tokens(primary='#8DB873', primary_dark='#76A35C', secondary='#B6C77F', background='#14170F',
                           surface='#1C2116', fill='#252B1D', border='#313926', soft_primary='#26331D',
                           soft_secondary='#2A3320', text='#EEF0E6', text_muted='#A3AA94', text_subtle='#D3D8C6',
                           market='#D9A05B', on_primary='#132010'),
        },
        'shape': {'corner_scale': 1.25},
        'icon_style': 'rounded',
        'decor': lambda f: {
            'background': {'light': f['bg_light'], 'dark': f['bg_dark']},
            'header': {'light': f['header_light'], 'dark': f['header_dark']},
            'empty': f['empty'],
            'chat_background': {'light': f['chat_light'], 'dark': f['chat_dark']},
        },
    },
    {
        'slug': 'cosmic-orbit', 'version': 2, 'name': 'Cosmic Orbit', 'maker': cosmic,
        'modes': {
            'dark': tokens(primary='#8B7CFF', primary_dark='#6F5CF0', secondary='#4DD8FF', background='#070A1A',
                           surface='#11162E', fill='#1A2142', border='#262E55', soft_primary='#221F4D',
                           soft_secondary='#0F2B45', text='#EEF0FF', text_muted='#9AA3C7', text_subtle='#CDD3F0',
                           market='#FFB547', warning='#FFB547', soft_warning='#3A2C14', success='#4BE3A4',
                           danger='#FF6B81', soft_danger='#3D1726', shadow='#66000000', on_primary='#0B0A24'),
        },
        'shape': {'corner_scale': 0.8},
        'icon_style': 'sharp',
        'icons': lambda f: {k[5:]: v for k, v in f.items() if k.startswith('icon_')},
        'decor': lambda f: {
            'background': {'dark': f['bg_dark']},
            'header': {'dark': f['header_dark']},
            'empty': f['empty'],
            'chat_background': {'dark': f['chat_dark']},
        },
    },
]

MIME = {'png': 'image/png', 'webp': 'image/webp', 'jpg': 'image/jpeg'}


def build(pack):
    folder = os.path.join(OUT, pack['slug'], 'v%d' % pack['version'])
    files = pack['maker'](folder)
    assets = []
    for name in sorted(set(files.values())):
        data = open(os.path.join(folder, name), 'rb').read()
        assets.append({
            'path': name,
            'sha256': hashlib.sha256(data).hexdigest(),
            'size': len(data),
            'type': MIME[name.rsplit('.', 1)[1]],
        })
    manifest = {
        'format': 1,
        'slug': pack['slug'],
        'version': pack['version'],
        'name': pack['name'],
        'min_app_build': 1,
        'modes': pack['modes'],
        'shape': pack['shape'],
        'icons': {'style': pack['icon_style'], 'files': pack['icons'](files) if 'icons' in pack else {}},
        'decor': pack['decor'](files),
        'assets': assets,
    }
    with io.open(os.path.join(folder, 'pack.json'), 'w', encoding='utf-8', newline='\n') as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
        f.write('\n')
    total = sum(a['size'] for a in assets)
    print('%-14s %2d files %7.1f KB' % (pack['slug'], len(assets), total / 1024))


if __name__ == '__main__':
    only = sys.argv[1:]
    for pack in PACKS:
        if not only or pack['slug'] in only:
            build(pack)
