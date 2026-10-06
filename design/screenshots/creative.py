import math, os, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter

# The App Store's two creative assets (App Store Connect → version → Product Page Information →
# Header and Search Results; iOS 27 and later):
#
#   creative/header-3840x1646.png   the product page header, 21:9
#   creative/search-3840x2560.png   the picture shown with the app in search results, 3:2
#
#   /usr/bin/python3 creative.py <raw-shots-dir> design/screenshots
#
# Apple's templates mark an "art safe area" in the middle of each (SAFE below, measured from the
# templates): the App Store crops to it in some layouts, so the words and the part of the phone
# that matters sit inside it, and everything outside is there to be cropped. `preview` writes
# each picture again with that area outlined, to check by eye.
RAW, OUT = sys.argv[1], sys.argv[2]
PREVIEW = len(sys.argv) > 3 and sys.argv[3] == 'preview'
FONT = '/System/Library/Fonts/SFNS.ttf'

NAVY = (12, 18, 48); NAVY2 = (24, 36, 80); BLUE = (30, 111, 217)
WHITE = (255, 255, 255); MIST = (200, 214, 240); GOLD = (232, 176, 75)
# x0, y0, x1, y1 of the art safe area in each template.
SAFE = {'header': (1097, 493, 2743, 1154), 'search': (836, 765, 3004, 1795)}

def font(size, weight='Bold'):
    f = ImageFont.truetype(FONT, size)
    try: f.set_variation_by_name(weight)
    except Exception: pass
    return f

def fit(text, width, weight='Bold', start=400):
    """The largest size at which `text` is no wider than `width`."""
    size = start
    while font(size, weight).getlength(text) > width: size -= 2
    return font(size, weight)

def ground(W, H, lights):
    """Navy, darker toward the corners, with soft lights: (x, y, radius, colour, strength)."""
    ys, xs = np.mgrid[0:H, 0:W].astype(np.float32)
    edge = np.clip(np.hypot((xs - W / 2) / (W * 0.62), (ys - H / 2) / (H * 0.85)), 0, 1)[..., None]
    img = np.array(NAVY2, np.float32) * (1 - edge) + np.array(NAVY, np.float32) * edge
    for x, y, r, colour, strength in lights:
        fall = np.clip(1 - np.hypot(xs - x, ys - y) / r, 0, 1) ** 2
        img += (np.array(colour, np.float32) - img) * (fall * strength)[..., None]
    # A grain of noise: a smooth gradient this dark bands in 8 bits without it.
    img += np.random.default_rng(7).uniform(-1.2, 1.2, (H, W, 1))
    return Image.fromarray(np.clip(img, 0, 255).astype(np.uint8)).convert('RGBA')

def bars(canvas, x_near, x_far, cy, tallest, colour=MIST, pitch=74, seed=0.0):
    """The waveform: rounded bars from `x_near` (beside the words, tall and bright) out to
    `x_far` (the edge of the picture, short and faint). Drawn at twice the size and scaled down,
    so the round ends are smooth."""
    W, H = canvas.size
    mask = Image.new('L', (W * 2, H * 2), 0); d = ImageDraw.Draw(mask)
    step = pitch if x_far > x_near else -pitch
    count = int(abs(x_far - x_near) / pitch) + 1
    for i in range(count):
        x = x_near + i * step
        t = i / max(1, count - 1)                       # 0 beside the words, 1 at the edge
        voice = 0.42 + 0.58 * abs(math.sin(i * 1.31 + seed) * 0.62 + math.sin(i * 0.47 + seed * 2.3) * 0.38)
        h = max(pitch * 0.45, tallest * voice * (1 - t) ** 0.8 + pitch * 0.45 * t)
        w = pitch * 0.44
        a = int(255 * (0.78 * (1 - t) ** 1.25 + 0.08))
        d.rounded_rectangle((2 * (x - w / 2), 2 * (cy - h / 2), 2 * (x + w / 2), 2 * (cy + h / 2)), radius=w, fill=a)
    layer = Image.new('RGBA', (W, H), colour + (0,))
    layer.putalpha(mask.resize((W, H), Image.LANCZOS))
    return Image.alpha_composite(canvas, layer)

def phone(shot, width):
    """A screenshot as a phone: a dark body with a lit edge around the screen, and the sensor
    island a simulator screenshot leaves out."""
    s = 2                                               # drawn large, scaled down
    sw = width * s; sh = round(sw * shot.height / shot.width)
    rim = round(sw * 0.028); r = round(sw * 0.135)
    bw, bh = sw + 2 * rim, sh + 2 * rim
    body = Image.new('RGBA', (bw, bh), (0, 0, 0, 0)); d = ImageDraw.Draw(body)
    d.rounded_rectangle((0, 0, bw - 1, bh - 1), radius=r + rim, fill=(86, 100, 132, 255))
    edge = max(2, round(sw * 0.005))
    d.rounded_rectangle((edge, edge, bw - 1 - edge, bh - 1 - edge), radius=r + rim - edge, fill=(9, 11, 18, 255))
    screen = shot.convert('RGBA').resize((sw, sh), Image.LANCZOS)
    mask = Image.new('L', (sw, sh), 0); ImageDraw.Draw(mask).rounded_rectangle((0, 0, sw - 1, sh - 1), radius=r, fill=255)
    body.paste(screen, (rim, rim), mask)
    iw, ih, iy = sw * 0.31, sw * 0.092, sw * 0.03
    d.rounded_rectangle((bw / 2 - iw / 2, rim + iy, bw / 2 + iw / 2, rim + iy + ih), radius=ih / 2, fill=(0, 0, 0, 255))
    return body.resize((bw // s, bh // s), Image.LANCZOS)

def place(canvas, device, x, y, shadow=150):
    W, H = canvas.size
    under = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    r = round(device.width * 0.15)
    ImageDraw.Draw(under).rounded_rectangle((x + 10, y + 50, x + device.width - 10, y + device.height + 50), radius=r, fill=(2, 4, 14, shadow))
    canvas = Image.alpha_composite(canvas, under.filter(ImageFilter.GaussianBlur(70)))
    canvas.alpha_composite(device, (x, y))
    return canvas

def save(canvas, kind, name):
    os.makedirs(f'{OUT}/creative', exist_ok=True)
    dst = f'{OUT}/creative/{name}.png'
    canvas.convert('RGB').save(dst, 'PNG', optimize=True)      # no alpha: the App Store refuses it
    print(dst, canvas.size)
    if PREVIEW:
        marked = canvas.copy(); d = ImageDraw.Draw(marked)
        d.rectangle(SAFE[kind], outline=(0, 255, 0, 255), width=6)
        marked.convert('RGB').save(f'{OUT}/creative/{name}-safe.png', 'PNG')

def header():
    W, H = 3840, 1646
    x0, y0, x1, y1 = SAFE['header']; cx, cy = W // 2, H // 2
    canvas = ground(W, H, [(cx, cy, 1500, BLUE, 0.34)])
    # The words: two lines, as wide as the safe area allows with air on both sides.
    width = (x1 - x0) - 220
    f = fit('Or just say it.', width, start=300)
    d = ImageDraw.Draw(canvas)
    lead = round(f.size * 1.1)
    d.text((cx, cy - lead // 2), 'Type it.', font=f, fill=WHITE, anchor='mm')
    d.text((cx, cy + lead // 2), 'Or just say it.', font=f, fill=GOLD, anchor='mm')
    # The voice on both sides, loudest beside the words and dying away toward the edges. Kept
    # low: on a phone the page's back and share buttons sit over the top corners of what shows.
    gap = 150
    canvas = bars(canvas, x0 - gap, -40, cy, 420, seed=0.4)
    canvas = bars(canvas, x1 + gap, W + 40, cy, 420, seed=2.1)
    save(canvas, 'header', 'header-3840x1646')

def search():
    W, H = 3840, 2560
    x0, y0, x1, y1 = SAFE['search']; cy = H // 2
    voice = phone(Image.open(f'{RAW}/ph-voice.png'), 920)
    chat = phone(Image.open(f'{RAW}/ph-chat-dark.png'), 920)
    vx = x1 - voice.width - 10; vy = 400                # the orb and the heard words fall in the safe area
    canvas = ground(W, H, [(vx + voice.width // 2, 1100, 1500, BLUE, 0.42)])
    # The voice comes in from the left edge toward the words.
    canvas = bars(canvas, x0 - 150, -40, cy, 620, seed=1.2)
    # Chat stands beside it, lower and a shade quieter, running off the edge: out where a
    # narrower layout crops it.
    quiet = Image.new('RGBA', chat.size, NAVY + (0,)); quiet.putalpha(chat.getchannel('A').point(lambda a: a * 46 // 255))
    chat.alpha_composite(quiet)
    canvas = place(canvas, chat, vx + voice.width + 130, vy + 330, shadow=120)
    canvas = place(canvas, voice, vx, vy)
    # The words, left of the phone, with room to spare inside the safe area.
    d = ImageDraw.Draw(canvas)
    left = x0 + 30; width = vx - left - 120
    lines = ['Talk to', 'your own', 'AI agent.']
    f = fit(max(lines, key=len), width, start=236)
    small = fit('Voice and chat for Hermes.', width, weight='Medium', start=96)
    lead = round(f.size * 1.08); gap = round(small.size * 0.7)
    y = cy - (lead * len(lines) + gap + small.size) // 2
    for i, line in enumerate(lines):
        d.text((left, y), line, font=f, fill=GOLD if i == 2 else WHITE, anchor='la'); y += lead
    d.text((left, y + gap), 'Voice and chat for Hermes.', font=small, fill=MIST, anchor='la')
    save(canvas, 'search', 'search-3840x2560')

header()
search()
