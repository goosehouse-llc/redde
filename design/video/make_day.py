#!/usr/bin/python3
""""A day with Redde": the video for the release with briefings, ideas, @tags, triggers, watches and
routines, told as one day from the morning's heads-up to the night's call, in the next release's
style (make_next.py, the bots' cool cut): a shot to a 2.5 s bar of the deep song, each sliding in to
land on the downbeat, the footage held still, big captions in SF Bold and Medium, sentence case,
each with the time of day it happens at beside its colour bar.

  make_day.py          the App Store cut, under 30 s (redde-day-app-preview.mp4, 886×1920)
  make_day.py long     the whole day, for Reddit, about 67 s (redde-day-reddit.mp4)
  make_day.py pages    the title, the call and the closing pages only, as stills (day-page-*.png)

The title: a sun comes up, Redde drops in, its tiny phone pops into its mitten and buzzes, and it
calls out "Rise and shine! It's Redde!"; then "A day / with / Redde." a word a beat. The shots: the
dentist's heads-up arriving (Redde peeking in from the corner to say it), the morning's idea cards
(the bagpipes put away, the vet taken, and Sol booking it), @Home asked in a chat with Sol, Home's
answer to the arrive-home automation as a notification (a Triggers shot), "Where should we go for
dinner?" answered with a choice card and one tapped (Redde peeking in: "Ooh, pasta!"), the cabin's
packing list as a checklist card ticked to done, the Evening wrap-up, Make This a Routine, Agent
Activity and Plugin Updates, a new watch on the garage door (Home watches, Sol takes over), the tiny
phone ringing ("Sol is calling"), and Sol's call. The
closing page: night, Redde drops onto the app icon on the last chord, says "See you tomorrow!",
tucks its phone away and nods off.

Takes (iOS 27 simulator of its own, Code theme, dark, the status bar at each scene's time; README
"A day with Redde"): cfr-d1-morning … cfr-d10-packing. The faces are drawn by the app
(EchoTests/PromoCallingTests): faces/redde-*.png. The lines: day_voices.py.
"""
import math, os, shutil, sys
from PIL import Image, ImageDraw, ImageFilter

LONG = 'long' in sys.argv[1:]
PAGES_ONLY = 'pages' in sys.argv[1:]
sys.argv = sys.argv[:1]          # the modules below read their modes from the arguments
import make_preview as mp
import make_cool as mc
import make_next as mn
import fun_music

V, W, H, FPS = mp.V, mp.W, mp.H, mp.FPS
BAR = fun_music.DEEP_BAR
BEAT = BAR / 4
SLIDE = mc.SLIDE
FW, FH, FX, FY, RADIUS = mc.FW, mc.FH, mc.FX, mc.FY, mc.RADIUS
INK, WHITE, MIST = mc.INK, mc.WHITE, mc.MIST
PURPLE, BLUE, GREEN, ORANGE = mc.PURPLE, mc.BLUE, mc.GREEN, mc.ORANGE
TEAL, PERIWINKLE, YELLOW, CORAL = mc.TEAL, mc.PERIWINKLE, mc.YELLOW, mc.CORAL
SUN, MOON = (255, 196, 92), (214, 224, 255)

HEADS = ('Heads-ups', 'Before each event, what to bring.')
IDEAS = ('Ideas for you', 'Swipe right: do it. Left: not now.')
TAG = ('@ any bot', 'Ask Home from your chat with Sol.')
WRAP = ('Evening wrap-up', 'Done, waiting on you, and tomorrow.')
WATCH = ('Watches', 'Home keeps an eye out. Sol takes over.')
CALL = ('It calls you', 'When something can’t wait.')
DINNER = ('Pick one', 'Sol asks with a card. One tap answers.')
PACK = ('Checklists', 'Tick it off, right in the chat.')
TRIGGERS = ('Triggers', 'Get home, and Home warms the house.')
# (kind, take, start, end, caption, colour, transition in, voices, bars, extra). Kinds: 'take',
# footage from cfr-<take>.mov sped to fit its bars and the slide before them; 'ring', the tiny phone
# ringing, drawn. A voice is (line, when it starts in the take, seconds of it or None for all).
# extra: 'clock' the time of day by the caption, 'peek' Redde popping up in the corner to say a
# line (line, when in the take), 'fix' a filter for the footage.
if not LONG:
    SHOTS = [
        ('take', 'd1-morning', 21.4, 25.6, HEADS, ORANGE, 'slideleft', [], 1,
         {'clock': '7:00 AM', 'peek': ('headsup', 22.15)}),
        ('take', 'd2-ideas', 26.3, 28.4, IDEAS, GREEN, 'slideleft', [], 1, {'clock': '7:05 AM'}),
        ('take', 'd3-aside', 25.0, 30.0, TAG, BLUE, 'slideup', [], 1, {'clock': '12:30 PM'}),
        ('take', 'd9-dinner', 30.4, 36.6, DINNER, ORANGE, 'slideleft', [], 1, {'clock': '6:30 PM', 'peek': ('pasta', 34.0)}),
        ('take', 'd10-packing', 32.8, 38.8, PACK, GREEN, 'slideup', [], 1, {'clock': '8:00 PM'}),
        ('take', 'd7-watch', 35.4, 40.6, WATCH, TEAL, 'slideup', [], 1, {'clock': '10:00 PM'}),
        ('take', 'd8-call', 5.75, 10.95, CALL, CORAL, 'slideleft', [('call', 5.75, None)], 2, {'clock': '10:40 PM'}),
    ]
    TITLE_BARS, OUT, P = 2, 'redde-day-app-preview.mp4', 'day'
else:
    SHOTS = [
        ('take', 'd1-morning', 21.0, 28.6, HEADS, ORANGE, 'slideleft', [], 2,
         {'clock': '7:00 AM', 'peek': ('headsup', 22.15)}),
        ('take', 'd2-ideas', 20.3, 28.1, IDEAS, GREEN, 'slideleft', [('pipes', 20.55, None)], 2, {'clock': '7:05 AM'}),
        ('take', 'd2-ideas', 28.5, 33.2, ('Do it', 'Sol takes it from there.'), GREEN, 'fade', [], 1, {'clock': '7:06 AM'}),
        ('take', 'd3-aside', 21.8, 30.6, TAG, BLUE, 'slideup', [], 2, {'clock': '12:30 PM'}),
        ('take', 'd4b-home', 23.4, 27.0, TRIGGERS, YELLOW, 'slideleft', [], 1, {'clock': '6:05 PM'}),
        ('take', 'd9-dinner', 28.6, 37.6, DINNER, ORANGE, 'slideleft', [], 2, {'clock': '6:30 PM', 'peek': ('pasta', 34.0)}),
        ('take', 'd10-packing', 27.0, 38.8, PACK, GREEN, 'slideup', [], 2, {'clock': '8:00 PM'}),
        ('take', 'd5-evening', 21.0, 25.8, WRAP, PURPLE, 'slideleft', [], 1, {'clock': '9:00 PM'}),
        ('take', 'd6-routine', 22.6, 27.2, ('Routines', 'Teach it once. It runs every week.'), PERIWINKLE, 'slideleft', [], 1,
         {'clock': '9:05 PM'}),
        ('take', 'd6b-activity', 19.4, 22.9, ('Agent activity', 'All your agents did on their own.'), PERIWINKLE, 'slideup', [], 1,
         {'clock': '9:05 PM'}),
        ('take', 'd6c-plugins', 19.5, 23.3, ('Plugin updates', 'Every agent’s plugins, at once.'), PERIWINKLE, 'slideup', [], 1,
         {'clock': '9:06 PM'}),
        ('take', 'd7-watch', 27.6, 40.8, WATCH, TEAL, 'slideleft', [], 2, {'clock': '10:00 PM'}),
        ('ring', None, 0, 0, CALL, CORAL, 'slideup', [], 1, {'clock': '10:40 PM'}),
        ('take', 'd8-call', 5.75, 11.0, CALL, CORAL, 'fade', [('call', 5.75, None)], 2, {'clock': '10:40 PM'}),
        ('take', 'd8b-yes', 5.55, 8.4, CALL, CORAL, 'fade', [('yes', 5.6, None)], 1, {'clock': '10:40 PM'}),
        ('take', 'd8c-done', 5.55, 8.4, CALL, CORAL, 'fade', [('done', 5.6, None)], 1, {'clock': '10:41 PM'}),
    ]
    TITLE_BARS, OUT, P = 2, 'redde-day-reddit.mp4', 'day-long'
LANDS_AT = [BAR * (TITLE_BARS + sum(s[8] for s in SHOTS[:i])) for i in range(len(SHOTS))]
END_BARS = 2
END_AT = BAR * (TITLE_BARS + sum(s[8] for s in SHOTS)) - SLIDE
LAND = BAR + SLIDE                       # where, in the closing page, the last chord falls
TOTAL = END_AT + SLIDE + BAR * END_BARS - 0.6
HEY_AT = 0.72                            # "Rise and shine! It's Redde!", in the title
BYE_AT = LAND + 0.32                     # "See you tomorrow!", in the closing page
TUCK_AT = BYE_AT + 1.75                  # the phone put away
BUZZ = (0.55, BAR - 0.15)                # the tiny phone buzzing in the title, from and to


# --- Faces and voices.

_env = {}
def mouth(line, start, t):
    """Which talking face, 0 (shut) to 3 (wide), for `line` said from `start`, at `t`."""
    if line not in _env: _env[line] = mn.envelope(f'{V}/voice-day-{line}.wav')
    i = int((t - start) * FPS)
    if not 0 <= i < len(_env[line]): return 0
    level = max(_env[line][max(0, i - 1):i + 1])
    return 0 if level < 0.12 else 1 if level < 0.35 else 2 if level < 0.62 else 3

def talking_face(t, line, start, blink_at=()):
    k = mouth(line, start, t) if line else 0
    if not k and any(0 <= t - b < 0.12 for b in blink_at): return 'redde-blink'
    return f'redde-talk-{k}'

def redde(im, t, cx, cy, size, face, phone=1.0, ringing=False, sway=0.0, tuck=0.0):
    """Redde with its tiny phone, as make_next draws it; `tuck` from 0 to 1 puts the phone away,
    down behind its side, smaller and smaller."""
    tuck = min(1.0, max(0.0, tuck))
    body = mn.pic(face, size).rotate(sway, Image.BICUBIC, expand=True)
    im.alpha_composite(body, (int(cx - body.width / 2), int(cy - body.height / 2)))
    k = phone * (1 - mp.ease(tuck))
    if k <= 0.02: return
    side = max(4, round(size * 0.62 * k))
    shake = 9 * math.sin(2 * math.pi * 9 * t) if ringing else 0
    hold = mn.pic('redde-phone', side).rotate(-14 - shake + sway - 50 * tuck, Image.BICUBIC, expand=True)
    px = cx + size * (0.47 - 0.12 * tuck)
    py = cy - size * 0.04 + size * 0.36 * tuck + 6 * math.sin(2 * math.pi * 0.8 * t)
    im.alpha_composite(hold, (int(px - hold.width / 2), int(py - hold.height / 2)))
    if ringing and k >= 1: mn.rings(im, px + side * 0.12, py - side * 0.34, t, size / 330)


# --- The sky: the sun coming up in the title, the moon and stars over the closing page.

def _sun():
    s = Image.new('RGBA', (900, 900), (0, 0, 0, 0)); d = ImageDraw.Draw(s)
    d.ellipse((170, 170, 730, 730), fill=SUN + (110,))
    s = s.filter(ImageFilter.GaussianBlur(120))
    core = Image.new('RGBA', (900, 900), (0, 0, 0, 0))
    ImageDraw.Draw(core).ellipse((370, 370, 530, 530), fill=SUN + (200,))
    s.alpha_composite(core.filter(ImageFilter.GaussianBlur(14)))
    return s
SUN_PIC = _sun()

def sunrise(im, t):
    """The sun climbing up out of the foot of the frame over the title's first bar and a half."""
    u = mp.ease(t / (BAR * 1.6))
    y = H + 250 - 650 * u
    im.alpha_composite(SUN_PIC, (int(W * 0.8 - 450), int(y - 450)))

STARS = [(0.08, 0.06), (0.21, 0.13), (0.34, 0.05), (0.62, 0.09), (0.86, 0.17), (0.12, 0.29), (0.47, 0.18),
         (0.93, 0.33), (0.29, 0.36), (0.78, 0.05), (0.56, 0.31), (0.03, 0.2)]

def _moon():
    m = Image.new('RGBA', (360, 360), (0, 0, 0, 0)); d = ImageDraw.Draw(m)
    d.ellipse((60, 60, 300, 300), fill=MOON + (70,))
    m = m.filter(ImageFilter.GaussianBlur(40))
    disc = Image.new('L', (360, 360), 0); dd = ImageDraw.Draw(disc)
    dd.ellipse((110, 110, 250, 250), fill=255)
    dd.ellipse((150, 88, 290, 228), fill=0)          # the crescent's bite
    face = Image.new('RGBA', (360, 360), MOON + (255,)); face.putalpha(disc)
    m.alpha_composite(face)
    return m
MOON_PIC = _moon()

def night(im, t, come=0.0):
    """Stars twinkling and a crescent moon top right, faded in from `come` seconds."""
    a = mp.ease((t - come) / 0.6)
    if a <= 0: return
    layer = Image.new('RGBA', (W, H), (0, 0, 0, 0)); d = ImageDraw.Draw(layer)
    for j, (x, y) in enumerate(STARS):
        tw = 0.55 + 0.45 * math.sin(t * 2.2 + j * 1.7)
        r = 3 + (j % 3)
        d.ellipse((x * W - r, y * H - r, x * W + r, y * H + r), fill=WHITE + (int(220 * tw),))
    layer.alpha_composite(MOON_PIC, (W - 330, 70))
    if a < 1: layer.putalpha(layer.getchannel('A').point(lambda v: int(v * a)))
    im.alpha_composite(layer)


# --- The captions, each with the time of day beside its colour bar.

def clock_icon(d, x, y, colour, evening):
    """A little sun (rays and all) or a crescent moon, 30 px, its middle at (x, y)."""
    if evening:
        d.ellipse((x - 14, y - 14, x + 14, y + 14), fill=colour + (255,))
        d.ellipse((x - 6, y - 20, x + 20, y + 6), fill=(0, 0, 0, 0))
    else:
        d.ellipse((x - 8, y - 8, x + 8, y + 8), fill=colour + (255,))
        for k in range(8):
            a = k * math.pi / 4
            d.line((x + 12 * math.cos(a), y + 12 * math.sin(a), x + 17 * math.cos(a), y + 17 * math.sin(a)), fill=colour + (255,), width=3)

def caption(path, words, colour, clock):
    mc.caption(path, words, colour)
    if not clock: return
    im = Image.open(path).convert('RGBA'); d = ImageDraw.Draw(im)
    evening = 'PM' in clock and int(clock.split(':')[0]) % 12 >= 6
    clock_icon(d, 214, 125, colour, evening)
    d.text((240, 125), clock, font=mp.font(34, 'Semibold'), fill=colour + (255,), anchor='lm')
    im.save(path)


# --- The pages.

def title(t):
    """The sun coming up; Redde falls in and lands, the phone pops into its mitten and buzzes while
    it calls out "Rise and shine! It's Redde!"; on the second bar "A day / with / Redde." a word a beat."""
    im = mc.glows(t).convert('RGBA')
    sunrise(im, t)
    size, cx, cy = 330, W // 2 - 40, 640
    fall = -(cy + size) * math.exp(-7 * t) * math.cos(11 * t) if t < 1.2 else 0
    sway = 4 * math.exp(-3 * t) * math.sin(13 * t) + 2.5 * math.sin(2 * math.pi * 0.7 * t)
    face = talking_face(t, 'hey', HEY_AT, blink_at=(3.1, 4.6))
    if t >= BAR - 0.1 and face == 'redde-talk-0': face = 'redde-look'
    redde(im, t, cx, cy + fall, size, face, phone=mp.pop((t - 0.42) / 0.3), ringing=BUZZ[0] < t < BUZZ[1], sway=sway)
    mn.bubble(im, t, HEY_AT, BAR - 0.15, (cx - 20, cy - size // 2 + 10 + fall), 'Rise and shine!', 'It’s Redde!')
    hi = BAR * (TITLE_BARS - 1)
    for n, word in enumerate(['A day', 'with', 'Redde.']):
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
    """Night: the icon and the name; on the last chord Redde drops onto the icon and takes its
    place, its phone pops up, it says "See you tomorrow!", puts the phone away and nods off; what
    the release brings, a line at a time."""
    im = mc.glows(END_AT + t).convert('RGBA')
    night(im, t)
    size, ix, iy = 220, (W - 220) // 2, 420
    pic_, m = mn.app_icon(size)
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
        if face == 'redde-talk-0' and t > BYE_AT + 1.2: face = 'redde-look'
        if t > TUCK_AT + 0.45: face = 'redde-blink'          # nodding off
        nod = 5 * mp.ease((t - TUCK_AT - 0.45) / 0.5)
        redde(im, t, cx, cy + nod, 280, face, phone=mp.pop((t - LAND - 0.2) / 0.3), sway=sway + nod,
              tuck=(t - TUCK_AT) / 0.45)
        mn.bubble(im, t, BYE_AT, TUCK_AT + 0.6, (cx - 30, cy - 130), 'See you tomorrow!', None)
        if t > TUCK_AT + 0.7:      # a small "z" floating up
            for j in range(2):
                u = ((t - TUCK_AT - 0.7) * 0.6 + j * 0.5) % 1
                layer = Image.new('RGBA', (W, H), (0, 0, 0, 0)); ld = ImageDraw.Draw(layer)
                ld.text((cx + 120 + 40 * u, cy - 150 - 120 * u), 'z', font=mp.font(44 + 18 * j, 'Bold'),
                        fill=MOON + (int(255 * math.sin(math.pi * u)),))
                im.alpha_composite(layer)
    d = ImageDraw.Draw(im)
    mp.centered(d, 720, 'Redde', mp.font(128, 'Bold'), WHITE)
    for n, line in enumerate(['Heads-ups, ideas and wrap-ups.', '@ any bot. Triggers. Routines.', 'Watchers that call you.']):
        u = mp.ease((t - 0.25 - n * BEAT) / 0.25)
        if u <= 0: continue
        layer = Image.new('RGBA', (W, H), (0, 0, 0, 0)); ld = ImageDraw.Draw(layer)
        mp.centered(ld, 900 + n * 70, line, mp.font(46, 'Semibold'), (YELLOW if n == 2 else MIST) + (255,))
        layer.putalpha(layer.getchannel('A').point(lambda v: int(v * u)))
        im = Image.alpha_composite(im, layer)
    return im.convert('RGB')


def ring_draw(i):
    """The ring page's frames: the tiny phone big in the middle, shaking and ringing, "Sol /
    is calling…" under it, at night; the caption sliding in as the others' do."""
    words, colour, bars, extra = SHOTS[i][4], SHOTS[i][5], SHOTS[i][8], SHOTS[i][9]
    starts = LANDS_AT[i] - SLIDE
    caption(f'{V}/{P}-cap{i}.png', words, colour, extra.get('clock'))
    cap = Image.open(f'{V}/{P}-cap{i}.png').convert('RGBA')
    glow = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse((W / 2 - 300, 560, W / 2 + 300, 1160), fill=colour + (90,))
    glow = glow.filter(ImageFilter.GaussianBlur(90))
    def draw(t):
        im = mc.glows(starts + t).convert('RGBA')
        night(im, t, come=-1)
        im.alpha_composite(glow)
        k = t - SLIDE
        grow = mp.pop(k / 0.3) if k > 0 else 0
        if grow > 0:
            side = round(520 * grow)
            shake = 7 * math.sin(2 * math.pi * 9 * t) if k > 0.3 else 0
            phone = mn.pic('redde-phone', side).rotate(-8 - shake, Image.BICUBIC, expand=True)
            im.alpha_composite(phone, (int(W / 2 - phone.width / 2 + 10), int(860 - phone.height / 2)))
            if k > 0.3: mn.rings(im, W / 2 + 40, 860 - 230, t, 1.6)
        d = ImageDraw.Draw(im)
        a = mp.ease((t - SLIDE - 0.2) / 0.3)
        if a > 0:
            layer = Image.new('RGBA', (W, H), (0, 0, 0, 0)); ld = ImageDraw.Draw(layer)
            mp.centered(ld, 1190, 'Sol', mp.font(96, 'Bold'), WHITE + (255,))
            mp.centered(ld, 1310, 'is calling…', mp.font(44, 'Medium'), MIST + (255,))
            layer.putalpha(layer.getchannel('A').point(lambda v: int(v * a)))
            im.alpha_composite(layer)
        u = mp.ease((t - SLIDE) / 0.35)
        c = cap.copy(); c.putalpha(c.getchannel('A').point(lambda v: int(v * min(1, max(0, (t - SLIDE) / 0.2)))))
        im.alpha_composite(c, (int(-140 * (1 - u) ** 3), 0))
        return im.convert('RGB')
    return draw

def ring_page(i):
    length = BAR * SHOTS[i][8] + SLIDE
    out, _ = page(f'ring{i}', ring_draw(i), length)
    return out, length


# --- Footage.

def peek_overlay(i, length, speed):
    """Redde popping up from the bottom right corner to say its line, then ducking away again:
    frames with alpha, laid over the shot."""
    line, said = SHOTS[i][9]['peek']
    a = SHOTS[i][2]
    at = (said - a) / speed      # when, in the shot, it starts
    seconds = len(mn.envelope(f'{V}/voice-day-{line}.wav')) / FPS
    up, down = at - 0.35, at + seconds + 0.25
    frames = f'{V}/frames-{P}-peek{i}'
    shutil.rmtree(frames, ignore_errors=True); os.makedirs(frames)
    size = 260
    for n in range(round(length * FPS)):
        t = n / FPS
        im = Image.new('RGBA', (W, H), (0, 0, 0, 0))
        rise = mp.pop((t - up) / 0.35) - mp.ease((t - down) / 0.3)
        if rise > 0.01:
            cy = H + size * 0.6 - (size * 1.05) * rise
            face = talking_face(t, line, at)
            redde(im, t, W - 215, cy, size, face, phone=1.0, sway=-6 + 3 * math.sin(2 * math.pi * 0.9 * t))
        im.save(f'{frames}/{n:04d}.png')
    return frames

def shot(i):
    """One shot: its bars and the slide before them, its footage held still in the phone's frame
    over the ground, its caption sliding in as it lands (simply there when the shot before had the
    same), and Redde peeking in when it has a line here."""
    kind, take, a, b, words, colour, _, _, bars, extra = SHOTS[i]
    if kind == 'ring': return ring_page(i)
    length = BAR * bars + SLIDE
    speed = (b - a) / length
    starts = LANDS_AT[i] - SLIDE
    caption(f'{V}/{P}-cap{i}.png', words, colour, extra.get('clock'))
    mc.glow_card(f'{V}/{P}-glow{i}.png', colour)
    out = f'{V}/{P}-seg{i}.mp4'
    same = i and SHOTS[i - 1][4] == words and SHOTS[i - 1][9].get('clock') == extra.get('clock')
    if same:
        place = '[s][4:v]overlay=0:0[p]'
    else:
        place = (f'[4:v]format=rgba,fade=t=in:st={SLIDE}:d=0.2:alpha=1[c];'
                 f"[s][c]overlay=x='-140*pow(1-min(1,max(0,(t-{SLIDE})/0.35)),3)':y=0:eval=frame[p]")
    fix = extra.get('fix')
    inputs = ['-ss', f'{starts:.3f}', '-t', f'{length:.3f}', '-i', f'{V}/{P}-ground.mp4',
              '-ss', str(a), '-to', str(b), '-i', f'{V}/cfr-{take}.mov',
              '-loop', '1', '-i', f'{V}/{P}-glow{i}.png', '-loop', '1', '-i', f'{V}/{P}-mask.png', '-loop', '1', '-i', f'{V}/{P}-cap{i}.png']
    last = '[p]'
    peek = None
    if 'peek' in extra:
        peek = peek_overlay(i, length, speed)
        inputs += ['-framerate', str(FPS), '-i', f'{peek}/%04d.png']
        place += ';[p][5:v]overlay=0:0[q]'
        last = '[q]'
    graph = (f'[1:v]{fix + "," if fix else ""}setpts=PTS/{speed},fps={FPS},scale={FW}:{FH}:flags=lanczos,setsar=1,format=rgba[f];'
             f'[3:v]format=gray[m];[f][m]alphamerge[fm];'
             f'[0:v][2:v]overlay=0:0[g];[g][fm]overlay={FX}:{FY}[s];'
             f'{place};{last}format=yuv420p,fps={FPS}')
    mp.run(['ffmpeg', '-v', 'error', '-y', *inputs,
            '-filter_complex', graph, '-t', f'{length:.3f}', '-c:v', 'libx264', '-crf', '14', '-preset', 'medium', out])
    if peek: shutil.rmtree(peek)
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


# --- The sound: the deep song, the lines, the buzz and the ring.

def soundtrack(voices, rings, cues, lands, boings, pops, swishes):
    """The deep song on the cut's cues, the lines laid in with the music dipping under them (as in
    the bots' cut), and the tiny phone's buzz and ring."""
    laid = fun_music.lay_voices
    def lay(track, lines):
        laid(track, lines)
        for at, length in rings:
            mn.ring(track, at, length)
    fun_music.lay_voices = lay
    try:
        return fun_music.render(TOTAL, f'{V}/{P}-music.wav', song='bots', lands=lands, boings=boings, pops=pops,
                                voices=voices, cues=cues, swishes=swishes)
    finally:
        fun_music.lay_voices = laid


def main():
    if PAGES_ONLY:
        pages = [('title', title, (0.3, 1.0, 1.6, 3.2, 4.6)),
                 ('end', ending, (LAND + 0.1, LAND + 0.6, BYE_AT + 0.4, TUCK_AT + 0.25, TUCK_AT + 1.2))]
        rings_at = [i for i, s in enumerate(SHOTS) if s[0] == 'ring']
        if rings_at: pages.append(('ring', ring_draw(rings_at[0]), (0.4, 1.4)))
        for name, draw, at in pages:
            for j, t in enumerate(at):
                draw(t).save(f'{V}/{P}-page-{name}{j}.png')
        print('pages written')
        return
    mask = Image.new('L', (FW, FH), 0); ImageDraw.Draw(mask).rounded_rectangle((0, 0, FW - 1, FH - 1), RADIUS, fill=255)
    mask.save(f'{V}/{P}-mask.png')
    frames = f'{V}/frames-{P}-ground'
    shutil.rmtree(frames, ignore_errors=True); os.makedirs(frames)
    for n in range(int(TOTAL * FPS) + FPS):
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

    voices = [(HEY_AT, f'{V}/voice-day-hey.wav'), (END_AT + BYE_AT, f'{V}/voice-day-bye.wav')]
    rings = [(BUZZ[0] + 0.07, 0.6), (BUZZ[0] + 1.05, 0.6)]
    for (kind, take, a, b, *_, lines, bars, extra), at in zip(SHOTS, LANDS_AT):
        speed = (b - a) / (BAR * bars + SLIDE) if kind == 'take' else 1
        for line, said, keep in lines:
            voices.append((at - SLIDE + (said - a) / speed, f'{V}/voice-day-{line}.wav', *([keep] if keep else [])))
        if 'peek' in extra:
            line, said = extra['peek']
            voices.append((at - SLIDE + (said - a) / speed, f'{V}/voice-day-{line}.wav'))
        if kind == 'ring':
            rings += [(at + 0.3, 0.7), (at + 1.3, 0.7)]
    swishes = [at - SLIDE - 0.05 for at, kind in zip(lands_at, kinds) if kind != 'fade']
    hi = BAR * (TITLE_BARS - 1)
    lands = [(hi + n * BEAT + 0.02, note) for n, note in ((1, 64), (2, 67), (3, 72))]
    call = next(at for s, at in zip(SHOTS, LANDS_AT) if s[4] == CALL)
    cues = {'groove': BAR * TITLE_BARS, 'quiet': call, 'back': END_AT, 'outro': END_AT + SLIDE}
    pops = [HEY_AT - 0.05, END_AT + BYE_AT - 0.05]
    sound = soundtrack(voices, rings, cues, lands, boings=[0.14, END_AT + LAND], pops=pops, swishes=swishes)
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
