import os, sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter

SHOTS = sys.argv[1]; OUT = sys.argv[2]
# A third argument names the slots to draw (`09-tools,08-ipad-tools`); the others are left as they are.
ONLY = set(sys.argv[3].split(',')) if len(sys.argv) > 3 else None
FONT = '/System/Library/Fonts/SFNS.ttf'

def font(size, bold=True):
    f = ImageFont.truetype(FONT, size)
    try: f.set_variation_by_name('Bold' if bold else 'Regular')
    except Exception:
        try: f.set_variation_by_axes([700 if bold else 400])
        except Exception: pass
    return f

def wrap(draw, text, f, maxw):
    words, lines, cur = text.split(), [], ''
    for w in words:
        t = (cur + ' ' + w).strip()
        if draw.textlength(t, font=f) <= maxw: cur = t
        else: lines.append(cur); cur = w
    if cur: lines.append(cur)
    return lines

def compose(src, dst, headline, sub, bg, fg, subfg, pad):
    shot = Image.open(src).convert('RGBA')
    W, H = shot.size
    canvas = Image.new('RGBA', (W, H), bg)
    d = ImageDraw.Draw(canvas)
    margin = int(W * 0.07)
    hf = font(int(W * (0.075 if not pad else 0.055)))
    sf = font(int(W * (0.034 if not pad else 0.026)), bold=False)
    y = int(H * 0.055)
    for line in wrap(d, headline, hf, W - 2 * margin):
        d.text((margin, y), line, font=hf, fill=fg); y += int(hf.size * 1.12)
    y += int(sf.size * 0.5)
    for line in wrap(d, sub, sf, W - 2 * margin):
        d.text((margin, y), line, font=sf, fill=subfg); y += int(sf.size * 1.3)
    top = y + int(H * 0.035)
    # device image: scaled to width, rounded, shadowed, bleeding off the bottom
    scale = 0.86 if not pad else 0.88
    dw = int(W * scale); dh = int(H * scale)
    dev = shot.resize((dw, dh), Image.LANCZOS)
    r = int(W * (0.09 if not pad else 0.03))
    mask = Image.new('L', (dw, dh), 0); ImageDraw.Draw(mask).rounded_rectangle((0, 0, dw, dh), r, fill=255)
    x = (W - dw) // 2
    shadow = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((x, top + 24, x + dw, top + dh + 24), r, fill=(0, 0, 0, 110))
    shadow = shadow.filter(ImageFilter.GaussianBlur(40))
    canvas = Image.alpha_composite(canvas, shadow)
    canvas.paste(dev, (x, top), mask)
    canvas.convert('RGB').save(dst, 'PNG', optimize=True)
    print(os.path.basename(dst), canvas.size)

def inset(path, box, radius, width, turn=0):
    """A piece of another screen (the Lock Screen's countdown, the Home Screen's widget), cut out
    along its own rounded edge, scaled to `width`, turned `turn` degrees, with its shadow."""
    im = Image.open(path).convert('RGBA').crop(box)
    mask = Image.new('L', im.size, 0); ImageDraw.Draw(mask).rounded_rectangle((0, 0, im.width - 1, im.height - 1), radius, fill=255)
    im.putalpha(mask)
    im = im.resize((width, round(im.height * width / im.width)), Image.LANCZOS)
    pad = 90
    out = Image.new('RGBA', (im.width + 2 * pad, im.height + 2 * pad), (0, 0, 0, 0))
    shadow = Image.new('RGBA', out.size, (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 150), (pad, pad + 26), im.getchannel('A'))
    out = Image.alpha_composite(out, shadow.filter(ImageFilter.GaussianBlur(34)))
    out.alpha_composite(im, (pad, pad))
    return out.rotate(turn, Image.BICUBIC, expand=True) if turn else out

# Where the insets are in the pictures testToolsShotInsets takes (1320×2868, an iPhone 17 Pro Max).
PILL = ('lock-timer.png', (47, 2269, 1273, 2456), 94)
WIDGET = ('home-widget.png', (97, 286, 1223, 807), 100)

def compose_tools(src, dst, headline, sub, bg, fg, subfg, pad):
    """The Phone tools slot: the conversation, and what it did beyond the app. On iPhone the
    timer counting down on the Lock Screen and the widget, set above the phone and over its
    top; on iPad the widget, over the empty end of the conversation."""
    shot = Image.open(src).convert('RGBA')
    W, H = shot.size
    canvas = Image.new('RGBA', (W, H), bg)
    d = ImageDraw.Draw(canvas)
    margin = int(W * 0.07)
    hf = font(int(W * (0.075 if not pad else 0.055))); sf = font(int(W * (0.034 if not pad else 0.026)), bold=False)
    y = int(H * 0.055)
    for line in wrap(d, headline, hf, W - 2 * margin):
        d.text((margin, y), line, font=hf, fill=fg); y += int(hf.size * 1.12)
    y += int(sf.size * 0.5)
    for line in wrap(d, sub, sf, W - 2 * margin):
        d.text((margin, y), line, font=sf, fill=subfg); y += int(sf.size * 1.3)
    scale = 0.86 if not pad else 0.88
    dw = int(W * scale); dh = int(H * scale)
    r = int(W * (0.09 if not pad else 0.03))
    x = (W - dw) // 2
    if pad:
        top = y + int(H * 0.035)
        cards = [(inset(SHOTS + '/' + WIDGET[0], *WIDGET[1:], width=int(W * 0.42), turn=-2.5), W - margin - int(W * 0.42) + 40, top + int(dh * 0.6))]
    else:
        pill = inset(SHOTS + '/' + PILL[0], *PILL[1:], width=int(W * 0.84), turn=1.5)
        widget = inset(SHOTS + '/' + WIDGET[0], *WIDGET[1:], width=int(W * 0.74), turn=-2.5)
        first = y - 40
        cards = [(pill, (W - pill.width) // 2, first), (widget, (W - widget.width) // 2 + 30, first + pill.height - 150)]
        top = first + pill.height - 150 + widget.height - 230
    dev = shot.resize((dw, dh), Image.LANCZOS)
    mask = Image.new('L', (dw, dh), 0); ImageDraw.Draw(mask).rounded_rectangle((0, 0, dw, dh), r, fill=255)
    shadow = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((x, top + 24, x + dw, top + dh + 24), r, fill=(0, 0, 0, 110))
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(40)))
    canvas.paste(dev, (x, top), mask)
    for card, cx, cy in cards: canvas.alpha_composite(card, (cx, cy))
    canvas.convert('RGB').save(dst, 'PNG', optimize=True)
    print(os.path.basename(dst), canvas.size)

def compose_car(shots, dst, headline, sub, bg, fg, subfg):
    """The CarPlay slot: the car's screens stacked under the words, each in a dark bezel. The
    shots are landscape (a dashboard display), drawn by scripts/carplay-preview.sh."""
    W, H = 1320, 2868
    canvas = Image.new('RGBA', (W, H), bg)
    d = ImageDraw.Draw(canvas)
    margin = int(W * 0.07)
    hf = font(int(W * 0.075)); sf = font(int(W * 0.034), bold=False)
    y = int(H * 0.055)
    for line in wrap(d, headline, hf, W - 2 * margin):
        d.text((margin, y), line, font=hf, fill=fg); y += int(hf.size * 1.12)
    y += int(sf.size * 0.5)
    for line in wrap(d, sub, sf, W - 2 * margin):
        d.text((margin, y), line, font=sf, fill=subfg); y += int(sf.size * 1.3)
    screens = [Image.open(p).convert('RGBA') for p in shots]
    sw = int(W * 0.86); frame = 16; gap = int(H * 0.028)
    sizes = [(sw, int(sw * im.height / im.width)) for im in screens]
    stack = sum(h + 2 * frame for _, h in sizes) + gap * (len(sizes) - 1)
    top = y + max(int(H * 0.035), (H - y - stack) // 2)
    x = (W - sw) // 2
    for im, (w, h) in zip(screens, sizes):
        box = (x - frame, top, x + w + frame, top + h + 2 * frame)
        shadow = Image.new('RGBA', (W, H), (0, 0, 0, 0))
        ImageDraw.Draw(shadow).rounded_rectangle((box[0], box[1] + 18, box[2], box[3] + 18), 46, fill=(0, 0, 0, 120))
        canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(30)))
        ImageDraw.Draw(canvas).rounded_rectangle(box, 46, fill=(6, 8, 12))
        mask = Image.new('L', (w, h), 0); ImageDraw.Draw(mask).rounded_rectangle((0, 0, w, h), 32, fill=255)
        canvas.paste(im.resize((w, h), Image.LANCZOS), (x, top + frame), mask)
        top += h + 2 * frame + gap
    canvas.convert('RGB').save(dst, 'PNG', optimize=True)
    print(os.path.basename(dst), canvas.size)

BLUE = (30, 111, 217); NAVY = (16, 24, 56); PAPER = (239, 235, 226); INK = (27, 29, 58); CHAR = (29, 28, 27); BONE = (237, 232, 208)
WHITE = (255, 255, 255); MIST = (200, 214, 240); SAND = (100, 96, 88); ASH = (170, 165, 158)
os.makedirs(f'{OUT}/iphone-6.9', exist_ok=True); os.makedirs(f'{OUT}/ipad-13', exist_ok=True)
phone = [
  ('ph-chat-dark', '01-hero',    'Your agent, in your pocket.',  'Voice or text, on your own server. Nothing in between.', BLUE, WHITE, MIST),
  ('ph-voice',    '02-voice',    'Just talk.',                   'An orb that moves with your voice. On-device speech, hands-free if you like.', (24, 32, 46), WHITE, MIST),
  ('ph-work',     '03-work',     'Watch it think and work.',     'Live reasoning, tool calls, and subagents you can steer.', PAPER, INK, SAND),
  ('ph-diagram',  '04-rich',     'Answers with substance.',      'Code, tables, diagrams and math, rendered on the spot.', CHAR, BONE, ASH),
  ('ph-settings', '05-backend',  'Your backend, your rules.',    'Hermes, or any OpenAI-compatible model server. A setup code fills in the address and keys for you.', BLUE, WHITE, MIST),
  ('ph-chat',     '06-light',    'Make it yours.',               'Seven themes, your own colors, 13 app icons and 12 voice orbs. Face ID lock included.', (236, 238, 243), INK, SAND),
  ('ph-gateway',  '08-server',   'Your server, from your phone.', 'What Hermes is running, its MCP servers, logs and files. Restart it without a terminal.', NAVY, WHITE, MIST),
  ('ph-phone',    '09-tools',    'Your agent can use your iPhone.', 'Calendar, reminders, photos, alarms, its own widget, calls and texts. Each one off until you turn it on.', CHAR, BONE, ASH),
]
pad = [
  ('pad-default-dark', '01-ipad',      'Built for iPad.',              'Sessions, scheduled jobs and the Kanban board beside the conversation.', BLUE, WHITE, MIST),
  ('pad-voice',        '02-ipad-voice','Just talk.',                   'An orb that moves with your voice. On-device speech, spoken replies, hands-free if you like.', (24, 32, 46), WHITE, MIST),
  ('pad-work',         '03-ipad-work', 'Watch it think and work.',     'Live reasoning, tool calls, and subagents you can steer.', PAPER, INK, SAND),
  ('pad-dark',         '04-ipad-rich', 'Answers with substance.',      'Code, tables, diagrams and math, rendered on the spot.', CHAR, BONE, ASH),
  ('pad-settings',     '05-ipad-backend', 'Your backend, your rules.', 'Hermes, or any OpenAI-compatible model server. A setup code fills in the address and keys for you.', BLUE, WHITE, MIST),
  ('pad-split',        '06-ipad-light','Make it yours.',               'Seven themes, your own colors, 13 app icons and 12 voice orbs.', (236, 238, 243), INK, SAND),
  ('pad-gateway',      '07-ipad-server', 'Your server, from your iPad.', 'What Hermes is running, its MCP servers, logs and files. Restart it without a terminal.', NAVY, WHITE, MIST),
  ('pad-phone',        '08-ipad-tools', 'Your agent can use your iPad.', 'Calendar, reminders, contacts, photos, files and its own widget. Each one off until you turn it on.', CHAR, BONE, ASH),
]
for kind, slots in (('iphone-6.9', phone), ('ipad-13', pad)):
    for src, name, h, s, bg, fg, sfg in slots:
        if ONLY and name not in ONLY: continue
        draw = compose_tools if name.endswith('-tools') else compose
        draw(f'{SHOTS}/{src}.png', f'{OUT}/{kind}/{name}.png', h, s, bg, fg, sfg, kind == 'ipad-13')
# iPhone only: CarPlay runs from the phone.
if not ONLY or '07-car' in ONLY:
  compose_car([f'{SHOTS}/car-ask.png', f'{SHOTS}/car-voice.png', f'{SHOTS}/car-speaking.png'], f'{OUT}/iphone-6.9/07-car.png',
              'In the car, by voice.', 'CarPlay: tap Ask or Talk, take a note, or pause a reply. Answers are spoken, so your eyes stay on the road.',
              (24, 32, 46), WHITE, MIST)
