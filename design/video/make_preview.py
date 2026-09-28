#!/usr/bin/python3
"""Builds the App Store preview (886×1920, 30 fps, H.264, silent stereo AAC) from the recorded clips.

Each shot: a navy background with a caption on top and the app footage beneath it, rounded; then
a closing card. Shots cross-fade.
"""
import subprocess, os, sys
from PIL import Image, ImageDraw, ImageFont

IPAD = 'ipad' in sys.argv[1:]   # `make_preview.py ipad`: the 13" iPad version, 1200×1600

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
FADE = 0.35

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
    centered(d, TITLE_Y, title, font(TITLE_PT, 'Bold'), (250, 252, 255))
    centered(d, SUB_Y, sub, font(SUB_PT, 'Medium'), MIST)
    # a soft shadow under the footage
    sh = Image.new('L', (W, H), 0); ImageDraw.Draw(sh).rounded_rectangle((FX, FY + 14, FX + FW, FY + FH + 14), RADIUS, fill=90)
    from PIL import ImageFilter
    im = Image.composite(Image.new('RGB', (W, H), (4, 8, 20)), im, sh.filter(ImageFilter.GaussianBlur(26)))
    im.save(f'{V}/bg-{name}.png')

def mask():
    m = Image.new('L', (FW, FH), 0); ImageDraw.Draw(m).rounded_rectangle((0, 0, FW - 1, FH - 1), RADIUS, fill=255)
    m.save(f'{V}/mask.png')

def end_card():
    im = background(); d = ImageDraw.Draw(im)
    icon = Image.open(f'{REDDE}/Echo/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png').convert('RGB').resize((300, 300), Image.LANCZOS)
    m = Image.new('L', (300, 300), 0); ImageDraw.Draw(m).rounded_rectangle((0, 0, 299, 299), 68, fill=255)
    top = (H - 1920) // 2 + (140 if IPAD else 0)   # the same card, centred on the taller or shorter frame
    im.paste(icon, ((W - 300) // 2, top + 560), m)
    centered(d, top + 910, 'Redde', font(92, 'Bold'), (250, 252, 255))
    centered(d, top + 1030, 'Your own AI agent,', font(44, 'Medium'), MIST)
    centered(d, top + 1086, 'by voice or by text.', font(44, 'Medium'), MIST)
    centered(d, top + 1210, 'No account. No tracking.', font(36, 'Semibold'), GOLD)
    im.save(f'{V}/end.png')

# (clip, start, end, background, hold_last_frame_until)
SHOTS = [
    ('c1-stream', 2.7, 8.4, 'agent', None),
    ('c2-voice', 3.5, 7.2, 'voice', None),
    ('c3-rich', 30.3, 35.4, 'rich', None),
    ('c4-kanban', 11.9, 14.7, 'workspace', None),
    ('c4b-kanban', 2.7, 3.85, 'workspace', 2.6),
    ('c5-yours', 11.0, 15.6, 'yours', None),
]
if IPAD:
    SHOTS = [
        ('ipad-c1-stream', 3.2, 9.4, 'agent', None),
        ('ipad-c2-voice', 3.5, 7.8, 'voice', None),
        ('ipad-c3-rich', 35.8, 41.5, 'rich', None),
        ('ipad-c4-kanban', 3.2, 7.8, 'workspace', None),
        ('ipad-c5-yours', 12.2, 17.5, 'yours', None),
    ]
CAPTIONS = {
    'agent': ('Your AI agent, on your iPad' if IPAD else 'Your AI agent, in your pocket', 'Watch it think, use tools and answer live'),
    'voice': ('Just talk', f'Hands-free voice, recognized on your {"iPad" if IPAD else "iPhone"}'),
    'rich': ('Answers with substance', 'Code, checklists and tables, rendered right'),
    'workspace': ('Every chat, job and board', 'Chats, cron and Kanban beside every conversation' if IPAD
                  else 'Swipe right for your whole workspace'),
    'yours': ('Make it yours', 'Seven themes, your colors, 13 app icons'),
}

def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode: print(r.stderr[-1500:]); raise SystemExit(1)

def main():
    mask(); end_card()
    for name, (t, s) in CAPTIONS.items(): caption_card(name, t, s)
    segs = []
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
    run(['ffmpeg', '-v', 'error', '-y', '-loop', '1', '-i', f'{V}/end.png', '-t', '3.4',
         '-vf', 'fps=30,format=yuv420p', '-c:v', 'libx264', '-crf', '14', f'{V}/seg-end.mp4'])
    segs.append((f'{V}/seg-end.mp4', 3.4))

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
    out = f'{V}/redde-app-preview-{"ipad" if IPAD else "iphone"}.mp4'
    run(['ffmpeg', '-v', 'error', '-y', *inputs,
         '-f', 'lavfi', '-t', f'{total:.3f}', '-i', 'anullsrc=channel_layout=stereo:sample_rate=44100',
         '-filter_complex', ';'.join(chain), '-map', last, '-map', f'{len(segs)}:a',
         '-c:v', 'libx264', '-profile:v', 'high', '-level', '4.0', '-pix_fmt', 'yuv420p', '-r', '30',
         '-b:v', '10M', '-maxrate', '11M', '-bufsize', '20M', '-g', '30',   # Apple: High 4.0, 10–12 Mbps
         '-c:a', 'aac', '-b:a', '256k', '-ar', '44100', '-ac', '2', '-shortest', '-movflags', '+faststart', out])
    print(f'{out}  {total:.2f}s')

main()
