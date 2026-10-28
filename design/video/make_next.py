#!/usr/bin/python3
"""The next release's video (after 2.2): the Redde bot calling out with a tiny phone, then what the
release adds, cut to the deep song's bars as the bots App Preview's cool cut is (make_cool.py): a shot
to a 2.5 s bar, each sliding in to land on the downbeat, the footage held still, big captions in the
story preview's bold and medium.

  make_next.py          the App Store cut, under 30 s (redde-next-app-preview.mp4, 886×1920)
  make_next.py long     the longer cut for Reddit, under 60 s (redde-next-reddit.mp4)
  make_next.py pages    the title and closing pages only, as stills (next-page-*.png), to look at

The title: Redde drops in, a tiny phone pops into its mitten and rings, and it calls out "Hey! It's
Redde! Pick up!" (Kokoro, next_voices.py); then "Your agent / can call / you." a word a beat. The
shots: an agent's call answered and talked on (voice mode posed on a call, `-echo.voiceDemoCall`),
a bedtime story asked for on a live call, the agent working on it (the thinking sound, now typing),
and its answer read in the call's voice as it is written (`-echo.demoCall story`), Redde in its 17
languages (Settings in each, a beat apiece), and the Mac app (its icon: the Mac was locked when
these were made, so it has no footage yet). The closing page: Redde drops onto the app icon on the
last chord and takes its place, the phone pops up again and it says "Call you later!".

Takes (iOS 27 simulator, Code theme, dark, the status bar at 9:41; README "The next release's cut"):
cfr-n1-call, cfr-n2-thanks, cfr-n2b-done, cfr-n3-story and the stills lang-<language>.png. The faces are drawn
by the app (EchoTests/PromoCallingTests): faces/redde-*.png.
"""
import array, math, os, shutil, subprocess, sys, wave
from PIL import Image, ImageDraw, ImageFont, ImageFilter

LONG = 'long' in sys.argv[1:]
PAGES_ONLY = 'pages' in sys.argv[1:]
sys.argv = sys.argv[:1]          # make_preview and make_cool read their modes from the arguments
import make_preview as mp
import make_cool as mc
import fun_music

V, W, H, FPS = mp.V, mp.W, mp.H, mp.FPS
REDDE = mp.REDDE
BAR = fun_music.DEEP_BAR
BEAT = BAR / 4
SLIDE = mc.SLIDE
FW, FH, FX, FY, RADIUS = mc.FW, mc.FH, mc.FX, mc.FY, mc.RADIUS
INK, WHITE, MIST = mc.INK, mc.WHITE, mc.MIST
PURPLE, BLUE, GREEN, ORANGE = mc.PURPLE, mc.BLUE, mc.GREEN, mc.ORANGE
TEAL, PERIWINKLE, YELLOW, CORAL = mc.TEAL, mc.PERIWINKLE, mc.YELLOW, mc.CORAL
ICON = f'{REDDE}/Echo/Resources/Assets.xcassets/AppIconFaceMist.appiconset/AppIcon-1024.png'
MAC_ICON = f'{REDDE}/Mac/Assets.xcassets/AppIconMac.appiconset/icon_512x512@2x.png'
TYPING = f'{REDDE}/Echo/Resources/Earcons/thinking.wav'

# Each language's own name, for the pill on its still.
NAMES = {'ja': '日本語', 'de': 'Deutsch', 'es': 'Español', 'ko': '한국어', 'fr': 'Français', 'zh-Hans': '简体中文',
         'zh-Hant': '繁體中文', 'pt-BR': 'Português', 'it': 'Italiano', 'nl': 'Nederlands', 'sv': 'Svenska', 'pl': 'Polski',
         'uk': 'Українська', 'ru': 'Русский', 'tr': 'Türkçe', 'da': 'Dansk', 'nb': 'Norsk'}

CALL = ('It calls you', 'Your agent rings when there’s news.')
STORY = ('In the call’s voice', 'Its answer, read out as it’s written.')
LANGS = ('17 languages', 'All of Redde, in yours.')
MAC = ('Now on the Mac', 'A native app, made for macOS.')
# (kind, take or stills, start, end, caption, colour, transition in, voices, bars). Kinds: 'take',
# footage from cfr-<take>.mov sped to fit its bars and the slide before them; 'flip', stills a beat
# each; 'mac', drawn. A voice is (line, when it starts in the take, seconds of it or None for all).
if not LONG:
    SHOTS = [
        ('take', 'n1-call', 7.05, 9.8, CALL, ORANGE, 'slideleft', [('call', 7.0, None)], 1),
        ('take', 'n2-thanks', 4.75, 7.5, CALL, ORANGE, 'fade', [('thanks', 4.62, None)], 1),
        ('take', 'n2b-done', 4.75, 7.5, CALL, ORANGE, 'fade', [('done', 4.62, None)], 1),
        ('take', 'n3-story', 11.9, 17.15, STORY, TEAL, 'slideup', [('story', 13.15, 3.95)], 2),
        ('flip', ['ja', 'de', 'es', 'ko', 'fr', 'zh-Hans', 'pt-BR', 'it'], 0, 0, LANGS, PURPLE, 'slideleft', [], 2),
        ('mac', None, 0, 0, MAC, BLUE, 'slideleft', [], 1),
    ]
    TITLE_BARS, OUT, P = 2, 'redde-next-app-preview.mp4', 'next'
    TYPING_IN = [3]          # the shots the typing sound is laid under (the agent working)
else:
    SHOTS = [
        ('take', 'n1-call', 6.95, 12.2, CALL, ORANGE, 'slideleft', [('call', 7.0, None)], 2),
        ('take', 'n2-thanks', 4.75, 7.5, CALL, ORANGE, 'fade', [('thanks', 4.62, None)], 1),
        ('take', 'n2b-done', 4.75, 7.5, CALL, ORANGE, 'fade', [('done', 4.62, None)], 1),
        ('take', 'n3-story', 5.65, 10.4, ('On a live call', 'Ask for anything. Even a story.'), CORAL, 'slideup', [('ask', 5.75, None)], 2),
        ('take', 'n3-story', 10.4, 13.15, ('It types', 'While it works, you hear it typing.'), YELLOW, 'slideleft', [], 1),
        ('take', 'n3-story', 13.15, 20.9, STORY, TEAL, 'slideleft', [('story', 13.15, None)], 3),
        ('flip', ['ja', 'de', 'fr', 'ko', 'it', 'zh-Hans', 'pt-BR', 'nl', 'sv', 'pl', 'uk', 'ru', 'tr', 'da', 'nb', 'zh-Hant'],
         0, 0, LANGS, PURPLE, 'slideleft', [], 4),
        ('flip', ['es-voice'], 0, 0, ('Voice mode too', 'Its words, in the language you speak.'), GREEN, 'slideleft', [], 1),
        ('mac', None, 0, 0, MAC, BLUE, 'slideleft', [], 1),
    ]
    TITLE_BARS, OUT, P = 2, 'redde-next-reddit.mp4', 'next-long'
    TYPING_IN = [4]
LANDS_AT = [BAR * (TITLE_BARS + sum(s[8] for s in SHOTS[:i])) for i in range(len(SHOTS))]
END_BARS = 2
END_AT = BAR * (TITLE_BARS + sum(s[8] for s in SHOTS)) - SLIDE
LAND = BAR + SLIDE                       # where, in the closing page, the last chord falls
TOTAL = END_AT + SLIDE + BAR * END_BARS - 0.6
HEY_AT = 0.72                            # "Hey! It's Redde! Pick up!", in the title
BYE_AT = LAND + 0.32                     # "Call you later!", in the closing page


# --- The voices: where each is heard, and how open Redde's mouth is as it says it.

def envelope(path):
    """How loud a line is, each 1/30 s, from 0 to 1."""
    with wave.open(path) as w:
        rate, raw = w.getframerate(), array.array('h', w.readframes(w.getnframes()))
    step = rate // FPS
    levels = [math.sqrt(sum(v * v for v in raw[i:i + step]) / max(1, len(raw[i:i + step]))) for i in range(0, len(raw), step)]
    top = max(levels) or 1
    return [v / top for v in levels]

_env = {}
def mouth(line, start, t):
    """Which talking face, 0 (shut) to 3 (wide), for `line` said from `start`, at `t`."""
    if line not in _env: _env[line] = envelope(f'{V}/voice-next-{line}.wav')
    i = int((t - start) * FPS)
    if not 0 <= i < len(_env[line]): return 0
    level = max(_env[line][max(0, i - 1):i + 1])
    return 0 if level < 0.12 else 1 if level < 0.35 else 2 if level < 0.62 else 3


# --- The Redde bot with its tiny phone.

_pics = {}
def pic(name, size):
    if (name, size) not in _pics:
        _pics[(name, size)] = Image.open(f'{V}/faces/{name}.png').convert('RGBA').resize((size, size), Image.LANCZOS)
    return _pics[(name, size)]

def rings(im, x, y, t, scale):
    """Three arcs going out from the phone's top, the call ringing."""
    layer = Image.new('RGBA', (W, H), (0, 0, 0, 0)); d = ImageDraw.Draw(layer)
    for j in range(3):
        u = (t * 2.2 + j / 3) % 1
        r = scale * (26 + 70 * u)
        a = int(255 * math.sin(math.pi * u) * 0.9)
        d.arc((x - r, y - r, x + r, y + r), -75, -15, fill=WHITE + (a,), width=max(3, round(scale * 7)))
    im.alpha_composite(layer)

def redde_on_the_phone(im, t, cx, cy, size, face='redde-talk-0', phone=1.0, ringing=False, sway=0.0):
    """Redde, `size` across, at (cx, cy): its face (a talking one, a blink, or looking out), and the
    tiny phone in its mitten up by its right side, popped in as far as `phone`, shaking and ringing."""
    turn = sway
    body = pic(face, size).rotate(turn, Image.BICUBIC, expand=True)
    im.alpha_composite(body, (int(cx - body.width / 2), int(cy - body.height / 2)))
    if phone <= 0: return
    side = max(4, round(size * 0.62 * phone))
    shake = 9 * math.sin(2 * math.pi * 9 * t) if ringing else 0
    hold = pic('redde-phone', side).rotate(-14 - shake + turn, Image.BICUBIC, expand=True)
    px, py = cx + size * 0.47, cy - size * 0.04 + 6 * math.sin(2 * math.pi * 0.8 * t)
    im.alpha_composite(hold, (int(px - hold.width / 2), int(py - hold.height / 2)))
    if ringing and phone >= 1: rings(im, px + side * 0.12, py - side * 0.34, t, size / 330)

def talking_face(t, line, start, blink_at=()):
    k = mouth(line, start, t) if line else 0
    if not k and any(0 <= t - b < 0.12 for b in blink_at): return 'redde-blink'
    return f'redde-talk-{k}'

def bubble(im, t, at, until, tip, big, small):
    """A speech bubble popping up from its tail's tip (at its foot, on the left) as it is said, gone
    at `until`: the bots' cut's hello."""
    grow = mp.pop((t - at + 0.05) / 0.3)
    gone = mp.ease((t - until) / 0.2)
    if grow <= 0 or gone >= 1: return
    fb, fs = mp.font(46, 'Bold'), mp.font(38, 'Semibold')
    probe = ImageDraw.Draw(Image.new('RGBA', (8, 8)))
    width = int(max(probe.textlength(big, font=fb), probe.textlength(small, font=fs) if small else 0)) + 88
    height = 150 if small else 96
    b = Image.new('RGBA', (width + 20, height + 50), (0, 0, 0, 0)); bd = ImageDraw.Draw(b)
    bd.rounded_rectangle((10, 10, width + 10, height), 44, fill=WHITE + (255,))
    bd.polygon([(64, height - 10), (120, height - 10), (44, height + 46)], fill=WHITE + (255,))
    bd.text((44, 24 if small else 20), big, font=fb, fill=INK + (255,))
    if small: bd.text((44, 82), small, font=fs, fill=(70, 86, 130, 255))
    w2, h2 = max(2, round(b.width * grow)), max(2, round(b.height * grow))
    b = b.resize((w2, h2), Image.LANCZOS)
    if gone > 0: b.putalpha(b.getchannel('A').point(lambda v: int(v * (1 - gone))))
    tx, ty = tip
    im.alpha_composite(b, (max(0, int(tx - 44 * grow)), max(0, int(ty - (height + 46) * grow))))


# --- The pages.

def title(t):
    """Redde falls in and lands; the phone pops into its mitten and rings while it calls out
    "Hey! It's Redde! Pick up!"; on the second bar it holds the phone and "Your agent / can call /
    you." comes in a word a beat."""
    im = mc.glows(t).convert('RGBA')
    size, cx, cy = 330, W // 2 - 40, 640
    k = t
    fall = -(cy + size) * math.exp(-7 * k) * math.cos(11 * k) if k < 1.2 else 0
    sway = 4 * math.exp(-3 * k) * math.sin(13 * k) + 2.5 * math.sin(2 * math.pi * 0.7 * t)
    ringing = 0.55 < t < BAR - 0.1
    face = talking_face(t, 'hey', HEY_AT, blink_at=(2.9, 4.5))
    if t >= BAR - 0.1 and face == 'redde-talk-0': face = 'redde-look'
    redde_on_the_phone(im, t, cx, cy + fall, size, face, phone=mp.pop((t - 0.42) / 0.3), ringing=ringing, sway=sway)
    bubble(im, t, HEY_AT, BAR - 0.15, (cx - 20, cy - size // 2 + 10 + fall), 'Hey! It’s Redde!', 'Pick up!')
    hi = BAR * (TITLE_BARS - 1)
    for n, word in enumerate(['Your agent', 'can call', 'you.']):
        u = mp.ease((t - hi - (n + 1) * BEAT) / 0.18)
        if u <= 0: continue
        layer = Image.new('RGBA', (W, H), (0, 0, 0, 0)); ld = ImageDraw.Draw(layer)
        f = mp.font(118 if n == 2 else 92, 'Bold')
        w = ld.textlength(word, font=f)
        ld.text(((W - w) / 2, 940 + n * 120 + 30 * (1 - u)), word, font=f, fill=(YELLOW if n == 2 else WHITE) + (255,))
        layer.putalpha(layer.getchannel('A').point(lambda v: int(v * u)))
        im = Image.alpha_composite(im, layer)
    return im.convert('RGB')


def app_icon(size):
    im = Image.open(ICON).convert('RGB').resize((size, size), Image.LANCZOS)
    m = Image.new('L', (size * 2, size * 2), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, size * 2 - 1, size * 2 - 1), int(size * 2 * 0.225), fill=255)
    return im, m.resize((size, size), Image.LANCZOS)


def ending(t):
    """The icon and the name; on the last chord Redde drops onto the icon and takes its place, its
    phone pops up and it says "Call you later!"; what the release brings, a line at a time."""
    im = mc.glows(END_AT + t).convert('RGBA')
    size, ix, iy = 220, (W - 220) // 2, 420
    pic_, m = app_icon(size)
    k = t - (LAND - 0.09)
    if k < 0.09:
        im.paste(pic_, (ix, iy), m)
    elif (u := (k - 0.09) / 0.2) < 1:
        w2, h2 = round(size * (1 + 0.5 * u)), max(1, round(size * (1 - u)))
        flat = pic_.convert('RGBA'); flat.putalpha(m); flat = flat.resize((w2, h2), Image.LANCZOS)
        flat.putalpha(flat.getchannel('A').point(lambda v: int(v * (1 - u))))
        im.alpha_composite(flat, (ix + size // 2 - w2 // 2, iy + size - h2))
    if k > 0:
        fall = -(iy + size + 200) * math.exp(-7 * k) * math.cos(11 * k)
        sway = 9 * math.exp(-4 * k) * math.sin(13 * k) + 2 * math.sin(2 * math.pi * 0.7 * t)
        cx, cy = ix + size / 2 - 30, iy + size / 2 + fall
        face = talking_face(t, 'bye', BYE_AT)
        if face == 'redde-talk-0' and t > BYE_AT + 1.3: face = 'redde-look'
        redde_on_the_phone(im, t, cx, cy, 280, face, phone=mp.pop((t - LAND - 0.2) / 0.3), ringing=t < BYE_AT + 1.2, sway=sway)
        bubble(im, t, BYE_AT, TOTAL - END_AT + 1, (cx - 30, cy - 130), 'Call you later!', None)
    d = ImageDraw.Draw(im)
    mp.centered(d, 720, 'Redde', mp.font(128, 'Bold'), WHITE)
    for n, line in enumerate(['Your agent calls you.', 'Answers in the call’s voice.', '17 languages. Now on the Mac.']):
        u = mp.ease((t - 0.25 - n * BEAT) / 0.25)
        if u <= 0: continue
        layer = Image.new('RGBA', (W, H), (0, 0, 0, 0)); ld = ImageDraw.Draw(layer)
        mp.centered(ld, 900 + n * 70, line, mp.font(46, 'Semibold'), (YELLOW if n == 2 else MIST) + (255,))
        layer.putalpha(layer.getchannel('A').point(lambda v: int(v * u)))
        im = Image.alpha_composite(im, layer)
    return im.convert('RGB')


def mac_page(i):
    """The Mac shot, drawn: the Mac app's icon dropping into place on the downbeat over the ground,
    the caption sliding in as the others' do."""
    words, colour, bars = SHOTS[i][4], SHOTS[i][5], SHOTS[i][8]
    length = BAR * bars + SLIDE
    starts = LANDS_AT[i] - SLIDE
    mc.caption(f'{V}/{P}-cap{i}.png', words, colour)
    cap = Image.open(f'{V}/{P}-cap{i}.png').convert('RGBA')
    icon = Image.open(MAC_ICON).convert('RGBA').resize((560, 560), Image.LANCZOS)
    glow = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse((W / 2 - 300, 760, W / 2 + 300, 1360), fill=colour + (110,))
    glow = glow.filter(ImageFilter.GaussianBlur(90))
    def draw(t):
        im = mc.glows(starts + t).convert('RGBA')
        im.alpha_composite(glow)
        k = t - SLIDE
        drop = -260 * math.exp(-6 * max(0, k)) * math.cos(9 * max(0, k)) if k > 0 else -260
        a = min(1, max(0, (t - 0.05) / 0.2))
        pic_ = icon if a >= 1 else icon.copy()
        if a < 1: pic_.putalpha(pic_.getchannel('A').point(lambda v: int(v * a)))
        im.alpha_composite(pic_, (int((W - 560) / 2), int(780 + drop)))
        d = ImageDraw.Draw(im)
        mp.centered(d, 1400, 'Redde for Mac', mp.font(54, 'Bold'), WHITE)
        mp.centered(d, 1476, 'macOS 26', mp.font(38, 'Medium'), MIST)
        u = mp.ease((t - SLIDE) / 0.35)
        c = cap.copy(); c.putalpha(c.getchannel('A').point(lambda v: int(v * min(1, max(0, (t - SLIDE) / 0.2)))))
        im.alpha_composite(c, (int(-140 * (1 - u) ** 3), 0))
        return im.convert('RGB')
    out, _ = page(f'mac{i}', draw, length)
    return out, length


# --- Footage.

_fonts = {}
def name_font(text, size):
    """A face that has the name's letters: SF for Latin and Cyrillic, Hiragino for Chinese and
    Japanese, Apple SD Gothic for Korean."""
    if any('가' <= c <= '힣' for c in text): path, index = '/System/Library/Fonts/AppleSDGothicNeo.ttc', 6   # its bold
    elif any(ord(c) > 0x2e80 for c in text): path, index = '/System/Library/Fonts/Hiragino Sans GB.ttc', 2   # W6
    else: return mp.font(size, 'Bold')
    if (path, size) not in _fonts: _fonts[(path, size)] = ImageFont.truetype(path, size, index=index)
    return _fonts[(path, size)]

def labelled(code):
    """A still with its language's name on a pill near its foot (at the take's own size)."""
    im = Image.open(f'{V}/lang-{code}.png').convert('RGBA')
    name = NAMES[code.split('-voice')[0]]
    f = name_font(name, 150)
    d = ImageDraw.Draw(im)
    w = d.textlength(name, font=f)
    x0, y0 = (im.width - w) / 2 - 90, im.height - 700
    layer = Image.new('RGBA', im.size, (0, 0, 0, 0)); ld = ImageDraw.Draw(layer)
    ld.rounded_rectangle((x0, y0, x0 + w + 180, y0 + 260), 130, fill=(250, 252, 255, 245))
    ld.text((x0 + 90, y0 + 130), name, font=f, fill=INK + (255,), anchor='lm')
    shadow = Image.new('RGBA', im.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((x0, y0 + 20, x0 + w + 180, y0 + 280), 130, fill=(0, 0, 0, 160))
    im.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(24)))
    im.alpha_composite(layer)
    return im

def flip_video(i, codes, length):
    """The stills as footage, the first under the slide and each next one on a beat."""
    frames = f'{V}/frames-{P}-flip{i}'
    shutil.rmtree(frames, ignore_errors=True); os.makedirs(frames)
    stills = [labelled(c).convert('RGB') for c in codes]
    beats = BEAT if len(codes) > 1 else length
    for n in range(round(length * FPS)):
        t = n / FPS
        j = min(len(codes) - 1, max(0, int((t - SLIDE + 1e-6) // beats) if t >= SLIDE else 0))
        path = f'{frames}/{n:04d}.png'
        if n and j == getattr(flip_video, 'last', -1):
            os.link(f'{frames}/{n - 1:04d}.png', path)
        else:
            stills[j].save(path)
        flip_video.last = j
    out = f'{V}/{P}-flip{i}.mov'
    mp.run(['ffmpeg', '-v', 'error', '-y', '-framerate', str(FPS), '-i', f'{frames}/%04d.png',
            '-vf', 'format=yuv420p', '-c:v', 'libx264', '-crf', '12', out])
    shutil.rmtree(frames)
    return out

def shot(i):
    """One shot: its bars and the slide before them, its footage held still in the phone's frame
    over the ground, its caption sliding in as it lands (simply there when the shot before had the same)."""
    kind, take, a, b, words, colour, _, _, bars = SHOTS[i]
    if kind == 'mac': return mac_page(i)
    length = BAR * bars + SLIDE
    if kind == 'flip':
        source, a, b = flip_video(i, take, length), 0, length
    else:
        source = f'{V}/cfr-{take}.mov'
    speed = (b - a) / length
    starts = LANDS_AT[i] - SLIDE
    mc.caption(f'{V}/{P}-cap{i}.png', words, colour)
    mc.glow_card(f'{V}/{P}-glow{i}.png', colour)
    out = f'{V}/{P}-seg{i}.mp4'
    if i and SHOTS[i - 1][4] == words:
        place = '[s][4:v]overlay=0:0'
    else:
        place = (f'[4:v]format=rgba,fade=t=in:st={SLIDE}:d=0.2:alpha=1[c];'
                 f"[s][c]overlay=x='-140*pow(1-min(1,max(0,(t-{SLIDE})/0.35)),3)':y=0:eval=frame")
    graph = (f'[1:v]setpts=PTS/{speed},fps={FPS},scale={FW}:{FH}:flags=lanczos,setsar=1,format=rgba[f];'
             f'[3:v]format=gray[m];[f][m]alphamerge[fm];'
             f'[0:v][2:v]overlay=0:0[g];[g][fm]overlay={FX}:{FY}[s];'
             f'{place},format=yuv420p,fps={FPS}')
    mp.run(['ffmpeg', '-v', 'error', '-y', '-ss', f'{starts:.3f}', '-t', f'{length:.3f}', '-i', f'{V}/{P}-ground.mp4',
            '-ss', str(a), '-to', str(b), '-i', source,
            '-loop', '1', '-i', f'{V}/{P}-glow{i}.png', '-loop', '1', '-i', f'{V}/{P}-mask.png', '-loop', '1', '-i', f'{V}/{P}-cap{i}.png',
            '-filter_complex', graph, '-t', f'{length:.3f}', '-c:v', 'libx264', '-crf', '14', '-preset', 'medium', out])
    return out, length


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


# --- The sound: the deep song, the lines, the typing and the ring.

RINGS = [(0.62, 0.7), (1.62, 0.7)]       # the tiny phone's ring in the title: (when, how long)

def ring(track, at, length, loud=0.05):
    """A phone's ring, made of bells: two notes trading fast."""
    n = int(length / 0.055)
    for j in range(n):
        track.add(at + j * 0.055, 0.5, fun_music.bell(fun_music.hz(88 if j % 2 else 84), loud * (1 - 0.3 * j / n)))

def soundtrack(voices, typing, cues, lands, boings, pops, swishes):
    """The deep song on the cut's cues; the lines laid in with the music dipping under them (as in
    the bots' cut), the typing under the agent's work, a little quieter, and the ring."""
    laid = fun_music.lay_voices
    def lay(track, lines):
        laid(track, lines)
        s, music = track.s, max(1e-6, max(abs(v) for v in track.s))
        for at, keep in typing:
            sound = fun_music.spoken(TYPING)[:int(keep * fun_music.RATE)]
            peak = max(1e-6, max(abs(v) for v in sound))
            gain = 0.75 * music / peak
            start = int(at * fun_music.RATE)
            fade = int(0.15 * fun_music.RATE)
            for j, v in enumerate(sound):
                if not 0 <= start + j < track.n: continue
                edge = min(1, j / fade, (len(sound) - j) / fade)
                s[start + j] = s[start + j] * (1 - 0.45 * edge) + v * gain * edge
        for at, length in RINGS + END_RINGS:
            ring(track, at, length)
    fun_music.lay_voices = lay
    try:
        return fun_music.render(TOTAL, f'{V}/{P}-music.wav', song='bots', lands=lands, boings=boings, pops=pops,
                                voices=voices, cues=cues, swishes=swishes)
    finally:
        fun_music.lay_voices = laid

END_RINGS = [(END_AT + LAND + 0.22, 0.5)]


def main():
    if PAGES_ONLY:
        for name, draw, at in (('title', title, (0.3, 1.0, 1.6, 3.2, 4.6)), ('end', ending, (LAND + 0.1, LAND + 0.6, LAND + 1.2))):
            for j, t in enumerate(at):
                draw(t).save(f'{V}/{P}-page-{name}{j}.png')
        print('pages written')
        return
    mask = Image.new('L', (FW, FH), 0); ImageDraw.Draw(mask).rounded_rectangle((0, 0, FW - 1, FH - 1), RADIUS, fill=255)
    mask.save(f'{V}/{P}-mask.png')
    ground_seconds = TOTAL
    frames = f'{V}/frames-{P}-ground'
    shutil.rmtree(frames, ignore_errors=True); os.makedirs(frames)
    for n in range(int(ground_seconds * FPS) + FPS):
        mc.glows(n / FPS).save(f'{frames}/{n:04d}.png')
    mp.run(['ffmpeg', '-v', 'error', '-y', '-framerate', str(FPS), '-i', f'{frames}/%04d.png',
            '-vf', 'format=yuv420p', '-c:v', 'libx264', '-crf', '16', f'{V}/{P}-ground.mp4'])
    shutil.rmtree(frames)

    segs = [page('title', title, BAR * TITLE_BARS)]
    for i in range(len(SHOTS)):
        segs.append(shot(i))
    segs.append(page('end', ending, TOTAL - END_AT))
    lands_at = LANDS_AT + [END_AT + SLIDE]
    kinds = [s[6] for s in SHOTS] + ['slideup']
    inputs, chain, last = [], [], '[0:v]'
    for path, _ in segs: inputs += ['-i', path]
    for i in range(1, len(segs)):
        chain.append(f'{last}[{i}:v]xfade=transition={kinds[i - 1]}:duration={SLIDE}:offset={lands_at[i - 1] - SLIDE:.3f}[x{i}]')
        last = f'[x{i}]'

    voices = [(HEY_AT, f'{V}/voice-next-hey.wav'), (END_AT + BYE_AT, f'{V}/voice-next-bye.wav')]
    for (kind, take, a, b, *_, lines, bars), at in zip(SHOTS, LANDS_AT):
        speed = (b - a) / (BAR * bars + SLIDE) if kind == 'take' else 1
        for line, said, keep in lines:
            when = at - SLIDE + (said - a) / speed
            voices.append((when, f'{V}/voice-next-{line}.wav', *([keep] if keep else [])))
    typing = []
    for i in TYPING_IN:
        kind, take, a, b, *_, bars = SHOTS[i]
        # From the question sent (10.3 s in the story take) until the answer starts (13.15 s).
        speed = (b - a) / (BAR * bars + SLIDE)
        start = LANDS_AT[i] - SLIDE + max(0, 10.3 - a) / speed
        typing.append((start, (13.1 - max(a, 10.3)) / speed))
    swishes = [at - SLIDE - 0.05 for at, kind in zip(lands_at, kinds) if kind != 'fade']
    hi = BAR * (TITLE_BARS - 1)
    lands = [(hi + n * BEAT + 0.02, note) for n, note in ((1, 64), (2, 67), (3, 72))]
    story = next(at for s, at in zip(SHOTS, LANDS_AT) if s[4] == STORY or s[4][0] == 'On a live call')
    after = next(at for s, at in zip(SHOTS, LANDS_AT) if s[0] == 'flip')
    cues = {'groove': BAR * TITLE_BARS, 'quiet': story, 'back': after - 0.6, 'outro': END_AT + SLIDE}
    sound = soundtrack(voices, typing, cues, lands, boings=[0.14, END_AT + LAND], pops=[HEY_AT - 0.05, END_AT + BYE_AT - 0.05],
                       swishes=swishes)
    out = f'{V}/{OUT}'
    mp.run(['ffmpeg', '-v', 'error', '-y', *inputs, '-i', sound,
            '-filter_complex', ';'.join(chain), '-map', last, '-map', f'{len(segs)}:a',
            '-c:v', 'libx264', '-profile:v', 'high', '-level', '4.0', '-pix_fmt', 'yuv420p', '-r', str(FPS),
            '-b:v', '10M', '-maxrate', '11M', '-bufsize', '20M', '-g', '30',
            '-c:a', 'aac', '-b:a', '256k', '-ar', '44100', '-ac', '2', '-shortest', '-movflags', '+faststart', out])
    print(f'{out}  {TOTAL:.2f}s')
    if not LONG and TOTAL > 29.8: raise SystemExit('over the App Store’s 30 s')


if __name__ == '__main__':
    main()
