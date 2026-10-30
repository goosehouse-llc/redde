#!/usr/bin/python3
"""The bots App Preview cut to the beat (redde-app-preview-bots-cool.mp4, 886×1920, under 30 s).

Bars of the deep song (96 bpm, 2.5 s a bar), a shot to each, every one sliding in to land on the
bar's first beat: the title (Redde's face, "your agent has a crew" a word a beat, the crew bursting
out), the bots, a bot from templates, an @, a group chat, the voice screen's round with each bot
heard (a bar each, cut where its line pauses), mute, schedules, and the closing page, where the
bot takes the icon's place on the last chord. Big captions slide in over a dark ground with the
bots' colours drifting in it; the footage holds still. Takes as for `make_preview.py bots`.

`long` makes the longer cut (redde-bots-cool-long.mp4, about 54 s, too long for the App Store):
Redde says hello before the title, most shots get two bars so what happens in them is seen at
nearer its own speed, a bot passing work on gets a shot, and each bot in the round says its
whole line, in time with its face.

  /usr/bin/python3 make_cool.py [long]
"""
import math, os, shutil, subprocess, sys
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

LONG = 'long' in sys.argv[1:]
sys.argv = sys.argv[:1]          # make_preview reads its modes from the arguments
import make_preview as mp
import fun_music

V, W, H, FPS = mp.V, mp.W, mp.H, mp.FPS
BAR = fun_music.DEEP_BAR
BEAT = BAR / 4
SLIDE = 0.25                     # a shot slides in over this, landing on the bar
FW, FH = 700, round(700 * 2868 / 1320)
FX, FY = (W - FW) // 2, 400
RADIUS = 56
INK = (8, 10, 18)
WHITE, MIST = (250, 252, 255), (185, 203, 230)
PURPLE, BLUE, GREEN, ORANGE = (168, 140, 245), (95, 185, 240), (130, 212, 120), (247, 152, 92)
TEAL, PERIWINKLE, YELLOW, CORAL = (80, 205, 175), (125, 135, 240), (247, 205, 95), (240, 120, 110)
CREW = ['writer', 'scout', 'fixit', 'researcher', 'coder', 'planner', 'home']

# (take, start, end, caption, its colour, transition in, voice, bars). A shot fills its bars and
# the slide before them: its footage runs bars × BAR + SLIDE, sped to fit. The voice is (line, when
# it starts in the take, seconds of it): with a time, the line is laid where the footage has it,
# its face moving with it; without, just after the shot lands. None for seconds keeps it whole.
TALK = ('They talk', 'Each one in its own voice.')
if not LONG:
    SHOTS = [
        ('b1-list', 6.0, 8.75, ('The crew', 'Every bot has a face, a voice and a job.'), PURPLE, 'slideleft', None, 1),
        ('b2-template', 21.4, 30.0, ('Build one', 'Start from a template. Make it yours.'), GREEN, 'slideleft', None, 1),
        ('b3-mention', 20.6, 26.0, ('@ each other', 'Hand work to another bot.'), BLUE, 'slideup', None, 1),
        ('b5-group', 6.2, 11.7, ('Group chats', 'The whole crew in one room.'), ORANGE, 'slideleft', None, 1),
        ('b7-round', 24.0, 26.75, TALK, TEAL, 'slideup', ('redde', None, 2.24), 1),
        ('b7-round', 29.4, 32.15, TALK, TEAL, 'fade', ('scout', None, 2.38), 1),
        ('b7-round', 36.2, 38.95, TALK, TEAL, 'fade', ('quill', None, 2.22), 1),
        ('b4-mute', 19.0, 24.4, ('Shhh.', 'Mute any of them for a while.'), PERIWINKLE, 'slideleft', None, 1),
        ('b4-mute', 28.8, 34.0, ('On schedule', 'What to wear, every weekday at 7.'), YELLOW, 'slideleft', None, 1),
    ]
    TITLE_BARS, OUT = 1, 'redde-app-preview-bots-cool.mp4'
else:
    SHOTS = [
        ('b1-list', 6.0, 9.4, ('The crew', 'Every bot has a face, a voice and a job.'), PURPLE, 'slideleft', None, 1),
        ('b2-template', 21.4, 29.6, ('Build one', 'Start from a template. Make it yours.'), GREEN, 'slideleft', None, 2),
        ('b3-mention', 16.2, 19.8, ('Pass it on', 'One asks another, and hears back.'), CORAL, 'slideup', None, 1),
        ('b3-mention', 20.6, 28.4, ('@ each other', 'Hand work to any of them.'), BLUE, 'slideleft', None, 2),
        ('b5-group', 6.0, 13.6, ('Group chats', 'The whole crew in one room.'), ORANGE, 'slideleft', None, 2),
        ('b7-round', 23.12, 28.37, TALK, TEAL, 'slideup', ('redde', 23.45, None), 2),
        ('b7-round', 29.07, 34.32, TALK, TEAL, 'fade', ('scout', 29.4, None), 2),
        ('b7-round', 35.92, 41.17, TALK, TEAL, 'fade', ('quill', 36.25, None), 2),
        ('b4-mute', 17.0, 24.9, ('Shhh.', 'Mute any of them for a while.'), PERIWINKLE, 'slideleft', None, 2),
        ('b4-mute', 27.5, 35.5, ('On schedule', 'What to wear, every weekday at 7.'), YELLOW, 'slideleft', None, 2),
    ]
    TITLE_BARS, OUT = 2, 'redde-bots-cool-long.mp4'
P = 'cool-long' if LONG else 'cool'          # the working files' names
# Where each shot lands, on its first bar's first beat.
LANDS_AT = [BAR * (TITLE_BARS + sum(s[7] for s in SHOTS[:i])) for i in range(len(SHOTS))]
END_BARS = 2
END_AT = BAR * (TITLE_BARS + sum(s[7] for s in SHOTS)) - SLIDE     # when the closing page slides in
LAND = BAR + SLIDE                                                 # where, in it, the last chord falls
TOTAL = END_AT + SLIDE + BAR * END_BARS - 0.6     # the last chord rings a moment, then the end
HELLO_AT = 0.4                                    # the long cut's hello, in its first bar


def glows(t, scale=1.0):
    """The ground: near black with four of the bots' colours drifting through it, drawn small and
    blurred, then brought up to size."""
    w, h = W // 4, H // 4
    im = Image.new('RGB', (w, h), INK)
    layer = Image.new('RGB', (w, h), (0, 0, 0))
    d = ImageDraw.Draw(layer)
    for i, (colour, r) in enumerate([(PURPLE, 70), (BLUE, 62), (GREEN, 54), (ORANGE, 58)]):
        x = w * (0.5 + 0.38 * math.sin(t * 0.21 + i * 1.7))
        y = h * (0.5 + 0.42 * math.sin(t * 0.17 + i * 2.3 + 0.6))
        dim = tuple(int(c * 0.42) for c in colour)
        d.ellipse((x - r, y - r, x + r, y + r), fill=dim)
    layer = layer.filter(ImageFilter.GaussianBlur(34))
    im = ImageChops.add(im, layer)
    return im.resize((W, H), Image.BICUBIC)


def ground_video(path):
    frames = f'{V}/frames-{P}-ground'
    shutil.rmtree(frames, ignore_errors=True); os.makedirs(frames)
    for n in range(int(TOTAL * FPS) + FPS):
        glows(n / FPS).save(f'{frames}/{n:04d}.png')
    mp.run(['ffmpeg', '-v', 'error', '-y', '-framerate', str(FPS), '-i', f'{frames}/%04d.png',
            '-vf', 'format=yuv420p', '-c:v', 'libx264', '-crf', '16', path])
    shutil.rmtree(frames)


_italics = {}
def italic(size, weight='Medium Italic'):
    """SF's italic, for what the person says (`said`)."""
    if (size, weight) not in _italics:
        f = ImageFont.truetype('/System/Library/Fonts/SFNSItalic.ttf', size)
        f.set_variation_by_name(weight)
        _italics[(size, weight)] = f
    return _italics[(size, weight)]

def said(words):
    """What the person says in a shot, when its caption carries it: `words` (big words, line)
    or (big words, line, said)."""
    return words[2] if len(words) > 2 and words[2] else None

def wrapped(d, text, font, width):
    """`text` in lines no wider than `width`; two lines evened out, so neither is a word or two."""
    lines = ['']
    for word in text.split():
        joined = f'{lines[-1]} {word}'.strip()
        if not lines[-1] or d.textlength(joined, font=font) <= width: lines[-1] = joined
        else: lines.append(word)
    if len(lines) == 2:
        words = text.split()
        splits = [(' '.join(words[:k]), ' '.join(words[k:])) for k in range(1, len(words))]
        fits = [pair for pair in splits if max(d.textlength(x, font=font) for x in pair) <= width]
        if fits: lines = list(min(fits, key=lambda pair: max(d.textlength(x, font=font) for x in pair)))
    return lines

def caption(path, words, colour):
    """The big words, a bar of their colour over them, and the line under them: bold and medium,
    as the story preview's captions are. When the person is talking in the shot (asked
    2026-10-29: "put the request in quotes and italics to clearly identify it's a user talking"),
    their words take the line's place, in “quotes” and SF's medium italic, white, on one line or
    two; the line itself is left out then."""
    im = Image.new('RGBA', (W, 400), (0, 0, 0, 0)); d = ImageDraw.Draw(im)
    size = 112
    while d.textlength(words[0], font=mp.font(size, 'Bold')) > W - 128: size -= 4
    d.rounded_rectangle((64, 118, 64 + 120, 132), 7, fill=colour + (255,))
    d.text((60, 150), words[0], font=mp.font(size, 'Bold'), fill=WHITE + (255,))
    under = 150 + round(size * 1.24) + 6
    if said(words):
        quote = f'“{said(words)}”'
        f = italic(40)
        lines = wrapped(d, quote, f, W - 136)
        if len(lines) > 1:
            f = italic(36)
            lines = wrapped(d, quote, f, W - 136)[:2]
        for n, line in enumerate(lines):
            d.text((64, under - 2 + n * 44), line, font=f, fill=WHITE + (255,))
    else:
        d.text((66, under), words[1], font=mp.font(36, 'Medium'), fill=MIST + (255,))
    im.save(path)


def glow_card(path, colour):
    """The light behind the phone, in the shot's colour."""
    im = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(im).rounded_rectangle((FX - 10, FY + 30, FX + FW + 10, FY + FH), RADIUS, fill=colour + (90,))
    im.filter(ImageFilter.GaussianBlur(60)).save(path)


def shot(i, take, a, b, words, colour, bars):
    """One shot: its bars and the slide before them, its footage sped to fit and held still, over
    the ground at the moment it plays, its caption sliding in as it lands (and simply there when
    the shot before had the same one)."""
    length = BAR * bars + SLIDE
    speed = (b - a) / length
    starts = LANDS_AT[i] - SLIDE
    caption(f'{V}/{P}-cap{i}.png', words, colour)
    glow_card(f'{V}/{P}-glow{i}.png', colour)
    out = f'{V}/{P}-seg{i}.mp4'
    if i and SHOTS[i - 1][3] == words:
        place = '[s][4:v]overlay=0:0'
    else:
        place = (f'[4:v]format=rgba,fade=t=in:st={SLIDE}:d=0.2:alpha=1[c];'
                 f"[s][c]overlay=x='-140*pow(1-min(1,max(0,(t-{SLIDE})/0.35)),3)':y=0:eval=frame")
    graph = (f'[1:v]setpts=PTS/{speed},fps={FPS},scale={FW}:{FH}:flags=lanczos,setsar=1,format=rgba[f];'
             f'[3:v]format=gray[m];[f][m]alphamerge[fm];'
             f'[0:v][2:v]overlay=0:0[g];[g][fm]overlay={FX}:{FY}[s];'
             f'{place},format=yuv420p,fps={FPS}')
    mp.run(['ffmpeg', '-v', 'error', '-y', '-ss', f'{starts:.3f}', '-t', f'{length:.3f}', '-i', f'{V}/{P}-ground.mp4',
            '-ss', str(a), '-to', str(b), '-i', f'{V}/cfr-{take}.mov',
            '-loop', '1', '-i', f'{V}/{P}-glow{i}.png', '-loop', '1', '-i', f'{V}/{P}-mask.png', '-loop', '1', '-i', f'{V}/{P}-cap{i}.png',
            '-filter_complex', graph, '-t', f'{length:.3f}', '-c:v', 'libx264', '-crf', '14', '-preset', 'medium', out])
    return out, length


def hello(im, t, cx, top):
    """The long cut's "Hi! I'm Redde." bubble, popping up over the face as it is said and gone by
    the next bar, the story preview's bubble."""
    grow = mp.pop((t - HELLO_AT + 0.05) / 0.3)
    gone = mp.ease((t - (BAR - 0.15)) / 0.25)
    if grow <= 0 or gone >= 1: return
    bubble = Image.new('RGBA', (520, 200), (0, 0, 0, 0)); bd = ImageDraw.Draw(bubble)
    bd.rounded_rectangle((10, 10, 510, 150), 44, fill=WHITE + (255,))
    bd.polygon([(64, 140), (120, 140), (44, 196)], fill=WHITE + (255,))
    bd.text((44, 26), "Hi! I'm Redde.", font=mp.font(44, 'Bold'), fill=INK + (255,))
    bd.text((44, 84), 'Meet my crew!', font=mp.font(38, 'Semibold'), fill=(70, 86, 130, 255))
    bubble.alpha_composite(mp.emoji('👋', 54), (420, 46))
    w2, h2 = max(2, round(520 * grow)), max(2, round(200 * grow))
    bubble = bubble.resize((w2, h2), Image.LANCZOS)
    if gone > 0: bubble.putalpha(bubble.getchannel('A').point(lambda v: int(v * (1 - gone))))
    # Grown from the tail's tip, just above the face.
    tip_x, tip_y = cx - 60, top - 4
    im.alpha_composite(bubble, (int(tip_x - 44 * grow), max(0, int(tip_y - 196 * grow))))


def title(t):
    """Redde's face landing on the first beat, "your agent / has a / crew." a word a beat, and on
    the last the crew bursting out from behind it. In the long cut the face lands a bar sooner and
    says hello first."""
    im = glows(t).convert('RGBA')
    hi = BAR * (TITLE_BARS - 1)          # when the words' bar begins
    k = mp.ease(t / 0.28)
    size = round(330 * (1.35 - 0.35 * k))
    bot = mp.face('redde', size).copy(); bot.putalpha(bot.getchannel('A').point(lambda v: int(v * min(1, t / 0.12))))
    cx, cy = W // 2, 640
    burst = (t - hi - 3 * BEAT) / 0.5
    for j, name in enumerate(CREW):
        u = mp.ease(burst)
        if u <= 0: continue
        angle = -math.pi / 2 + (j - 3) * 0.48
        r = 330 * u
        pic = mp.face(name, 128).copy(); pic.putalpha(pic.getchannel('A').point(lambda v: int(v * min(1, burst * 2))))
        im.alpha_composite(pic, (int(cx + r * math.cos(angle) * 1.15 - 64), int(cy + r * math.sin(angle) * 0.75 - 64 - 40)))
    im.alpha_composite(bot, (cx - bot.width // 2, cy - bot.height // 2))
    if LONG: hello(im, t, cx, cy - size // 2)
    for n, word in enumerate(['Your agent', 'has a', 'crew.']):
        u = mp.ease((t - hi - (n + 1) * BEAT) / 0.18)
        if u <= 0: continue
        layer = Image.new('RGBA', (W, H), (0, 0, 0, 0)); ld = ImageDraw.Draw(layer)
        f = mp.font(118 if n == 2 else 92, 'Bold')
        w = ld.textlength(word, font=f)
        ld.text(((W - w) / 2, 940 + n * 120 + 30 * (1 - u)), word, font=f, fill=(YELLOW if n == 2 else WHITE) + (255,))
        layer.putalpha(layer.getchannel('A').point(lambda v: int(v * u)))
        im = Image.alpha_composite(im, layer)
    return im.convert('RGB')


def ending(t):
    """The icon and the name; the bot dropping onto the icon on the last chord and taking its
    place; three short lines; the crew along the bottom."""
    im = glows(END_AT + t).convert('RGBA')
    size, ix, iy = 220, (W - 220) // 2, 420
    pic, m = mp.icon(size)
    k = t - (LAND - 0.09)
    if k < 0.09:
        im.paste(pic, (ix, iy), m)
    elif (u := (k - 0.09) / 0.2) < 1:
        w2, h2 = round(size * (1 + 0.5 * u)), max(1, round(size * (1 - u)))
        flat = pic.convert('RGBA'); flat.putalpha(m); flat = flat.resize((w2, h2), Image.LANCZOS)
        flat.putalpha(flat.getchannel('A').point(lambda v: int(v * (1 - u))))
        im.alpha_composite(flat, (ix + size // 2 - w2 // 2, iy + size - h2))
    if k > 0:
        fall = -(iy + size + 200) * math.exp(-7 * k) * math.cos(11 * k)
        bot = mp.face('redde', 280, 9 * math.exp(-4 * k) * math.sin(13 * k))
        im.paste(bot, (int(ix + size / 2 - bot.width / 2), int(iy + size / 2 + fall - bot.height / 2)), bot)
    d = ImageDraw.Draw(im)
    mp.centered(d, 720, 'Redde', mp.font(128, 'Bold'), WHITE)
    for n, line in enumerate(['Bots with faces and voices.', 'Group chats. Schedules.', 'On your own Hermes.']):
        u = mp.ease((t - 0.25 - n * BEAT) / 0.25)
        if u <= 0: continue
        layer = Image.new('RGBA', (W, H), (0, 0, 0, 0)); ld = ImageDraw.Draw(layer)
        mp.centered(ld, 900 + n * 70, line, mp.font(46, 'Semibold'), (YELLOW if n == 2 else MIST) + (255,))
        layer.putalpha(layer.getchannel('A').point(lambda v: int(v * u)))
        im = Image.alpha_composite(im, layer)
    for j, name in enumerate(CREW):
        u = mp.ease((t - 0.6 - j * 0.07) / 0.3)
        if u <= 0: continue
        pic = mp.face(name, 96).copy(); pic.putalpha(pic.getchannel('A').point(lambda v: int(v * u)))
        x = (W - 6 * 108) / 2 + j * 108 - 48
        im.alpha_composite(pic, (int(x), int(1300 + 20 * (1 - u) + 6 * math.sin(2 * math.pi * 0.7 * t - j * 0.8))))
    return im.convert('RGB')


def page(name, draw, seconds):
    frames = f'{V}/frames-{P}-{name}'
    shutil.rmtree(frames, ignore_errors=True); os.makedirs(frames)
    for n in range(round(seconds * FPS)):
        draw(n / FPS).save(f'{frames}/{n:04d}.png')
    out = f'{V}/{P}-{name}.mp4'
    mp.run(['ffmpeg', '-v', 'error', '-y', '-framerate', str(FPS), '-i', f'{frames}/%04d.png',
            '-vf', 'format=yuv420p', '-c:v', 'libx264', '-crf', '14', out])
    shutil.rmtree(frames)
    return out, seconds


def main():
    mask = Image.new('L', (FW, FH), 0); ImageDraw.Draw(mask).rounded_rectangle((0, 0, FW - 1, FH - 1), RADIUS, fill=255)
    mask.save(f'{V}/{P}-mask.png')
    ground_video(f'{V}/{P}-ground.mp4')
    segs = [page('title', title, BAR * TITLE_BARS)]
    for i, (take, a, b, words, colour, _, _, bars) in enumerate(SHOTS):
        segs.append(shot(i, take, a, b, words, colour, bars))
    segs.append(page('end', ending, TOTAL - END_AT))
    # Each shot lands on its bar's first beat, the slide ending there.
    lands_at = LANDS_AT + [END_AT + SLIDE]
    kinds = [s[5] for s in SHOTS] + ['slideup']
    inputs, chain, last = [], [], '[0:v]'
    for path, _ in segs: inputs += ['-i', path]
    for i in range(1, len(segs)):
        chain.append(f'{last}[{i}:v]xfade=transition={kinds[i - 1]}:duration={SLIDE}:offset={lands_at[i - 1] - SLIDE:.3f}[x{i}]')
        last = f'[x{i}]'
    voices = []
    for (take, a, b, *_, voice, bars), at in zip(SHOTS, LANDS_AT):
        if not voice: continue
        line, said, keep = voice
        when = at - SLIDE + (said - a) / ((b - a) / (BAR * bars + SLIDE)) if said is not None else at + 0.08
        voices.append((when, f'{V}/voice-{line}.wav', *([keep] if keep else [])))
    if LONG: voices.insert(0, (HELLO_AT, f'{V}/voice-hello.wav'))
    swishes = [at - SLIDE - 0.05 for at, kind in zip(lands_at, kinds) if kind != 'fade']
    hi = BAR * (TITLE_BARS - 1)
    lands = [(0.02, 57)] + [(hi + n * BEAT + 0.02, note) for n, note in ((1, 64), (2, 67), (3, 72))]
    round_at = next(at for s, at in zip(SHOTS, LANDS_AT) if s[6])
    last_line = max(at + (keep[0] if keep else len(fun_music.spoken(path)) / fun_music.RATE) for at, path, *keep in voices)
    cues = {'groove': BAR * TITLE_BARS, 'quiet': round_at, 'back': last_line - 0.35, 'outro': END_AT + SLIDE}
    sound = fun_music.render(TOTAL, f'{V}/{P}-music.wav', song='bots', lands=lands, boings=[END_AT + LAND],
                             pops=[HELLO_AT - 0.05] if LONG else [], voices=voices, cues=cues, swishes=swishes)
    out = f'{V}/{OUT}'
    mp.run(['ffmpeg', '-v', 'error', '-y', *inputs, '-i', sound,
            '-filter_complex', ';'.join(chain), '-map', last, '-map', f'{len(segs)}:a',
            '-c:v', 'libx264', '-profile:v', 'high', '-level', '4.0', '-pix_fmt', 'yuv420p', '-r', str(FPS),
            '-b:v', '10M', '-maxrate', '11M', '-bufsize', '20M', '-g', '30',
            '-c:a', 'aac', '-b:a', '256k', '-ar', '44100', '-ac', '2', '-shortest', '-movflags', '+faststart', out])
    print(f'{out}  {TOTAL:.2f}s')


if __name__ == '__main__':
    main()
