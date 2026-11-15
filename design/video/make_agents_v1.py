#!/usr/bin/python3
"""Agents, for Reddit, the first cut (2026-11-14, Redde 2.6; kept as redde-agents-reddit-v1.mp4): everyday Redde with the stress on the agents, switching
between them and using several together. Framed, as the earlier Reddit cuts are (make_day.py's shots:
a shot a 2.5 s bar of the deep song or two, landing on the downbeat, the footage held still in the
phone's frame over the drifting ground, big captions in SF Bold and Medium, what the person types in
“quotes” and SF's medium italic).

  make_agents.py          the cut (redde-agents-reddit.mp4, 886×1920, here in design/video)
  make_agents.py small    and the copy for posting, under 5 MB (redde-agents-reddit-small.mp4, 664×1440)
  make_agents.py pages    the title and closing pages only, as stills (agents-page-*.png)

The story: Redde drops in and says "Hi! I'm Redde. Meet the team!", the team bursting out around it,
then "All your / agents. / One app."; the drawer with the team (Sol, Quill, Scout, Fix-it) and what
each is doing; Quill, Scout and Fix-it opened from the Team row in turn; Sol asked for a hike, its
answer streaming; Scout asked with an @, answering in Sol's chat; the invite handed to Quill, its
progress under Sol's reply, and Quill's chat with the invite; the group chat; its voice screen, Sol,
Scout and Quill answering one question in turn, heard; what waits on you from several of them, on
the drawer; the server menu to a coding agent (Redde's built-in demo agent, as Claude Code or Codex
are through the bridge), "Fix the notes" with its approval allowed, and back to the team. The closing
page: Redde drops onto the icon on the last chord, says "Go team!", the team along the bottom.

Takes (README "Agents, for Reddit (2.6)"): cfr-g1-team … cfr-g6-coding, from take_agents.sh. The
lines: agents_voices.py (and bot_voices.py's round). The faces: faces/ (PromoFacesTests).
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

# The team on the pages: the demo bots' own faces (PromoFacesTests' face-bot-*), and Coder's for
# the coding agents.
TEAM = ['bot-scout', 'bot-writer', 'bot-fixit', 'coder']

# Captions: (big words, line) or (big words, line, what the person types: drawn in “quotes” and
# italics in the line's place).
DRAWER = ('Meet the team', 'Every agent on the drawer, and what it’s up to.')
SWITCH = ('Switch in a tap', 'Each agent has its own face and chat.')
ASK = ('Just ask', 'Sol’s answer streams in as it’s written.', 'Find us a hike for Saturday morning')
TAG = ('@ another agent', 'Scout answers right here, under its face.', '@scout is the trail open?')
HAND = ('Hand it off', 'Sol passes the invite to Quill.', 'Ask Quill to write the invite')
HANDED = ('Hand it off', 'Quill wrote it, in its own chat.')
GROUP = ('Group chats', 'The whole team in one room.')
TALK = ('They talk', 'One question, three voices.')
WAITS = ('What needs you', 'Every agent’s asks, in one stack.')
CODING = ('Coding agents too', 'Claude Code, Codex and more. Or try the demo.')
FIX = ('Coding agents too', 'Diffs, approvals, done.', 'Fix the notes')
BACK = ('Back to the team', 'One menu between them.')

# (kind, take, start, end, caption, colour, transition in, voices, bars, extra), as make_day.py's:
# start and end are seconds in cfr-<take>.mov, set from the takes' frames. A voice is (line, when
# it starts in the take): voice-<line>.wav laid where the footage says it.
SHOTS = [
    ('take', 'g1-team', 23.0, 26.2, DRAWER, PURPLE, 'slideleft', [], 1, {}),
    ('take', 'g1-team', 26.3, 29.9, SWITCH, BLUE, 'slideleft', [], 1, {}),     # to Quill
    ('take', 'g1-team', 33.6, 37.2, SWITCH, BLUE, 'fade', [], 1, {}),          # back to the drawer, to Scout
    ('take', 'g1-team', 41.3, 44.9, SWITCH, BLUE, 'fade', [], 1, {}),          # and to Fix-it
    ('take', 'g2-chat', 28.2, 36.0, ASK, GREEN, 'slideleft', [], 2, {}),
    ('take', 'g2-chat', 37.3, 48.4, TAG, BLUE, 'slideleft', [], 2,
     {'fix': "select='not(between(t,1.7,3.1))',setpts=N/30/TB"}),               # (the caret moved to the end, left out)
    ('take', 'g2-chat', 49.9, 61.0, HAND, ORANGE, 'slideleft', [], 3, {}),
    ('take', 'g2-chat', 62.0, 65.5, HANDED, ORANGE, 'fade', [], 1, {}),
    ('take', 'g3-group', 30.5, 35.3, GROUP, ORANGE, 'slideleft', [], 1, {}),
    ('take', 'g4-round', 27.9, 33.15, TALK, TEAL, 'slideup', [('redde', 28.2)], 2, {}),
    ('take', 'g4-round', 34.9, 40.15, TALK, TEAL, 'fade', [('scout', 35.2)], 2, {}),
    ('take', 'g4-round', 41.3, 46.55, TALK, TEAL, 'fade', [('quill', 41.6)], 2, {}),
    ('take', 'g5-waits', 26.5, 31.0, WAITS, CORAL, 'slideleft', [], 1, {}),
    ('take', 'g6-coding', 26.5, 34.6, CODING, YELLOW, 'slideleft', [], 2, {}),
    ('take', 'g6-coding', 40.0, 50.5, FIX, YELLOW, 'fade', [], 3, {}),
    ('take', 'g6-coding', 58.6, 61.6, BACK, PURPLE, 'slideleft', [], 1, {}),
]

TITLE_BARS, END_BARS = 2, 2
P, OUT = 'agents', 'redde-agents-reddit-v1.mp4'   # (the first cut, 11-14; make_agents.py is the one after)
LANDS_AT = [BAR * (TITLE_BARS + sum(s[8] for s in SHOTS[:i])) for i in range(len(SHOTS))]
END_AT = BAR * (TITLE_BARS + sum(s[8] for s in SHOTS)) - SLIDE
LAND = BAR + SLIDE                       # where, in the closing page, the last chord falls
TOTAL = END_AT + SLIDE + BAR * END_BARS - 0.6
HELLO_AT = 0.72                          # "Hi! I'm Redde. Meet the team!", in the title
BYE_AT = LAND + 0.3                      # "Go team!", in the closing page
END_LINES = ['Agents with faces, voices and chats.', '@ them, hand off, talk as a group.',
             'Claude Code, Codex and more, too.']

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
    for j, name in enumerate(TEAM):
        angle = math.radians((200, 160, 20, -20)[j])   # two each side, clear of the bubble above
        r = radius * u
        bob = 6 * math.sin(2 * math.pi * 0.7 * t - j * 0.9)
        pic = mp.face(name, 132).copy(); pic.putalpha(pic.getchannel('A').point(lambda v: int(v * min(1, burst * 2))))
        im.alpha_composite(pic, (int(cx + r * math.cos(angle) * 1.2 - 66), int(cy + r * math.sin(angle) * 0.72 - 66 - 50 + bob)))

def title(t):
    """Redde falls in and lands and says hello in a bubble; the team bursts out around it; on the
    second bar "All your / agents. / One app." a word a beat."""
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
    for n, word in enumerate(['All your', 'agents.', 'One app.']):
        u = mp.ease((t - hi - (n + 1) * BEAT) / 0.18)
        if u <= 0: continue
        layer = Image.new('RGBA', (W, H), (0, 0, 0, 0)); ld = ImageDraw.Draw(layer)
        f = mp.font(118 if n == 2 else 92, 'Bold')
        w = ld.textlength(word, font=f)
        ld.text(((W - w) / 2, 1010 + n * 120 + 30 * (1 - u)), word, font=f, fill=(YELLOW if n == 2 else WHITE) + (255,))
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
    for j, name in enumerate(TEAM):
        u = mp.ease((t - 0.6 - j * 0.07) / 0.3)
        if u <= 0: continue
        pic = mp.face(name, 120).copy(); pic.putalpha(pic.getchannel('A').point(lambda v: int(v * u)))
        x = (W - 3 * 150) / 2 + j * 150 - 60
        im.alpha_composite(pic, (int(x), int(1260 + 20 * (1 - u) + 6 * math.sin(2 * math.pi * 0.7 * t - j * 0.8))))
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
    round_at = next(at for s, at in zip(SHOTS, LANDS_AT) if s[4] == TALK)
    round_end = max(at + len(fun_music.spoken(path)) / fun_music.RATE for at, path in voices[2:])
    cues = {'groove': BAR * TITLE_BARS, 'quiet': round_at, 'back': round_end - 0.35, 'outro': END_AT + SLIDE}
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
