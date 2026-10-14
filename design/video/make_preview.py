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
  make_preview.py phone    the Phone tools cut (redde-phone-tools.mp4), for a post: the agent using
                           the iPhone, the question before a change, a photo found, the switches
  make_preview.py fun      the fun Phone tools cut (redde-phone-fun.mp4): a day with the agent, every
                           area, captions that drop in with an emoji, the chat a little faster, and a
                           soundtrack made by fun_music.py
"""
import math, subprocess, os, shutil, sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter

IPAD = 'ipad' in sys.argv[1:]
FUN = 'fun' in sys.argv[1:]
PHONE = 'phone' in sys.argv[1:] or FUN
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
# The opening page's two lines under the name, and the closing page's last line.
TITLE_LINES = ('for Hermes', 'Talk, chat and run your agent')
LAST_LINE = 'No account. No tracking.'
if PHONE:
    FEATURES = [
        'Calendar and reminders',
        'Contacts and photos',
        'Files, alarms and timers',
        'A widget it keeps up to date',
        'Calls and messages, sent by you',
        'Each one off until you turn it on',
    ]
    TITLE_LINES = ('Phone tools', 'Your agent can use your iPhone')
    LAST_LINE = 'Changes always ask you first.'
if FUN:
    # (emoji, line): the emoji stands where the gold dot does.
    FEATURES = [
        ('🗓️', 'Calendar and reminders'),
        ('👤', 'Contacts'),
        ('📸', 'Photos, by what they show'),
        ('📁', 'A folder of files'),
        ('⏰', 'Alarms and timers'),
        ('📌', 'A widget it writes on'),
        ('📞', 'Calls and texts, sent by you'),
        ('👀', 'The camera in voice mode'),
    ]
    TITLE_LINES = ('Phone tools', 'Your agent just got an iPhone')
    LAST_LINE = 'Each one off until you say so.'
    TITLE_SECONDS, END_SECONDS = 2.6, 5.0
    TITLE_EMOJI = ['🗓️', '⏰', '🛒', '📸', '🪴', '📞', '💬']

def font(size, weight):
    f = ImageFont.truetype('/System/Library/Fonts/SFNS.ttf', size)
    try: f.set_variation_by_name(weight)
    except Exception: pass
    return f

_emoji = {}
def emoji(ch, size):
    """An emoji as a picture `size` pixels high: Apple's are drawn at 160 and scaled."""
    if (ch, size) not in _emoji:
        f = ImageFont.truetype('/System/Library/Fonts/Apple Color Emoji.ttc', 160)
        im = Image.new('RGBA', (220, 220), (0, 0, 0, 0))
        ImageDraw.Draw(im).text((10, 10), ch, font=f, embedded_color=True)
        im = im.crop(im.getbbox())
        _emoji[(ch, size)] = im.resize((round(im.width * size / im.height), size), Image.LANCZOS)
    return _emoji[(ch, size)]

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

def caption_card(name, title, sub, mark=None):
    im = background(); d = ImageDraw.Draw(im)
    if FUN:
        layer = Image.new('RGBA', (W, H), (0, 0, 0, 0)); ld = ImageDraw.Draw(layer)
        f = font(TITLE_PT - 4, 'Bold'); pic = emoji(mark, 74)
        width = pic.width + 18 + ld.textlength(title, font=f)
        x = (W - width) / 2
        layer.paste(pic, (int(x), TITLE_Y - 4), pic)
        ld.text((x + pic.width + 18, TITLE_Y), title, font=f, fill=WHITE + (255,))
        centered(ld, SUB_Y, sub, font(SUB_PT, 'Medium'), MIST + (255,))
        layer.save(f'{V}/cap-{name}.png')
    else:
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
    centered(d, top + 980, TITLE_LINES[0], font(50, 'Semibold'), GOLD)
    centered(d, top + 1084, TITLE_LINES[1], font(42, 'Medium'), MIST)
    if FUN:
        # The new things, popping up one after another and then bobbing like a wave.
        size, pitch = 86, 112; x0 = (W - (len(TITLE_EMOJI) - 1) * pitch) / 2
        for i, ch in enumerate(TITLE_EMOJI):
            k = (t - 0.35 - i * 0.09) / 0.32
            if k <= 0: continue
            pop = 1 + 0.35 * math.sin(min(k, 1) * math.pi) if k < 1 else 1
            s2 = max(4, round(size * min(1, k * 1.6) * pop))
            pic = emoji(ch, size).resize((round(emoji(ch, size).width * s2 / size), s2), Image.LANCZOS)
            y = top + 1330 + 18 * math.sin(2 * math.pi * 0.9 * t - i * 0.75)
            im.paste(pic, (int(x0 + i * pitch - pic.width / 2), int(y - pic.height / 2)), pic)
    else:
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
    f = font(40 if FUN else 42, 'Semibold')
    step = 88 if FUN else 96
    lines = [line[1] if FUN else line for line in FEATURES]
    gap = 66 if FUN else 44
    widest = max(d.textlength(line, font=f) for line in lines)
    x = (W - widest - gap) / 2
    for i, line in enumerate(lines):
        seen = ease((t - 0.15 - i * 0.13) / 0.3)                    # 0 before its turn, 1 once it is in
        if seen <= 0: continue
        row = Image.new('RGBA', (W, H), (0, 0, 0, 0)); rd = ImageDraw.Draw(row)
        y = top + 740 + i * step + (1 - seen) * 14
        if FUN:
            pic = emoji(FEATURES[i][0], 46); row.paste(pic, (int(x + 23 - pic.width / 2), int(y + 4)), pic)
        else:
            rd.ellipse((x, y + 20, x + 16, y + 36), fill=GOLD + (255,))
        rd.text((x + gap, y), line, font=f, fill=WHITE + (255,))
        row.putalpha(row.getchannel('A').point(lambda a: int(a * seen)))
        im = Image.alpha_composite(im, row)
    last = ease((t - 0.15 - len(FEATURES) * 0.13 - 0.1) / 0.35)
    if last > 0:
        row = Image.new('RGBA', (W, H), (0, 0, 0, 0)); rd = ImageDraw.Draw(row)
        centered(rd, top + 740 + len(FEATURES) * step + 56, LAST_LINE, font(40, 'Semibold'), GOLD + (255,))
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
if PHONE:
    # One take of the agent at work, cut in three under three captions, and the switches.
    # Times are seconds into each take: its marks less its t0 (README).
    SHOTS = [
        ('c8-phone', 12.85, 15.7, 'ask', None),
        ('c8-phone', 15.35, 20.55, 'allow', None),
        ('c8-phone', 22.3, 30.6, 'photo', None),
        ('c10-reach', 13.5, 18.1, 'call', None),
        ('c10-reach', 19.6, 25.2, 'text', None),
        ('c9-phone-settings', 31.0, 35.75, 'choose', None),
    ]
if FUN:
    # (clip, start, end, caption, hold, speed). Takes from 2026-10-14 (README): the timer and the
    # widget on an iOS 26.3 simulator (alarms), the rest on iOS 27 (its emoji). Chat runs a little
    # fast; the countdown on the Lock Screen at its own pace.
    SHOTS = [
        ('f1-morning', 15.0, 20.7, 'cal', None, 1.3),
        ('f1-morning', 20.5, 27.2, 'ask', None, 1.15),
        ('f2-timer', 8.0, 12.3, 'timer', None, 1.2),
        ('f2-timer', 14.9, 19.0, 'timer', None, 1.0),
        ('f3-widget', 8.4, 13.9, 'widget', None, 1.25),
        ('f3-widget', 14.3, 15.5, 'widget', 3.4, 1.0),
        ('f4-photo', 13.6, 21.6, 'photo', None, 1.3),
        ('f5-look', 15.6, 20.3, 'look', None, 1.0),
        ('f5-look', 20.6, 25.5, 'plant', None, 1.15),
        ('f6-reach', 13.2, 19.6, 'call', None, 1.3),
        ('f6-reach', 19.4, 26.5, 'text', None, 1.3),
    ]
CAPTIONS = {
    'ask': ('Your agent, using your iPhone', 'Ask, and it reads your calendar'),
    'allow': ('A change asks you first', 'Nothing is added without your yes'),
    'photo': ('Finds the photo you mean', 'Your iPhone looks; only the match is sent'),
    'call': ('It can start a call', 'iOS asks you before it dials'),
    'text': ('It writes the message', 'Messages opens with it; you tap Send'),
    'choose': ('You decide what it may use', 'Every area is off until you turn it on'),
    # The fun cut's: (title, line, emoji).
    'cal': ('Good morning', 'It reads your calendar', '☀️'),
    'ask': ('It asks first', 'Nothing changes without your yes', '🙋'),
    'timer': ("Pasta o'clock", 'A real timer, right on your Lock Screen', '🍝'),
    'widget': ('Shopping list', 'Saved to Files, pinned to its widget', '🛒'),
    'photo': ('Finds that photo', '187. A personal best.', '🎳'),
    'look': ('Show it, ask it', 'Turn on the camera in voice mode', '🪴'),
    'plant': ('Plant doctor', 'It sees what your camera sees', '💧'),
    'call': ('Calls the vet', 'iOS asks you before it dials', '☎️'),
    'text': ('Writes the text', 'You tap Send. Not it.', '💬'),
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
        kind = 'phone' if PHONE else 'ipad' if IPAD else 'iphone'
        title_page(1.0).save(f'{V}/pages-{kind}-title.png'); end_page(END_SECONDS).save(f'{V}/pages-{kind}-end.png')
        return
    mask()
    used = {shot[3] for shot in SHOTS}
    for name, words in CAPTIONS.items():
        if name in used: caption_card(name, *words)
    segs = [page_segment('title', title_page, TITLE_SECONDS)]
    drops = []                                  # which segments' captions drop in (FUN)
    for i, (clip, a, b, bg, hold, *rest) in enumerate(SHOTS):
        speed = rest[0] if rest else 1.0
        out = f'{V}/seg{i}.mp4'
        dur = hold if hold else (b - a) / speed
        pad = f',tpad=stop_mode=clone:stop_duration={hold}' if hold else ''
        footage = (f'[0:v]setpts=PTS/{speed},fps=30,scale={FW}:{FH}:flags=lanczos,setsar=1{pad},format=rgba[v];'
                   f'[2:v]format=gray[m];[v][m]alphamerge[vm];[1:v][vm]overlay={FX}:{FY}')
        words = []
        if FUN:
            drop = i == 0 or SHOTS[i - 1][3] != bg
            drops.append(drop)
            words = ['-loop', '1', '-i', f'{V}/cap-{bg}.png']
            # The caption falls in from above and settles with a little bounce.
            fall = "overlay=0:'-44*exp(-6*t)*cos(10*t)':eval=frame" if drop else 'overlay=0:0'
            fade = 'fade=t=in:st=0:d=0.2:alpha=1,' if drop else ''
            footage += f'[b];[3:v]format=rgba,{fade}null[c];[b][c]{fall}'
        run(['ffmpeg', '-v', 'error', '-y', '-ss', str(a), '-to', str(b), '-i', f'{V}/cfr-{clip}.mov',
             '-loop', '1', '-i', f'{V}/bg-{bg}.png', '-loop', '1', '-i', f'{V}/mask.png', *words,
             '-filter_complex', footage + ',format=yuv420p,fps=30',
             '-t', f'{dur:.3f}', '-c:v', 'libx264', '-crf', '14', '-preset', 'medium', out])
        segs.append((out, dur))
    segs.append(page_segment('end', end_page, END_SECONDS))

    # Cross-fade everything together.
    inputs, chain, offset, last = [], [], 0.0, '[0:v]'
    for i, (path, dur) in enumerate(segs):
        inputs += ['-i', path]
    total = segs[0][1]
    pops = []
    for i in range(1, len(segs)):
        offset = total - FADE
        if FUN and i <= len(drops) and drops[i - 1]: pops.append(offset + 0.08)
        label = f'[x{i}]'
        chain.append(f'{last}[{i}:v]xfade=transition=fade:duration={FADE}:offset={offset:.3f}{label}')
        last = label
        total = offset + segs[i][1]
    if not PHONE and total > 29.8: raise SystemExit(f'{total:.2f}s: an App Store preview is at most 30 seconds; shorten a shot')
    out = f'{V}/redde-phone-fun.mp4' if FUN else f'{V}/redde-phone-tools.mp4' if PHONE else f'{V}/redde-app-preview-{"ipad" if IPAD else "iphone"}.mp4'
    if FUN:
        sys.path.insert(0, V); import fun_music
        sound = ['-i', fun_music.render(total, f'{V}/fun-music.wav', pops)]
    else:
        sound = ['-f', 'lavfi', '-t', f'{total:.3f}', '-i', 'anullsrc=channel_layout=stereo:sample_rate=44100']
    run(['ffmpeg', '-v', 'error', '-y', *inputs, *sound,
         '-filter_complex', ';'.join(chain), '-map', last, '-map', f'{len(segs)}:a',
         '-c:v', 'libx264', '-profile:v', 'high', '-level', '4.0', '-pix_fmt', 'yuv420p', '-r', '30',
         '-b:v', '10M', '-maxrate', '11M', '-bufsize', '20M', '-g', '30',   # Apple: High 4.0, 10–12 Mbps
         '-c:a', 'aac', '-b:a', '256k', '-ar', '44100', '-ac', '2', '-shortest', '-movflags', '+faststart', out])
    print(f'{out}  {total:.2f}s')

main()
