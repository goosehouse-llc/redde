#!/usr/bin/python3
"""Builds the App Store preview (886×1920, 30 fps, H.264, silent stereo AAC) from the recorded clips.

A title page; then a new conversation, blank, and each feature as a shot: a navy background with
a caption on top and the app footage beneath it, rounded; then a closing page that lists the
feature set. Shots cross-fade.
The two pages are drawn frame by frame (the title's waveform moves, the list arrives a line at
a time). Apple takes 15 to 30 seconds: the script stops if the cut runs longer.

  make_preview.py          the 6.9" iPhone version
  make_preview.py ipad     the 13" iPad version, 1200×1600
  make_preview.py [ipad] pages   only the two pages, as stills in pages-*.png, to look at
"""
import math, subprocess, os, shutil, sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter

IPAD = 'ipad' in sys.argv[1:]
PAGES_ONLY = 'pages' in sys.argv[1:]

V = os.path.dirname(os.path.abspath(__file__))
REDDE = os.path.abspath(os.path.join(V, '..', '..'))
if IPAD:
    W, H = 1200, 1600
    FW, FH, FX, FY = 975, 1300, 112, 250     # footage box (iPad screens are 3:4)
    TITLE_Y, SUB_Y, TITLE_PT, SUB_PT, RADIUS = 80, 160, 60, 32, 40
else:
    W, H = 886, 1920
    FW, FH, FX, FY = 720, 1564, 83, 312
    TITLE_Y, SUB_Y, TITLE_PT, SUB_PT, RADIUS = 118, 206, 62, 33, 56
NAVY_TOP, NAVY_BOTTOM, GOLD, MIST = (14, 22, 48), (27, 42, 85), (232, 176, 75), (185, 203, 230)
WHITE = (250, 252, 255)
FADE = 0.35
FPS = 30
TITLE_SECONDS, END_SECONDS = 1.8, 4.2
ICON = f'{REDDE}/Echo/Resources/Assets.xcassets/AppIconGraphiteFlat.appiconset/AppIcon-1024.png'
# The closing page: the feature set, a line at a time.
FEATURES = [
    'Voice and chat with your own agent',
    'Live reasoning, tools and approvals',
    'Sessions, cron jobs and Kanban',
    'Apple Watch and CarPlay',
    'Setup by QR code',
    'Seven themes, 13 app icons',
]

def font(size, weight):
    f = ImageFont.truetype('/System/Library/Fonts/SFNS.ttf', size)
    try: f.set_variation_by_name(weight)
    except Exception: pass
    return f

def background():
    im = Image.new('RGB', (W, H))
    d = ImageDraw.Draw(im)
    for y in range(H):
        t = y / H
        d.line([(0, y), (W, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(NAVY_TOP, NAVY_BOTTOM)))
    return im

def centered(d, y, text, f, fill):
    w = d.textlength(text, font=f)
    d.text(((W - w) / 2, y), text, font=f, fill=fill)

def caption_card(name, title, sub):
    im = background(); d = ImageDraw.Draw(im)
    centered(d, TITLE_Y, title, font(TITLE_PT, 'Bold'), WHITE)
    centered(d, SUB_Y, sub, font(SUB_PT, 'Medium'), MIST)
    # a soft shadow under the footage
    sh = Image.new('L', (W, H), 0); ImageDraw.Draw(sh).rounded_rectangle((FX, FY + 14, FX + FW, FY + FH + 14), RADIUS, fill=90)
    im = Image.composite(Image.new('RGB', (W, H), (4, 8, 20)), im, sh.filter(ImageFilter.GaussianBlur(26)))
    im.save(f'{V}/bg-{name}.png')

def mask():
    m = Image.new('L', (FW, FH), 0); ImageDraw.Draw(m).rounded_rectangle((0, 0, FW - 1, FH - 1), RADIUS, fill=255)
    m.save(f'{V}/mask.png')

def icon(size):
    """The app icon with its corners rounded, and the mask to paste it through."""
    im = Image.open(ICON).convert('RGB').resize((size, size), Image.LANCZOS)
    m = Image.new('L', (size * 2, size * 2), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, size * 2 - 1, size * 2 - 1), int(size * 2 * 0.225), fill=255)
    return im, m.resize((size, size), Image.LANCZOS)

def ease(t):
    t = min(1.0, max(0.0, t))
    return 1 - (1 - t) ** 3

def waveform(im, cy, t, tallest):
    """A row of bars across the frame, loudest in the middle and moving with `t` (seconds)."""
    layer = Image.new('RGBA', (W * 2, H * 2), (0, 0, 0, 0)); d = ImageDraw.Draw(layer)
    pitch = 34; count = W // pitch + 1; x0 = (W - (count - 1) * pitch) / 2
    for i in range(count):
        x = x0 + i * pitch
        mid = 1 - abs(x - W / 2) / (W / 2)                          # 1 in the middle, 0 at the edges
        voice = 0.5 + 0.5 * math.sin(i * 1.31 + t * 5.2) * math.sin(i * 0.47 - t * 3.1 + 1.0)
        h = 10 + tallest * (0.18 + 0.82 * voice) * mid ** 1.4
        a = int(255 * (0.16 + 0.7 * mid ** 1.2))
        d.rounded_rectangle((2 * (x - 7), 2 * (cy - h / 2), 2 * (x + 7), 2 * (cy + h / 2)), radius=14, fill=MIST + (a,))
    im.paste(layer.resize((W, H), Image.LANCZOS), (0, 0), layer.resize((W, H), Image.LANCZOS))

def title_page(t):
    """The opening page at `t` seconds: the icon, the name, what it is, and a voice below."""
    im = background(); d = ImageDraw.Draw(im)
    top = (H - 1920) // 2 + (110 if IPAD else 0)                    # laid out for 1920, centred on a shorter frame
    size = 300; pic, m = icon(size)
    im.paste(pic, ((W - size) // 2, top + 470), m)
    centered(d, top + 826, 'Redde', font(128, 'Bold'), WHITE)
    centered(d, top + 980, 'for Hermes', font(50, 'Semibold'), GOLD)
    centered(d, top + 1084, 'Talk, chat and run your agent', font(42, 'Medium'), MIST)
    waveform(im, top + 1330, t, 150)
    return im

def end_page(t):
    """The closing page at `t` seconds: the feature set, each line coming up in turn."""
    im = background().convert('RGBA')
    top = (H - 1920) // 2 + (120 if IPAD else 60)
    size = 190; pic, m = icon(size)
    im.paste(pic, ((W - size) // 2, top + 330), m)
    d = ImageDraw.Draw(im)
    centered(d, top + 548, 'Redde', font(84, 'Bold'), WHITE)
    f = font(42, 'Semibold')
    widest = max(d.textlength(line, font=f) for line in FEATURES)
    x = (W - widest - 44) / 2
    for i, line in enumerate(FEATURES):
        seen = ease((t - 0.15 - i * 0.13) / 0.3)                    # 0 before its turn, 1 once it is in
        if seen <= 0: continue
        row = Image.new('RGBA', (W, H), (0, 0, 0, 0)); rd = ImageDraw.Draw(row)
        y = top + 740 + i * 96 + (1 - seen) * 14
        rd.ellipse((x, y + 20, x + 16, y + 36), fill=GOLD + (255,))
        rd.text((x + 44, y), line, font=f, fill=WHITE + (255,))
        row.putalpha(row.getchannel('A').point(lambda a: int(a * seen)))
        im = Image.alpha_composite(im, row)
    last = ease((t - 0.15 - len(FEATURES) * 0.13 - 0.1) / 0.35)
    if last > 0:
        row = Image.new('RGBA', (W, H), (0, 0, 0, 0)); rd = ImageDraw.Draw(row)
        centered(rd, top + 740 + len(FEATURES) * 96 + 56, 'No account. No tracking.', font(40, 'Semibold'), GOLD + (255,))
        row.putalpha(row.getchannel('A').point(lambda a: int(a * last)))
        im = Image.alpha_composite(im, row)
    return im.convert('RGB')

def page_segment(name, page, seconds):
    """Draws a page frame by frame and encodes it."""
    frames = f'{V}/frames-{name}'
    shutil.rmtree(frames, ignore_errors=True); os.makedirs(frames)
    for n in range(round(seconds * FPS)):
        page(n / FPS).save(f'{frames}/{n:04d}.png')
    out = f'{V}/seg-{name}.mp4'
    run(['ffmpeg', '-v', 'error', '-y', '-framerate', str(FPS), '-i', f'{frames}/%04d.png',
         '-vf', 'format=yuv420p', '-c:v', 'libx264', '-crf', '14', out])
    shutil.rmtree(frames)
    return out, seconds

# (clip, start, end, background, hold_last_frame_until). Two shots in a row with the same background
# read as one: the swipe and then the board.
#
# The first two are one take: a new conversation on the start screen, then the question sent
# from it and answered live. The second starts FADE before the first ends, so under the
# cross-fade the footage runs straight on and only the caption changes.
SHOTS = [
    ('c1-stream', 4.4, 6.75, 'start', None),
    ('c1-stream', 6.4, 13.3, 'agent', None),
    ('c2-voice', 5.1, 8.1, 'voice', None),
    ('c3-rich', 40.4, 44.4, 'rich', None),
    ('c4-kanban', 16.9, 19.2, 'workspace', None),
    ('c4b-kanban', 5.0, 5.7, 'workspace', 2.0),
    ('c7-code', 19.2, 22.6, 'setup', None),
    ('c5-yours', 16.6, 19.4, 'yours', None),
]
if IPAD:
    SHOTS = [
        ('ipad-c1-stream', 4.7, 6.95, 'start', None),
        ('ipad-c1-stream', 6.6, 13.65, 'agent', None),
        ('ipad-c2-voice', 6.5, 9.5, 'voice', None),
        ('ipad-c3-rich', 49.4, 53.6, 'rich', None),
        ('ipad-c4-kanban', 5.45, 5.55, 'workspace', 3.2),
        ('ipad-c7-code', 24.05, 27.45, 'setup', None),
        ('ipad-c5-yours', 17.7, 20.5, 'yours', None),
    ]
CAPTIONS = {
    'start': ('A place to start', 'Your day and your last chat, one tap away'),
    'agent': ('Your AI agent, on your iPad' if IPAD else 'Your AI agent, in your pocket', 'Watch it think, use tools and answer live'),
    'voice': ('Just talk', f'Hands-free voice, recognized on your {"iPad" if IPAD else "iPhone"}'),
    'rich': ('Answers with substance', 'Code, checklists and tables, rendered right'),
    'workspace': ('Every chat, job and board', 'Chats, cron and Kanban beside every conversation' if IPAD
                  else 'Swipe right for your whole workspace'),
    'setup': ('Set up by QR code', 'Scan it, and your server fills itself in'),
    'yours': ('Make it yours', 'Seven themes, your colors, 13 app icons'),
}

def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode: print(r.stderr[-1500:]); raise SystemExit(1)

def main():
    if PAGES_ONLY:
        kind = 'ipad' if IPAD else 'iphone'
        title_page(1.0).save(f'{V}/pages-{kind}-title.png'); end_page(END_SECONDS).save(f'{V}/pages-{kind}-end.png')
        return
    mask()
    for name, (t, s) in CAPTIONS.items(): caption_card(name, t, s)
    segs = [page_segment('title', title_page, TITLE_SECONDS)]
    for i, (clip, a, b, bg, hold) in enumerate(SHOTS):
        out = f'{V}/seg{i}.mp4'
        dur = hold if hold else b - a
        pad = f',tpad=stop_mode=clone:stop_duration={hold}' if hold else ''
        run(['ffmpeg', '-v', 'error', '-y', '-ss', str(a), '-to', str(b), '-i', f'{V}/cfr-{clip}.mov',
             '-loop', '1', '-i', f'{V}/bg-{bg}.png', '-loop', '1', '-i', f'{V}/mask.png',
             '-filter_complex',
             f'[0:v]fps=30,scale={FW}:{FH}:flags=lanczos,setsar=1{pad},format=rgba[v];'
             f'[2:v]format=gray[m];[v][m]alphamerge[vm];[1:v][vm]overlay={FX}:{FY},format=yuv420p,fps=30',
             '-t', f'{dur:.3f}', '-c:v', 'libx264', '-crf', '14', '-preset', 'medium', out])
        segs.append((out, dur))
    segs.append(page_segment('end', end_page, END_SECONDS))

    # Cross-fade everything together.
    inputs, chain, offset, last = [], [], 0.0, '[0:v]'
    for i, (path, dur) in enumerate(segs):
        inputs += ['-i', path]
    total = segs[0][1]
    for i in range(1, len(segs)):
        offset = total - FADE
        label = f'[x{i}]'
        chain.append(f'{last}[{i}:v]xfade=transition=fade:duration={FADE}:offset={offset:.3f}{label}')
        last = label
        total = offset + segs[i][1]
    if total > 29.8: raise SystemExit(f'{total:.2f}s: an App Store preview is at most 30 seconds; shorten a shot')
    out = f'{V}/redde-app-preview-{"ipad" if IPAD else "iphone"}.mp4'
    run(['ffmpeg', '-v', 'error', '-y', *inputs,
         '-f', 'lavfi', '-t', f'{total:.3f}', '-i', 'anullsrc=channel_layout=stereo:sample_rate=44100',
         '-filter_complex', ';'.join(chain), '-map', last, '-map', f'{len(segs)}:a',
         '-c:v', 'libx264', '-profile:v', 'high', '-level', '4.0', '-pix_fmt', 'yuv420p', '-r', '30',
         '-b:v', '10M', '-maxrate', '11M', '-bufsize', '20M', '-g', '30',   # Apple: High 4.0, 10–12 Mbps
         '-c:a', 'aac', '-b:a', '256k', '-ar', '44100', '-ac', '2', '-shortest', '-movflags', '+faststart', out])
    print(f'{out}  {total:.2f}s')

main()
