import os, sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter

# The website's "Private by design" band as an App Store slot: no device shot,
# just the gradient card with the three zeros and the privacy-label copy.
#   /usr/bin/python3 privacy.py design/screenshots
OUT = sys.argv[1]
FONT = '/System/Library/Fonts/SFNS.ttf'

def font(size, bold=True):
    f = ImageFont.truetype(FONT, size)
    try: f.set_variation_by_name('Bold' if bold else 'Regular')
    except Exception:
        try: f.set_variation_by_axes([700 if bold else 400])
        except Exception: pass
    return f

NAVY = (12, 18, 48); GOLD = (232, 176, 75); WHITE = (255, 255, 255)
MIST = (200, 214, 240); DIM = (143, 160, 196)
BORDER = (122, 106, 83)   # gold at ~45% over the card, pre-blended

def wrap_runs(d, tokens, f, maxw):
    # tokens: (word, color); returns lines of runs, keeping per-word color
    lines, cur, curw = [], [], 0
    space = d.textlength(' ', font=f)
    for word, col in tokens:
        w = d.textlength(word, font=f)
        if cur and curw + space + w > maxw:
            lines.append(cur); cur, curw = [], 0
        cur.append((word, col)); curw += (space if len(cur) > 1 else 0) + w
    if cur: lines.append(cur)
    return lines

def rich_center(d, line, f, cx, y):
    space = d.textlength(' ', font=f)
    total = sum(d.textlength(w, font=f) for w, _ in line) + space * (len(line) - 1)
    x = cx - total / 2
    for word, col in line:
        d.text((x, y), word, font=f, fill=col)
        x += d.textlength(word, font=f) + space

COPY = [('The', MIST), ('App', MIST), ('Store', MIST), ('privacy', MIST), ('label', MIST),
        ('says', MIST), ('“Data', GOLD), ('Not', GOLD), ('Collected”', GOLD),
        ('because', MIST), ('that', MIST), ('is', MIST), ('what', MIST), ('happens.', MIST),
        ('Speech', MIST), ('is', MIST), ('recognized', MIST), ('on', MIST), ('your', MIST),
        ('device,', MIST), ('and', MIST), ('your', MIST), ('credentials', MIST),
        ('never', MIST), ('leave', MIST), ('the', MIST), ('iOS', MIST), ('Keychain.', MIST)]
ZEROS = ['accounts', 'trackers', 'bytes collected']

def privacy(W, H, dst, pad=False):
    canvas = Image.new('RGBA', (W, H), NAVY)
    d = ImageDraw.Draw(canvas)
    margin = int(W * 0.07)
    hf = font(int(W * (0.075 if not pad else 0.055)))
    sf = font(int(W * (0.034 if not pad else 0.026)), bold=False)
    y = int(H * 0.055)
    d.text((margin, y), 'Private by design.', font=hf, fill=WHITE); y += int(hf.size * 1.12)
    y += int(sf.size * 0.5)
    d.text((margin, y), 'No account. No analytics. No tracking.', font=sf, fill=MIST); y += int(sf.size * 1.3)
    top = y + int(H * 0.06); bottom = int(H * 0.885)
    cm = int(W * 0.105)   # card inset, wider than the text margin so the box sits smaller
    rad = int(W * 0.045)
    # card: vertical navy gradient behind a rounded mask, like the site band
    grad = Image.new('RGBA', (W, H))
    gd = ImageDraw.Draw(grad)
    for yy in range(top, bottom, 4):
        t = (yy - top) / (bottom - top)
        c = (int(24 + 12 * t), int(36 + 16 * t), int(80 + 15 * t), 255)
        gd.rectangle((cm, yy, W - cm, yy + 4), fill=c)
    mask = Image.new('L', (W, H), 0)
    ImageDraw.Draw(mask).rounded_rectangle((cm, top, W - cm, bottom), rad, fill=255)
    canvas.paste(grad, (0, 0), mask)
    # faint gold glow at the card's top edge: a true radial falloff, like the
    # site's radial-gradient(ellipse, rgba(232,176,75,.18) -> transparent)
    glow = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    gw = ImageDraw.Draw(glow)
    gx, gy, rx, ry, steps = W / 2, top, W * 0.32, H * 0.1, 48
    for i in range(steps, 0, -1):
        t = i / steps
        gw.ellipse((gx - rx * t, gy - ry * t, gx + rx * t, gy + ry * t),
                   fill=(232, 176, 75, int(55 * (1 - t))))
    glow = glow.filter(ImageFilter.GaussianBlur(int(W * 0.015)))
    glow.putalpha(Image.composite(glow.split()[3], Image.new('L', (W, H), 0), mask))
    canvas = Image.alpha_composite(canvas, glow)
    d = ImageDraw.Draw(canvas)
    d.rounded_rectangle((cm, top, W - cm, bottom), rad, outline=BORDER, width=max(3, int(W * 0.0025)))
    cx = W / 2
    zf = font(int(H * (0.085 if not pad else 0.11)))
    lf = font(int(W * (0.036 if not pad else 0.024)))
    cf = font(int(W * (0.033 if not pad else 0.024)), bold=False)
    inner = int(W * 0.055)
    copy_lines = wrap_runs(d, COPY, cf, W - 2 * cm - 2 * inner)
    copy_h = len(copy_lines) * int(cf.size * 1.45)
    if not pad:
        # phone: the three zeros stacked, copy at the card's foot
        zone_top = top + int(H * 0.02); zone_bot = bottom - copy_h - int(H * 0.05)
        step = (zone_bot - zone_top) / 3
        for i, label in enumerate(ZEROS):
            cy = zone_top + step * i + step / 2
            d.text((cx, cy - int(zf.size * 0.16)), '0', font=zf, fill=GOLD, anchor='mm')
            d.text((cx, cy + int(zf.size * 0.52)), label, font=lf, fill=MIST, anchor='mm')
        ty = zone_bot + int(H * 0.015)
    else:
        # iPad: three columns across the card, copy beneath, the block centered in the card
        gap = int(H * 0.06)
        block = int(zf.size * 1.6) + gap + copy_h
        zone_top = top + ((bottom - top) - block) // 2
        colw = (W - 2 * cm) / 3
        for i, label in enumerate(ZEROS):
            ccx = cm + colw * i + colw / 2
            d.text((ccx, zone_top + zf.size * 0.5), '0', font=zf, fill=GOLD, anchor='mm')
            d.text((ccx, zone_top + zf.size * 1.18), label, font=lf, fill=MIST, anchor='mm')
        ty = zone_top + int(zf.size * 1.6) + gap
    for line in copy_lines:
        rich_center(d, line, cf, cx, ty); ty += int(cf.size * 1.45)
    canvas.convert('RGB').save(dst, 'PNG', optimize=True)
    print(os.path.basename(dst), canvas.size)

privacy(1320, 2868, f'{OUT}/iphone-6.9/07-privacy.png')
privacy(2064, 2752, f'{OUT}/ipad-13/07-ipad-privacy.png', pad=True)
