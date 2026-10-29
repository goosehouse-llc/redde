"""The Mac App Store's pictures: a window of the Mac app (captured by `screencapture -o -l<window>`,
so without the system's shadow) under a headline, on 2880 × 1800, the largest 16:10 size App Store
Connect takes. The headlines and colours are the iPad set's (compose.py).

    python3 design/screenshots/mac.py <folder of window captures> design/screenshots
"""
import os, sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

SHOTS, OUT = sys.argv[1], sys.argv[2]
FONT = '/System/Library/Fonts/SFNS.ttf'
# compose.py's colours and type (that file draws the iPhone and iPad sets as it is read, so it
# can't be imported).
BLUE = (30, 111, 217); PAPER = (239, 235, 226); INK = (27, 29, 58); CHAR = (29, 28, 27); BONE = (237, 232, 208)
WHITE = (255, 255, 255); MIST = (200, 214, 240); SAND = (100, 96, 88); ASH = (170, 165, 158)
PLUM = (44, 30, 78); LILAC = (206, 192, 246)


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


W, H = 2880, 1800


def compose(src, dst, headline, sub, bg, fg, subfg):
    canvas = Image.new('RGBA', (W, H), bg)
    d = ImageDraw.Draw(canvas)
    hf, sf = font(104), font(50, bold=False)
    y = 96
    for line in wrap(d, headline, hf, W - 400):
        d.text(((W - d.textlength(line, font=hf)) // 2, y), line, font=hf, fill=fg); y += int(hf.size * 1.12)
    y += 18
    for line in wrap(d, sub, sf, W - 700):
        d.text(((W - d.textlength(line, font=sf)) // 2, y), line, font=sf, fill=subfg); y += int(sf.size * 1.3)
    top = y + 70
    shot = Image.open(src).convert('RGBA')
    # The window, as large as the room below the words allows, bleeding off the bottom a little.
    room_w, room_h = W - 320, H - top + 60
    scale = min(room_w / shot.width, room_h / shot.height)
    win = shot.resize((int(shot.width * scale), int(shot.height * scale)), Image.LANCZOS)
    x = (W - win.width) // 2
    shadow = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    alpha = win.split()[3].point(lambda a: 120 if a > 0 else 0)
    shadow.paste((0, 0, 0, 255), (x, top + 30), alpha)
    shadow = shadow.filter(ImageFilter.GaussianBlur(45))
    canvas = Image.alpha_composite(canvas, shadow)
    canvas.alpha_composite(win, (x, top))
    canvas.convert('RGB').save(dst, 'PNG', optimize=True)
    print(os.path.basename(dst), canvas.size)


mac = [
    ('mac-work',     '01-mac',         'Your agent, on your Mac.',   'Chats in the sidebar, the conversation beside them, on your own server.', PAPER, INK, SAND),
    ('mac-bots',     '02-mac-bots',    'Meet the crew.',             'Each Hermes profile is a bot, with a face, a voice and a chat of its own. Start one from a template.', PLUM, WHITE, LILAC),
    ('mac-crew',     '03-mac-crew',    'Talk to the whole crew.',    'Put bots in a group chat and they answer in turn.', (24, 32, 46), WHITE, MIST),
    ('mac-rich',     '04-mac-rich',    'Answers with substance.',    'Code, tables, diagrams and math, rendered on the spot.', CHAR, BONE, ASH),
    ('mac-settings', '05-mac-backend', 'Your backend, your rules.',  'Hermes, or any OpenAI-compatible model server. Servers and settings follow you from your iPhone with iCloud.', BLUE, WHITE, MIST),
]
if __name__ == '__main__':
    os.makedirs(f'{OUT}/mac', exist_ok=True)
    for src, name, h, s, bg, fg, sfg in mac:
        path = f'{SHOTS}/{src}.png'
        if os.path.exists(path):
            compose(path, f'{OUT}/mac/{name}.png', h, s, bg, fg, sfg)
        else:
            print('no capture for', name, '(' + path + ')')
