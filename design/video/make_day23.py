#!/usr/bin/python3
""""A day with Redde", made again for 2.3 (2026-10-30): the same day told with the new answer cards
and the proactive moments, from the morning's ideas to the evening's wrap-up. Cut as make_day.py's
(a shot a 2.5 s bar of the deep song, landing on the downbeat, the footage still; the time of day by
each caption), from new takes (`e*`, README "A day with Redde, for 2.3"). The cuts go in design/.

  make_day23.py            the iPhone App Store cut, full frame, under 30 s
                           (redde-day23-app-preview-iphone.mp4, 886×1920)
  make_day23.py ipad       the iPad's, full frame, from the ipad- takes (redde-day23-app-preview-ipad.mp4, 1200×1600)
  make_day23.py long       the Reddit cut, framed, about 59 s (redde-day23-reddit.mp4, 886×1920)
  make_day23.py pages      the long cut's title and closing pages as stills

The day: 7:00 Morning Ideas (the bagpipes put away, the vet taken); 7:50 "What's my day look like?",
today as a timeline (the walk over, a free stretch, the now line, the dentist tapped open); 10:15
"Good coffee near me?", places measured from where the phone is; 11:30 Coder's approval in plain
words (long); 12:10 "Will it rain this afternoon?", storms called out; 1:30 PM the dentist's
heads-up, its event card and map; 2:00 PM the Leave-By Alert; 3:35 PM an email to review and send;
8:00 PM the cabin's checklist (long); 9:00 PM the Evening Wrap-up. Nobody real is named.
"""
import os, sys

ARGS = sys.argv[1:]
LONG = 'long' in ARGS
IPAD = 'ipad' in ARGS and not LONG
PAGES_ONLY = 'pages' in ARGS
sys.argv = sys.argv[:1]          # the modules below read their modes from the arguments
import make_preview as mp
import make_cool as mc
import make_day as md
import store_cut as sc
import fun_music
from PIL import Image

V, FPS = mp.V, mp.FPS
W, H = (1200, 1600) if IPAD else (mp.W, mp.H)
BAR, BEAT, SLIDE = md.BAR, md.BEAT, md.SLIDE
WHITE, MIST = mc.WHITE, mc.MIST
PURPLE, BLUE, GREEN, ORANGE = mc.PURPLE, mc.BLUE, mc.GREEN, mc.ORANGE
TEAL, PERIWINKLE, YELLOW, CORAL = mc.TEAL, mc.PERIWINKLE, mc.YELLOW, mc.CORAL

# Captions: (big words, line) or (big words, line, what the person says: drawn in “quotes” and
# italics in the line's place).
IDEAS = ('Morning ideas', 'Swipe right: do it. Left: not now.')
DAY = ('Your day', 'Free time, and what’s done, at a glance.', 'What’s my day look like?')
DAY_OPEN = ('Your day', 'Tap an event to open it.')
NEAR = ('Near you', 'Walks measured from where you are.', 'Good coffee near me?')
NEAR_LINE = ('Near you', 'Walks measured from where you are.')
OK = ('Plain-English approvals', 'What it deletes, in red, before you allow it.')
RAIN = ('The forecast', 'Storms called out, hour by hour.', 'Will it rain this afternoon?')
HEADS = ('Heads-ups', 'Before each event: what to bring.')
WHEN = ('Where and when', 'A countdown, when to leave, a map.')
LEAVE = ('Time to leave', 'Worked out on your iPhone, with Apple Maps.')
EMAIL = ('Review, then send', 'Nothing goes until you tap Send.', 'Tell Ana I’m running 15 minutes late for pickup')
EMAIL_SENT = ('Review, then send', 'Nothing goes until you tap Send.')
PACK = ('Checklists', 'Tick it off, right in the chat.', 'Make me a packing list for the cabin')
WRAP = ('Evening wrap-up', 'What got done, and what’s tomorrow.')
if IPAD:
    LEAVE = (LEAVE[0], 'Worked out on your iPad, with Apple Maps.')

# (kind, take, start, end, caption, colour, transition in, voices, bars, extra), as make_day.py's;
# the start and end are seconds in cfr-<take>.mov, set from the takes' frames (a still screen isn't
# written to a recording, so the UI tests' marks run ahead of the footage). extra: 'clock' the time
# of day by the caption; 'peek' Redde's line (line, when in the take): drawn peeking in from the
# corner in the long cut, heard only in the App Store cuts.
IDEAS_DO = ('Morning ideas', 'Swipe right, and Sol does it.')
if LONG:
    SHOTS = [
        ('take', 'e1-ideas', 22.2, 26.4, IDEAS, GREEN, 'slideleft', [], 1, {'clock': '7:00 AM'}),
        ('take', 'e1-ideas', 28.4, 35.4, IDEAS_DO, GREEN, 'fade', [], 2,
         {'clock': '7:00 AM', 'fix': "select='not(between(t,2.22,2.55))',setpts=N/30/TB"}),   # (a black frame as the chat opens)
        ('take', 'e2-today', 23.6, 28.4, DAY, PURPLE, 'slideleft', [], 1, {'clock': '7:50 AM'}),
        ('take', 'e2-today', 29.2, 33.6, DAY_OPEN, PURPLE, 'fade', [], 1, {'clock': '7:50 AM'}),
        ('take', 'e3-coffee', 24.6, 27.6, NEAR, TEAL, 'slideleft', [], 1, {'clock': '10:15 AM', 'peek': ('coffee', 25.6)}),
        ('take', 'e3-coffee', 27.6, 31.5, NEAR_LINE, TEAL, 'fade', [], 1, {'clock': '10:15 AM'}),
        ('take', 'e5-approval', 19.0, 27.6, OK, CORAL, 'slideleft', [], 2, {'clock': '11:30 AM'}),
        ('take', 'e4-rain', 26.6, 31.0, RAIN, BLUE, 'slideleft', [], 1, {'clock': '12:10 PM'}),
        ('take', 'e6-afternoon', 21.9, 26.8, HEADS, ORANGE, 'slideleft', [], 1, {'clock': '1:30 PM', 'peek': ('headsup2', 22.7)}),
        ('take', 'e6-afternoon', 29.0, 34.8, WHEN, YELLOW, 'slideup', [], 1, {'clock': '1:31 PM'}),
        ('take', 'e7-leave', 22.8, 29.9, LEAVE, YELLOW, 'slideleft', [], 2, {'clock': '2:00 PM', 'peek': ('leave', 23.6)}),
        ('take', 'e8-email', 26.3, 30.6, EMAIL, PERIWINKLE, 'slideleft', [], 1, {'clock': '3:35 PM'}),
        ('take', 'e8-email', 30.6, 35.6, EMAIL_SENT, PERIWINKLE, 'fade', [], 1, {'clock': '3:35 PM', 'peek': ('sent', 33.4)}),
        ('take', 'e9-packing', 26.5, 35.0, PACK, GREEN, 'slideleft', [], 2, {'clock': '8:00 PM'}),
        ('take', 'e10-evening', 19.6, 22.35, WRAP, PURPLE, 'slideleft', [], 2, {'clock': '9:00 PM'}),
    ]
    TITLE_BARS, OUT, P = 2, 'redde-day23-reddit.mp4', 'day23-long'
else:
    SHOTS = [
        ('take', 'e1-ideas', 22.4, 26.2, IDEAS, GREEN, 'fade', [], 1, {'clock': '7:00 AM'}),
        ('take', 'e2-today', 23.6, 28.4, DAY, PURPLE, 'slideleft', [], 1, {'clock': '7:50 AM'}),
        ('take', 'e2-today', 29.2, 33.6, DAY_OPEN, PURPLE, 'fade', [], 1, {'clock': '7:50 AM'}),
        ('take', 'e3-coffee', 25.2, 28.6, NEAR, TEAL, 'slideleft', [], 1, {'clock': '10:15 AM'}),
        ('take', 'e4-rain', 26.9, 30.4, RAIN, BLUE, 'slideleft', [], 1, {'clock': '12:10 PM'}),
        # (the two lines laid back to back, neither over the other)
        ('take', 'e6-afternoon', 21.9, 26.8, HEADS, ORANGE, 'slideleft', [], 1, {'clock': '1:30 PM', 'peek': ('headsup2', 21.9)}),
        ('take', 'e7-leave', 22.8, 27.4, LEAVE, YELLOW, 'slideleft', [], 1, {'clock': '2:00 PM', 'peek': ('leave', 23.9)}),
        ('take', 'e8-email', 27.4, 32.6, EMAIL, PERIWINKLE, 'slideleft', [], 1, {'clock': '3:35 PM'}),
        ('take', 'e10-evening', 19.8, 22.35, WRAP, PURPLE, 'slideleft', [], 1, {'clock': '9:00 PM'}),
    ]
    TITLE_BARS = 1
    OUT = f'redde-day23-app-preview-{"ipad" if IPAD else "iphone"}.mp4'
    P = 'day23-ipad' if IPAD else 'day23'
TITLE_TAKE = ('e1-ideas', 20.0, 22.4)     # the App Store cuts: the chat list at 7:00, before the swipe
END_TAKE = ('e10-evening', 22.3)          # and the wrap-up, held

if IPAD:
    # The iPad's takes (ipad-e…), the same shots: their own cut points (start, end, peek).
    IPAD_CUTS = {}
    exec(open(os.path.join(V, 'day23_ipad_cuts.py')).read())   # IPAD_CUTS, IPAD_TITLE, IPAD_END
    for n, s in enumerate(SHOTS):
        a, b, *peek = IPAD_CUTS[n]
        extra = dict(s[9])
        if 'peek' in extra: extra['peek'] = (extra['peek'][0], peek[0])
        SHOTS[n] = (s[0], 'ipad-' + s[1], a, b, *s[4:9], extra)
    TITLE_TAKE, END_TAKE = ('ipad-' + IPAD_TITLE[0], *IPAD_TITLE[1:]), ('ipad-' + IPAD_END[0], IPAD_END[1])

END_LINES = ['Ideas, heads-ups and time to leave.', 'Your day, the weather, places near you.',
             'Cards you can tap.']
LANDS_AT = [BAR * (TITLE_BARS + sum(s[8] for s in SHOTS[:i])) for i in range(len(SHOTS))]
END_BARS = 2
END_AT = BAR * (TITLE_BARS + sum(s[8] for s in SHOTS)) - SLIDE
TOTAL = END_AT + SLIDE + BAR * END_BARS - 0.6
EVENING = next(at for s, at in zip(SHOTS, LANDS_AT) if s[4][0] == WRAP[0])

# make_day.py's pages and shots read these from their own module: the long cut uses them as they
# are, with this cut's shots, names and closing lines.
md.SHOTS, md.LANDS_AT, md.P, md.TITLE_BARS = SHOTS, LANDS_AT, P, TITLE_BARS
md.END_LINES, md.END_AT, md.TOTAL = END_LINES, END_AT, TOTAL


# --- The App Store cuts, full frame (store_cut.py).

S = 1.2 if IPAD else 1.0             # the words' size: the iPad's frame is wider

def store_title(t):
    """Over the chat list at 7:00, as Redde says "Rise and shine! It's Redde!": "A day / with /
    Redde." a word a beat."""
    f1, f2 = mp.font(round(92 * S), 'Bold'), mp.font(round(118 * S), 'Bold')
    y = H - round(740 * S)
    return sc.words_over(W, H, t, [('A day', f1, WHITE, y), ('with', f1, WHITE, y + round(120 * S)),
                                   ('Redde.', f2, YELLOW, y + round(240 * S))],
                         start=BEAT, beat=BEAT, shown=0.15, depth=round(1000 * S))

def store_ending(t):
    """Over the wrap-up, held: the name and what the day showed, a line a beat."""
    # (the iPad's lower, under the wrap-up's sheet, which sits in the middle of its screen)
    y, k, depth = (H - 420, 1.05, 760) if IPAD else (H - 800, 1.0, 1100)
    lines = [('Redde', mp.font(round(120 * k), 'Bold'), WHITE, y)]
    lines += [(line, mp.font(round(44 * k), 'Semibold'), YELLOW if n == len(END_LINES) - 1 else MIST, y + round((170 + n * 66) * k))
              for n, line in enumerate(END_LINES)]
    return sc.words_over(W, H, t, lines, start=SLIDE + 0.25, beat=BEAT, shown=SLIDE, depth=depth, solid=0.88)

def cues():
    """The deep song: the groove from the first shot, quieter for the evening, the closing."""
    return {'groove': BAR * TITLE_BARS, 'quiet': EVENING, 'back': END_AT - 0.3, 'outro': END_AT + SLIDE}

def store_main():
    take, a, b = TITLE_TAKE
    segs = [sc.page(f'{V}/{P}-title.mp4', f'{V}/cfr-{take}.mov', a, b, BAR * TITLE_BARS, store_title, W, H, f'{P}-title')]
    for i, (kind, take, a, b, words, colour, _, _, bars, extra) in enumerate(SHOTS):
        png = f'{V}/{P}-band{i}.png'
        sc.band(png, words, colour, W, H, extra.get('clock'), scale=S)
        same = i and SHOTS[i - 1][4][0] == words[0] and SHOTS[i - 1][9].get('clock') == extra.get('clock')
        segs.append(sc.shot(f'{V}/{P}-seg{i}.mp4', f'{V}/cfr-{take}.mov', a, b, BAR * bars + SLIDE, png, W, H,
                            slide_in=not same, fix=extra.get('fix')))
    take, a = END_TAKE
    segs.append(sc.page(f'{V}/{P}-end.mp4', f'{V}/cfr-{take}.mov', a, a + 0.05, TOTAL - END_AT, store_ending, W, H, f'{P}-end'))
    lands_at = LANDS_AT + [END_AT + SLIDE]
    kinds = [s[6] for s in SHOTS] + ['fade']
    kinds[0] = 'fade'              # the title's footage goes on as it was
    voices = [(0.2, f'{V}/voice-day-hey.wav'), (END_AT + SLIDE + 0.5, f'{V}/voice-day-bye.wav')]
    for (kind, take, a, b, *_, lines, bars, extra), at in zip(SHOTS, LANDS_AT):
        speed = (b - a) / (BAR * bars + SLIDE)
        if 'peek' in extra:          # Redde's line, heard (no face is drawn over the footage)
            line, said = extra['peek']
            voices.append((at - SLIDE + (said - a) / speed, f'{V}/voice-day-{line}.wav'))
    swishes = [at - SLIDE - 0.05 for at, kind in zip(lands_at, kinds) if kind != 'fade']
    lands = [(n * BEAT + 0.02, note) for n, note in ((1, 64), (2, 67), (3, 72))]
    sound = md.soundtrack(voices, [], cues(), lands, boings=[], pops=[], swishes=swishes)
    out = os.path.normpath(f'{V}/../{OUT}')
    sc.assemble(out, segs, kinds, lands_at, sound)
    print(f'{out}  {TOTAL:.2f}s  (full frame)')
    if TOTAL > 29.8: raise SystemExit('over the App Store’s 30 s')


# --- The Reddit cut, framed (make_day.py's look: the title and closing pages drawn, Redde
# peeking in from the corner to say its lines).

def long_main():
    import shutil
    from PIL import ImageDraw
    mask = Image.new('L', (md.FW, md.FH), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, md.FW - 1, md.FH - 1), md.RADIUS, fill=255)
    mask.save(f'{V}/{P}-mask.png')
    frames = f'{V}/frames-{P}-ground'
    shutil.rmtree(frames, ignore_errors=True); os.makedirs(frames)
    for n in range(int(TOTAL * FPS) + FPS):
        mc.glows(n / FPS).save(f'{frames}/{n:04d}.png')
    mp.run(['ffmpeg', '-v', 'error', '-y', '-framerate', str(FPS), '-i', f'{frames}/%04d.png',
            '-vf', 'format=yuv420p', '-c:v', 'libx264', '-crf', '16', f'{V}/{P}-ground.mp4'])
    shutil.rmtree(frames)
    segs = [md.page('title', md.title, BAR * TITLE_BARS)]
    for i in range(len(SHOTS)):
        segs.append(md.shot(i))
    segs.append(md.page('end', md.ending, TOTAL - END_AT))
    lands_at = LANDS_AT + [END_AT + SLIDE]
    kinds = [s[6] for s in SHOTS] + ['slideup']
    voices = [(md.HEY_AT, f'{V}/voice-day-hey.wav'), (END_AT + md.BYE_AT, f'{V}/voice-day-bye.wav')]
    rings = [(md.BUZZ[0] + 0.07, 0.6), (md.BUZZ[0] + 1.05, 0.6)]
    for (kind, take, a, b, *_, lines, bars, extra), at in zip(SHOTS, LANDS_AT):
        speed = (b - a) / (BAR * bars + SLIDE)
        if 'peek' in extra:
            line, said = extra['peek']
            voices.append((at - SLIDE + (said - a) / speed, f'{V}/voice-day-{line}.wav'))
    swishes = [at - SLIDE - 0.05 for at, kind in zip(lands_at, kinds) if kind != 'fade']
    hi = BAR * (TITLE_BARS - 1)
    lands = [(hi + n * BEAT + 0.02, note) for n, note in ((1, 64), (2, 67), (3, 72))]
    pops = [md.HEY_AT - 0.05, END_AT + md.BYE_AT - 0.05]
    sound = md.soundtrack(voices, rings, cues(), lands, boings=[0.14, END_AT + md.LAND], pops=pops, swishes=swishes)
    sc.assemble(os.path.normpath(f'{V}/../{OUT}'), segs, kinds, lands_at, sound)
    print(os.path.normpath(f'{V}/../{OUT}'), f'{TOTAL:.2f}s')


if __name__ == '__main__':
    if PAGES_ONLY:
        for j, t in enumerate((0.3, 1.6, 3.2, 4.6)): md.title(t).save(f'{V}/{P}-page-title{j}.png')
        for j, t in enumerate((md.LAND + 0.6, md.BYE_AT + 0.4, md.TUCK_AT + 1.2)): md.ending(t).save(f'{V}/{P}-page-end{j}.png')
    elif LONG:
        long_main()
    else:
        store_main()
