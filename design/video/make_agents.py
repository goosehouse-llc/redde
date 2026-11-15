#!/usr/bin/python3
"""Agents, for Reddit (2026-11-15, Redde 2.6), the second cut: one small job done by Hermes bots and
coding agents side by side, slowly enough to follow (their word on the first cut, now
redde-agents-reddit-v1.mp4 by make_agents_v1.py: "it was really hard to follow what was being done").
Framed, as the earlier Reddit cuts are (make_day.py's shots: a shot three or four 2.5 s bars of the
deep song, landing on the downbeat, the footage held still in the phone's frame over the drifting
ground; one caption a shot, naming what is done; what the person types in “quotes” and SF's medium
italic). A ring shows each touch (the app's `-echo.showTouches`).

  make_agents.py          the cut (redde-agents-reddit.mp4, 886×1920, here in design/video)
  make_agents.py small    and the copy for posting, under 5 MB (redde-agents-reddit-small.mp4, 664×1440)
  make_agents.py pages    the title and closing pages only, as stills (agents-page-*.png)

The story, all from one take (cfr-c1-coders.mov, PromoVideoUITests.testAgentsCoders): the server menu
with the Hermes server and Claude Code and Codex; Sol asked what's left before the release; New Chat
held for a chat with Claude Code, which fixes the login bug, asks before it runs the tests (Allow
Once) and shows its change; New Chat held for Codex, which reviews the change and asks to run a test
(left waiting); back to Home and Quill, who writes the release notes; the drawer's stack, Codex's ask
on top of the bots'. Claude Code and Codex are scripted stand-ins (`-echo.demoCoders`), as the
closing page's small print says.
"""
import math, os, shutil, sys
from PIL import Image, ImageDraw

SMALL = 'small' in sys.argv[1:]
PAGES_ONLY = 'pages' in sys.argv[1:]
sys.argv = sys.argv[:1]          # the modules below read their modes from the arguments
import make_preview as mp
import make_cool as mc
import make_next as mn
import make_day as md
import store_cut as sc
import fun_music

V, W, H, FPS = mp.V, mp.W, mp.H, mp.FPS
BAR, BEAT, SLIDE = md.BAR, md.BEAT, md.SLIDE
WHITE, MIST, INK = mc.WHITE, mc.MIST, mc.INK
PURPLE, BLUE, GREEN, ORANGE = mc.PURPLE, mc.BLUE, mc.GREEN, mc.ORANGE
TEAL, PERIWINKLE, YELLOW, CORAL = mc.TEAL, mc.PERIWINKLE, mc.YELLOW, mc.CORAL

# The Hermes team on the pages: the demo bots' own faces (PromoFacesTests' face-bot-*).
TEAM = ['bot-scout', 'bot-writer', 'bot-fixit']
# And the coding agents, as a terminal tile each (the app marks them with a terminal, not a face).
CREW = ['bot-scout', 'bot-writer', 'term', 'term']
ENDING_CREW = TEAM + ['term', 'term']

_tiles = {}
def member(name, size):
    """A bot's face, or a coding agent's terminal tile."""
    if name != 'term': return mp.face(name, size)
    if size not in _tiles:
        from PIL import ImageFont
        im = Image.new('RGBA', (size, size), (0, 0, 0, 0)); d = ImageDraw.Draw(im)
        d.rounded_rectangle((6, 6, size - 7, size - 7), size // 4, fill=(32, 38, 48, 255), outline=(120, 132, 150, 255), width=3)
        f = ImageFont.truetype('/System/Library/Fonts/SFNSMono.ttf', size // 3)
        d.text((size / 2, size / 2), '>_', font=f, fill=(120, 230, 150, 255), anchor='mm')
        _tiles[size] = im
    return _tiles[size]

# Captions: (big words, line) or (big words, line, what the person types: drawn in “quotes” and
# italics in the line's place).
ALL = ('All your agents', 'Tap the server menu: Hermes, and more.')
ASK = ('Ask a Hermes bot', 'Sol', 'What’s left before the release?')
TO_CLAUDE = ('Switch to Claude Code', 'Hold New Chat, then pick the agent.')
CLAUDE = ('Claude Code gets to work', '', 'Fix the login bug')
ALLOW = ('Let it run the tests', 'It asks first. Tap Allow Once.')
CHANGE = ('See the change', 'Open the step, then View Changes.')
TO_CODEX = ('Switch to Codex', 'Hold New Chat again, pick Codex.')
CODEX = ('Codex reviews it', '', 'Review Claude Code’s change')
BACK = ('Back to your Hermes bots', 'Pick Home, then tap Quill.')
NOTES = ('Quill writes it up', '', 'Write the release notes from today’s changes')
NEEDS = ('What needs you', 'Codex’s ask and the bots’, in one stack.')

# (kind, take, start, end, caption, colour, transition in, voices, bars, extra), as make_day.py's:
# start and end are seconds in cfr-<take>.mov, set from the take's frames. `fix` leaves out still
# stretches (the seconds it drops in `dropped`, so the footage keeps its pace).
T = 'c1-coders'
SHOTS = [
    ('take', T, 26.0, 34.4, ALL, PURPLE, 'slideleft', [], 3, {}),
    ('take', T, 45.0, 55.2, ASK, BLUE, 'slideleft', [], 3, {}),
    ('take', T, 55.4, 64.6, TO_CLAUDE, ORANGE, 'slideleft', [], 3, {}),
    ('take', T, 67.0, 75.0, CLAUDE, ORANGE, 'slideleft', [], 3, {}),
    ('take', T, 75.0, 84.6, ALLOW, ORANGE, 'slideleft', [], 3, {}),
    ('take', T, 85.8, 97.9, CHANGE, ORANGE, 'slideleft', [], 4,
     {'fix': "select='not(between(t,1.6,2.9))',setpts=N/30/TB", 'dropped': 1.3}),
    ('take', T, 101.3, 110.6, TO_CODEX, GREEN, 'slideleft', [], 3, {}),
    ('take', T, 114.4, 124.6, CODEX, GREEN, 'slideleft', [], 3, {}),
    ('take', T, 124.7, 139.6, BACK, TEAL, 'slideleft', [], 3,
     {'fix': "select='not(between(t,1.6,3.8)+between(t,10.2,13.0))',setpts=N/30/TB", 'dropped': 5.0}),
    ('take', T, 146.2, 156.0, NOTES, TEAL, 'slideleft', [], 3, {}),
    ('take', T, 159.6, 168.2, NEEDS, CORAL, 'slideleft', [], 3, {}),
]

TITLE_BARS, END_BARS = 2, 2
P, OUT = 'agents', 'redde-agents-reddit.mp4'
LANDS_AT = [BAR * (TITLE_BARS + sum(s[8] for s in SHOTS[:i])) for i in range(len(SHOTS))]
END_AT = BAR * (TITLE_BARS + sum(s[8] for s in SHOTS)) - SLIDE
LAND = BAR + SLIDE                       # where, in the closing page, the last chord falls
TOTAL = END_AT + SLIDE + BAR * END_BARS - 0.6
HELLO_AT = 0.72                          # "Hi! I'm Redde. Meet the team!", in the title
BYE_AT = LAND + 0.3                      # "Go team!", in the closing page
END_LINES = ['Hermes bots, Claude Code and Codex.', 'Switch with a hold.', 'Every ask in one stack.']
SMALL_PRINT = 'Claude Code and Codex replies scripted for this video.'

# make_day.py's shots and pages read these from their own module.
md.SHOTS, md.LANDS_AT, md.P, md.TITLE_BARS = SHOTS, LANDS_AT, P, TITLE_BARS
md.END_LINES, md.END_AT, md.TOTAL = END_LINES, END_AT, TOTAL


# --- Redde's face as it talks.

_env = {}
def mouth(line, start, t):
    if line not in _env: _env[line] = mn.envelope(f'{V}/voice-agents-{line}.wav')
    i = int((t - start) * FPS)
    if not 0 <= i < len(_env[line]): return 0
    level = max(_env[line][max(0, i - 1):i + 1])
    return 0 if level < 0.12 else 1 if level < 0.35 else 2 if level < 0.62 else 3

def face(t, line, start, blink_at=()):
    k = mouth(line, start, t)
    if not k and any(0 <= t - b < 0.12 for b in blink_at): return 'redde-blink'
    return f'redde-talk-{k}'

def body(im, cx, cy, size, name, sway=0.0):
    pic = mn.pic(name, size).rotate(sway, Image.BICUBIC, expand=True)
    im.alpha_composite(pic, (int(cx - pic.width / 2), int(cy - pic.height / 2)))


# --- The pages.

def team_around(im, t, cx, cy, start, radius=260):
    """The team bursting out from behind Redde, from `start`, and bobbing."""
    burst = (t - start) / 0.5
    if burst <= 0: return
    u = mp.ease(burst)
    for j, name in enumerate(CREW):
        angle = math.radians((200, 160, 20, -20)[j])   # two each side, clear of the bubble above
        r = radius * u
        bob = 6 * math.sin(2 * math.pi * 0.7 * t - j * 0.9)
        pic = member(name, 132).copy(); pic.putalpha(pic.getchannel('A').point(lambda v: int(v * min(1, burst * 2))))
        im.alpha_composite(pic, (int(cx + r * math.cos(angle) * 1.2 - 66), int(cy + r * math.sin(angle) * 0.72 - 66 - 50 + bob)))

def title(t):
    """Redde falls in and lands and says hello in a bubble; the team bursts out around it; on the
    second bar "Your Hermes bots, / Claude Code and Codex. / One app." a line a beat."""
    im = mc.glows(t).convert('RGBA')
    size, cx, cy = 330, W // 2, 700
    fall = -(cy + size) * math.exp(-7 * t) * math.cos(11 * t) if t < 1.2 else 0
    sway = 4 * math.exp(-3 * t) * math.sin(13 * t) + 2.5 * math.sin(2 * math.pi * 0.7 * t)
    team_around(im, t, cx, cy, HELLO_AT + 1.35)
    name = face(t, 'hello', HELLO_AT, blink_at=(3.3, 4.6))
    if t >= BAR - 0.1 and name == 'redde-talk-0': name = 'redde-look'
    body(im, cx, cy + fall, size, name, sway)
    mn.bubble(im, t, HELLO_AT, BAR - 0.15, (cx - 40, cy - size // 2 + 4 + fall), 'Hi! I’m Redde.', 'Meet the team!')
    hi = BAR * (TITLE_BARS - 1)
    for n, word in enumerate(['Your Hermes bots,', 'Claude Code and Codex.', 'One app.']):
        u = mp.ease((t - hi - (n + 1) * BEAT) / 0.18)
        if u <= 0: continue
        layer = Image.new('RGBA', (W, H), (0, 0, 0, 0)); ld = ImageDraw.Draw(layer)
        f = mp.font(112 if n == 2 else 64, 'Bold')
        w = ld.textlength(word, font=f)
        ld.text(((W - w) / 2, 1010 + n * 96 + (24 if n == 2 else 0) + 30 * (1 - u)), word, font=f, fill=(YELLOW if n == 2 else WHITE) + (255,))
        layer.putalpha(layer.getchannel('A').point(lambda v: int(v * u)))
        im = Image.alpha_composite(im, layer)
    return im.convert('RGB')


def ending(t):
    """The icon and the name; on the last chord Redde drops onto the icon and takes its place and
    says "Go team!"; what the agents do, a line a beat; the team along the bottom."""
    im = mc.glows(END_AT + t).convert('RGBA')
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
        cx, cy = ix + size / 2, iy + size / 2 + fall
        name = face(t, 'bye', BYE_AT)
        if name == 'redde-talk-0' and t > BYE_AT + 1.0: name = 'redde-look'
        body(im, cx, cy, 280, name, sway)
        mn.bubble(im, t, BYE_AT, TOTAL - END_AT, (cx - 20, cy - 130), 'Go team!', None)
    d = ImageDraw.Draw(im)
    mp.centered(d, 720, 'Redde', mp.font(128, 'Bold'), WHITE)
    for n, line in enumerate(END_LINES):
        u = mp.ease((t - 0.25 - n * BEAT) / 0.25)
        if u <= 0: continue
        layer = Image.new('RGBA', (W, H), (0, 0, 0, 0)); ld = ImageDraw.Draw(layer)
        mp.centered(ld, 900 + n * 70, line, mp.font(44, 'Semibold'), (YELLOW if n == len(END_LINES) - 1 else MIST) + (255,))
        layer.putalpha(layer.getchannel('A').point(lambda v: int(v * u)))
        im = Image.alpha_composite(im, layer)
    for j, name in enumerate(ENDING_CREW):
        u = mp.ease((t - 0.6 - j * 0.07) / 0.3)
        if u <= 0: continue
        pic = member(name, 120).copy(); pic.putalpha(pic.getchannel('A').point(lambda v: int(v * u)))
        x = (W - (len(ENDING_CREW) - 1) * 140) / 2 + j * 140 - 60
        im.alpha_composite(pic, (int(x), int(1260 + 20 * (1 - u) + 6 * math.sin(2 * math.pi * 0.7 * t - j * 0.8))))
    u = mp.ease((t - 1.2) / 0.4)
    if u > 0:
        layer = Image.new('RGBA', (W, H), (0, 0, 0, 0)); ld = ImageDraw.Draw(layer)
        mp.centered(ld, H - 150, SMALL_PRINT, mp.font(28, 'Medium'), MIST + (int(200 * u),))
        im = Image.alpha_composite(im, layer)
    return im.convert('RGB')


# --- The cut.

def main():
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
    segs = [md.page('title', title, BAR * TITLE_BARS)]
    for i in range(len(SHOTS)):
        segs.append(md.shot(i))
    segs.append(md.page('end', ending, TOTAL - END_AT))
    lands_at = LANDS_AT + [END_AT + SLIDE]
    kinds = [s[6] for s in SHOTS] + ['slideup']
    voices = [(HELLO_AT, f'{V}/voice-agents-hello.wav'), (END_AT + BYE_AT, f'{V}/voice-agents-bye.wav')]
    for (kind, take, a, b, *_, lines, bars, extra), at in zip(SHOTS, LANDS_AT):
        speed = (b - a) / (BAR * bars + SLIDE)
        for line, said in lines:
            voices.append((at - SLIDE + (said - a) / speed, f'{V}/voice-{line}.wav'))
    swishes = [at - SLIDE - 0.05 for at, kind in zip(lands_at, kinds) if kind != 'fade']
    hi = BAR * (TITLE_BARS - 1)
    lands = [(hi + n * BEAT + 0.02, note) for n, note in ((1, 64), (2, 67), (3, 72))]
    cues = {'groove': BAR * TITLE_BARS, 'quiet': END_AT, 'back': END_AT - 0.3, 'outro': END_AT + SLIDE}
    sound = md.soundtrack(voices, [], cues, lands, boings=[0.14, END_AT + LAND], pops=[HELLO_AT - 0.05, END_AT + BYE_AT - 0.05],
                          swishes=swishes)
    out = f'{V}/{OUT}'
    sc.assemble(out, segs, kinds, lands_at, sound)
    print(f'{out}  {TOTAL:.2f}s')


def small():
    """Two passes at a set rate, so it lands under 5 MB (as the day cut's small copy)."""
    src, out = f'{V}/{OUT}', f'{V}/{OUT.replace(".mp4", "-small.mp4")}'
    rate = int((4.6 * 8 * 1024 * 1024 / TOTAL - 64_000) / 1000)   # kbit/s for the picture, with 64k of sound
    log = f'{V}/{P}-small-pass'
    common = ['-vf', 'scale=664:1440', '-c:v', 'libx264', '-b:v', f'{rate}k', '-passlogfile', log]
    mp.run(['ffmpeg', '-v', 'error', '-y', '-i', src, *common, '-pass', '1', '-an', '-f', 'mp4', '/dev/null'])
    mp.run(['ffmpeg', '-v', 'error', '-y', '-i', src, *common, '-pass', '2', '-c:a', 'aac', '-b:a', '64k',
            '-movflags', '+faststart', out])
    for f in os.listdir(V):
        if f.startswith(f'{P}-small-pass'): os.remove(os.path.join(V, f))
    print(f'{out}  {os.path.getsize(out) / 1024 / 1024:.2f} MB at {rate}k')


if __name__ == '__main__':
    if PAGES_ONLY:
        for j, t in enumerate((0.3, 1.0, 1.9, 2.4, 3.4, 4.8)): title(t).save(f'{V}/{P}-page-title{j}.png')
        for j, t in enumerate((LAND - 0.2, LAND + 0.6, BYE_AT + 0.5, TOTAL - END_AT - 0.1)): ending(t).save(f'{V}/{P}-page-end{j}.png')
        print('pages written')
    elif SMALL:
        small()
    else:
        main()
