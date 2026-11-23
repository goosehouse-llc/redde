#!/usr/bin/python3
"""The 2.7 App Preview for iPhone (2026-11-22): every AI agent in one app, full frame (store_cut.py's
rule: the screen capture edge to edge, the words laid over it), a shot two 2.5 s bars of the deep
song, as make_24's. The store had shown 2.3.1's day cut since October; 2.4's were never uploaded.

  make_27.py          redde-27-app-preview-iphone.mp4 (886×1920), in design/
  make_27.py ipad     redde-27-app-preview-ipad.mp4 (1200×1600), from the iPad's take (v27_ipad_cuts.py)

All from the agents take (cfr-c1-coders.mov, PromoVideoUITests.testAgentsCoders, 2026-11-15): the
chat list, the server menu with Hermes, Claude Code and Codex; Claude Code fixing the login bug and
asking before it runs the tests; the stack of what needs you, Claude Code's change on top. Claude
Code and Codex are scripted stand-ins (`-echo.demoCoders`), as the closing's small print says.
"""
import os, sys

IPAD = 'ipad' in sys.argv[1:]
sys.argv = sys.argv[:1]
import make_preview as mp
import make_cool as mc
import make_day as md
import store_cut as sc

V, FPS = mp.V, mp.FPS
W, H = (1200, 1600) if IPAD else (mp.W, mp.H)
S = 1.2 if IPAD else 1.0
BAR, BEAT, SLIDE = md.BAR, md.BEAT, md.SLIDE
WHITE, MIST, YELLOW = mc.WHITE, mc.MIST, mc.YELLOW
PURPLE, ORANGE, CORAL = mc.PURPLE, mc.ORANGE, mc.CORAL

T = 'c1-coders'
ALL = ('All your agents', 'Your Hermes bots, Claude Code and Codex.')
CLAUDE = ('Claude Code gets to work', '', 'Fix the login bug')
ALLOW = ('It asks you first', 'Allow Once, and it runs the tests.')
NEEDS = ('What needs you', 'Every agent’s ask, in one stack.')

# (take, start, end, caption, colour, bars): start and end in cfr-<take>.mov, make_agents' cut points.
# Taken again 2026-11-22 with the Hermes server named "Hermes" (it had come out "Home" beside Claude
# Code and Codex): each cut moved to the same moment by the test's marks (the 11-15 take is kept in
# tmp/take-c1-coders-1115).
SHOTS = [
    (T, 28.1, 36.5, ALL, PURPLE, 2),
    (T, 69.4, 77.2, CLAUDE, ORANGE, 2),
    (T, 77.2, 87.0, ALLOW, ORANGE, 2),
    (T, 166.7, 173.3, NEEDS, CORAL, 2),
]
TITLE_TAKE = (T, 25.8, 29.0)   # the chat list, before the server menu opens
END_TAKE = (T, 173.2)          # the stack, held (the app is gone at 173.6)
if IPAD:
    exec(open(os.path.join(V, 'v27_ipad_cuts.py')).read())   # SHOTS, TITLE_TAKE, END_TAKE for ipad-c1-coders

TITLE_BARS, END_BARS = 2, 2
LANDS_AT = [BAR * (TITLE_BARS + sum(s[5] for s in SHOTS[:i])) for i in range(len(SHOTS))]
END_AT = BAR * (TITLE_BARS + sum(s[5] for s in SHOTS)) - SLIDE
TOTAL = END_AT + SLIDE + BAR * END_BARS - 0.6
P = 'v27-ipad' if IPAD else 'v27'
OUT = f'redde-27-app-preview-{"ipad" if IPAD else "iphone"}.mp4'
END_LINES = ['Hermes bots, Claude Code and Codex.', 'Approve from your phone.', 'Every ask in one stack.']
SMALL_PRINT = 'Claude Code and Codex replies scripted for this video.'
md.P, md.TOTAL = P, TOTAL             # the soundtrack reads these from its own module


def title(t):
    """Over the chat list: "Every AI agent, / one app.", a line a beat."""
    f1, f2 = mp.font(round(92 * S), 'Bold'), mp.font(round(118 * S), 'Bold')
    y = H - round(740 * S) if IPAD else H - 700
    return sc.words_over(W, H, t, [('Every', f1, WHITE, y), ('AI agent,', f1, WHITE, y + round(120 * S)),
                                   ('one app.', f2, YELLOW, y + round(240 * S))],
                         start=BEAT, beat=BEAT, shown=0.15, depth=round(1000 * S))


def ending(t):
    """Over the stack, held: the name and what it brings, a line a beat, and the small print."""
    y, k, depth = (H - 470, 1.05, 820) if IPAD else (H - 840, 1.0, 1140)
    lines = [('Redde', mp.font(round(120 * k), 'Bold'), WHITE, y)]
    lines += [(line, mp.font(round(44 * k), 'Semibold'), YELLOW if n == len(END_LINES) - 1 else MIST, y + round((170 + n * 66) * k))
              for n, line in enumerate(END_LINES)]
    lines.append((SMALL_PRINT, mp.font(round(28 * k), 'Regular'), MIST, y + round((170 + len(END_LINES) * 66 + 40) * k)))
    return sc.words_over(W, H, t, lines, start=SLIDE + 0.25, beat=BEAT, shown=SLIDE, depth=depth, solid=0.88)


def main():
    take, a, b = TITLE_TAKE
    segs = [sc.page(f'{V}/{P}-title.mp4', f'{V}/cfr-{take}.mov', a, b, BAR * TITLE_BARS, title, W, H, f'{P}-title')]
    for i, (take, a, b, words, colour, bars) in enumerate(SHOTS):
        png = f'{V}/{P}-band{i}.png'
        sc.band(png, words, colour, W, H, scale=S)
        segs.append(sc.shot(f'{V}/{P}-seg{i}.mp4', f'{V}/cfr-{take}.mov', a, b, BAR * bars + SLIDE, png, W, H))
    take, a = END_TAKE
    segs.append(sc.page(f'{V}/{P}-end.mp4', f'{V}/cfr-{take}.mov', a, a + 0.05, TOTAL - END_AT, ending, W, H, f'{P}-end'))
    lands_at = LANDS_AT + [END_AT + SLIDE]
    kinds = ['fade'] + ['slideleft'] * (len(SHOTS) - 1) + ['fade']
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
