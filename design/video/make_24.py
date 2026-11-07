#!/usr/bin/python3
"""The 2.4 App Previews (2026-11-06): what 2.4 brings, full frame (store_cut.py's rule: the screen
capture edge to edge, the words laid over it). A shot a 2.5 s bar of the deep song, as make_day23's
store cut, from the `v24-*` takes (PromoVideoUITests' testV24Goal/Inbox/Today/Memory, recorded with
record.sh --test; the iPad's are `ipad-v24-*`).

  make_24.py          the iPhone's (redde-24-app-preview-iphone.mp4, 886×1920)
  make_24.py ipad     the iPad's (redde-24-app-preview-ipad.mp4, 1200×1600)

The story: the chat list with Today above it ("New in Redde 2.4"), the Today strip swiped, a goal
with its check-in and plan, the inbox sorted into piles, an email opened, a memory added and saved.
"""
import os, sys

ARGS = sys.argv[1:]
IPAD = 'ipad' in ARGS
sys.argv = sys.argv[:1]
import make_preview as mp
import make_cool as mc
import make_day as md
import store_cut as sc

V, FPS = mp.V, mp.FPS
W, H = (1200, 1600) if IPAD else (mp.W, mp.H)
BAR, BEAT, SLIDE = md.BAR, md.BEAT, md.SLIDE
WHITE, MIST, YELLOW = mc.WHITE, mc.MIST, mc.YELLOW
PURPLE, BLUE, GREEN, CORAL, PERIWINKLE = mc.PURPLE, mc.BLUE, mc.GREEN, mc.CORAL, mc.PERIWINKLE

TODAY = ('Today, above your chats', 'Inbox, briefings and goals, a swipe away.')
GOAL = ('Goals', 'A plan, check-ins, and how far along you are.')
INBOX = ('Your inbox, sorted', 'Important, Needs Reply, FYI, News.')
EMAIL = ('Your inbox, sorted', 'Open one, and hand the reply to your agent.')
MEMORY = ('Memory you can see', 'What your agent knows. Add to it, or change it.')

# (take, start, end, caption, colour, bars): start and end in cfr-<take>.mov, set from the frames.
SHOTS = [
    ('v24-today', 23.6, 27.6, TODAY, PURPLE, 1),
    ('v24-goal', 25.6, 31.8, GOAL, CORAL, 2),
    ('v24-inbox', 23.1, 27.6, INBOX, BLUE, 1),
    ('v24-inbox', 30.4, 33.2, EMAIL, BLUE, 1),
    ('v24-memory', 24.6, 30.6, MEMORY, GREEN, 2),
]
TITLE_TAKE = ('v24-today', 19.6, 22.6)   # the chat list, Today above it, before the swipe
END_TAKE = ('v24-today', 28.4)           # and again after it, held
if IPAD:
    exec(open(os.path.join(V, 'v24_ipad_cuts.py')).read())   # SHOTS' cut points, TITLE_TAKE, END_TAKE for ipad-v24-*

TITLE_BARS, END_BARS = 2, 2
LANDS_AT = [BAR * (TITLE_BARS + sum(s[5] for s in SHOTS[:i])) for i in range(len(SHOTS))]
END_AT = BAR * (TITLE_BARS + sum(s[5] for s in SHOTS)) - SLIDE
TOTAL = END_AT + SLIDE + BAR * END_BARS - 0.6
P = 'v24-ipad' if IPAD else 'v24'
OUT = f'redde-24-app-preview-{"ipad" if IPAD else "iphone"}.mp4'
END_LINES = ['Goals with a plan and check-ins.', 'Your inbox, sorted for you.', 'Memory you can see.']
md.P, md.TOTAL = P, TOTAL             # the soundtrack reads these from its own module
S = 1.2 if IPAD else 1.0


def title(t):
    """Over the chat list: "New in / Redde / 2.4", a word a beat."""
    f1, f2 = mp.font(round(92 * S), 'Bold'), mp.font(round(118 * S), 'Bold')
    y = H - round(740 * S)
    return sc.words_over(W, H, t, [('New in', f1, WHITE, y), ('Redde', f1, WHITE, y + round(120 * S)),
                                   ('2.4', f2, YELLOW, y + round(240 * S))],
                         start=BEAT, beat=BEAT, shown=0.15, depth=round(1000 * S))


def ending(t):
    """Over the chat list, held: the name and what 2.4 brings, a line a beat."""
    y, k, depth = (H - 420, 1.05, 760) if IPAD else (H - 800, 1.0, 1100)
    lines = [('Redde 2.4', mp.font(round(120 * k), 'Bold'), WHITE, y)]
    lines += [(line, mp.font(round(44 * k), 'Semibold'), YELLOW if n == len(END_LINES) - 1 else MIST, y + round((170 + n * 66) * k))
              for n, line in enumerate(END_LINES)]
    return sc.words_over(W, H, t, lines, start=SLIDE + 0.25, beat=BEAT, shown=SLIDE, depth=depth, solid=0.88)


def main():
    take, a, b = TITLE_TAKE
    segs = [sc.page(f'{V}/{P}-title.mp4', f'{V}/cfr-{take}.mov', a, b, BAR * TITLE_BARS, title, W, H, f'{P}-title')]
    for i, (take, a, b, words, colour, bars) in enumerate(SHOTS):
        png = f'{V}/{P}-band{i}.png'
        sc.band(png, words, colour, W, H, scale=S)
        same = i and SHOTS[i - 1][3][0] == words[0]
        segs.append(sc.shot(f'{V}/{P}-seg{i}.mp4', f'{V}/cfr-{take}.mov', a, b, BAR * bars + SLIDE, png, W, H, slide_in=not same))
    take, a = END_TAKE
    segs.append(sc.page(f'{V}/{P}-end.mp4', f'{V}/cfr-{take}.mov', a, a + 0.05, TOTAL - END_AT, ending, W, H, f'{P}-end'))
    lands_at = LANDS_AT + [END_AT + SLIDE]
    kinds = ['fade'] + ['fade' if SHOTS[i][3][0] == SHOTS[i - 1][3][0] else 'slideleft' for i in range(1, len(SHOTS))] + ['fade']
    swishes = [at - SLIDE - 0.05 for at, kind in zip(lands_at, kinds) if kind != 'fade']
    lands = [(n * BEAT + 0.02, note) for n, note in ((1, 64), (2, 67), (3, 72))]   # the title's words
    cues = {'groove': BAR * TITLE_BARS, 'quiet': END_AT, 'back': END_AT - 0.3, 'outro': END_AT + SLIDE}
    sound = md.soundtrack([], [], cues, lands, boings=[], pops=[], swishes=swishes)
    out = os.path.normpath(f'{V}/../{OUT}')
    sc.assemble(out, segs, kinds, lands_at, sound)
    print(f'{out}  {TOTAL:.2f}s  (full frame)')
    if TOTAL > 29.8: raise SystemExit('over the App Store’s 30 s')


if __name__ == '__main__':
    main()
