#!/usr/bin/python3
"""App Store cuts as App Review wants them (2026-10-29, Guideline 2.3.4 on 2.2's preview: "The app
preview includes framing around the video screen capture of the app … Revise the app preview to
only use video screen captures of the app that may include narration and video or textual
overlays"). The standing rule for every App Store cut (README "App Store cuts"): the screen capture
fills the whole frame, edge to edge, at the device's own aspect; no ground, device frame, rounded
inset or drawn pages; the captions, the person's words and the titles are text laid over the
footage (a dark scrim fading up from the foot, or the top, of the screen, the words on it), and
the title and the closing are app footage too. Narration, voices and music are fine.

The pieces, used by make_day.py, make_next.py and make_preview.py (`fullframe`):
  band(...)        a caption as an overlay: a scrim and the words, the size of the frame
  shot(...)        a take's span, sped to fit, filling the frame, its band sliding in
  page(...)        a take's span with frames drawn over it (titles, the closing)
  assemble(...)    the segments joined with the cut's transitions, and the sound
"""
import math, os, shutil
from PIL import Image, ImageDraw

import make_preview as mp
import make_cool as mc

V, FPS = mp.V, mp.FPS
INK, WHITE, MIST = mc.INK, mc.WHITE, mc.MIST


def fill(w, h):
    """A take scaled to cover a w×h frame and cropped to it (a 1320×2868 capture comes out
    886×1925, less 2 or 3 rows top and bottom)."""
    return f'scale={w}:{h}:force_original_aspect_ratio=increase:flags=lanczos,crop={w}:{h},setsar=1'


def scrim(w, h, at='bottom', depth=440, solid=0.86):
    """A dark scrim fading in from nothing `depth` px from the foot (or the top) to `solid` over
    the last 60% of it: the ground the overlay's words sit on, with the app showing through."""
    im = Image.new('RGBA', (w, h), (0, 0, 0, 0)); d = ImageDraw.Draw(im)
    ramp = int(depth * 0.4)
    for k in range(depth):
        a = solid * mp.ease(min(1, k / ramp)) if k < ramp else solid
        y = h - depth + k if at == 'bottom' else depth - 1 - k
        d.line((0, y, w, y), fill=INK + (int(255 * a),))
    return im


def clock_icon(d, x, y, colour, evening):
    """A little sun (rays and all) or a crescent moon, its middle at (x, y)."""
    if evening:
        d.ellipse((x - 13, y - 13, x + 13, y + 13), fill=colour + (255,))
        d.ellipse((x - 5, y - 19, x + 19, y + 5), fill=(0, 0, 0, 0))
    else:
        d.ellipse((x - 7, y - 7, x + 7, y + 7), fill=colour + (255,))
        for k in range(8):
            a = k * math.pi / 4
            d.line((x + 11 * math.cos(a), y + 11 * math.sin(a), x + 16 * math.cos(a), y + 16 * math.sin(a)), fill=colour + (255,), width=3)


def band(path, words, colour, w, h, clock=None, at='bottom', scale=1.0):
    """A caption as an overlay on the footage: the scrim, a bar of its colour (the time of day by
    it, a sun or a moon, when there is one), the big words in SF Bold and the line under them in
    Medium; or, where the person talks, their words in “quotes” and SF's medium italic in the
    line's place (make_cool.caption's rule)."""
    s = scale
    im = scrim(w, h, at, depth=round(440 * s))
    layer = Image.new('RGBA', (w, h), (0, 0, 0, 0)); d = ImageDraw.Draw(layer)
    size = round(88 * s)
    while d.textlength(words[0], font=mp.font(size, 'Bold')) > w - 112 * s: size -= 4
    quote = mc.said(words)
    lines, f = [], None
    if quote:
        f = mc.italic(round(38 * s))
        lines = mc.wrapped(d, f'“{quote}”', f, w - 116 * s)
        if len(lines) > 1:
            f = mc.italic(round(34 * s))
            lines = mc.wrapped(d, f'“{quote}”', f, w - 116 * s)[:2]
    below = round(size * 1.24) + round(6 * s) + (round(42 * s) * len(lines) if quote else round(44 * s))
    top = (h - round(118 * s) - below - round(40 * s)) if at == 'bottom' else round(150 * s)
    x = round(56 * s)
    d.rounded_rectangle((x + 2, top, x + 2 + round(110 * s), top + round(13 * s)), round(6 * s), fill=colour + (255,))
    if clock:
        evening = 'PM' in clock and int(clock.split(':')[0]) % 12 >= 6
        cx = x + round(136 * s)
        clock_icon(d, cx, top + round(7 * s), colour, evening)
        d.text((cx + round(24 * s), top + round(7 * s)), clock, font=mp.font(round(32 * s), 'Semibold'), fill=colour + (255,), anchor='lm')
    y = top + round(30 * s)
    d.text((x - 3, y), words[0], font=mp.font(size, 'Bold'), fill=WHITE + (255,))
    y += round(size * 1.24) + round(6 * s)
    if quote:
        for n, line in enumerate(lines):
            d.text((x + 2, y - 2 + n * round(42 * s)), line, font=f, fill=WHITE + (255,))
    else:
        d.text((x + 4, y), words[1], font=mp.font(round(34 * s), 'Medium'), fill=MIST + (255,))
    im.alpha_composite(layer)
    im.save(path)


def shot(out, source, a, b, length, band_png, w, h, slide_in=True, fix=None):
    """A take's span from `a` to `b`, sped to fill `length` (its last frame held, should the take
    end first), covering the frame, its band laid over it: fading and sliding in as the shot lands (after the slide that brings it), or simply
    there when the shot before had the same big words."""
    speed = (b - a) / length
    slide = mc.SLIDE
    if slide_in:
        place = (f'[1:v]format=rgba,fade=t=in:st={slide}:d=0.2:alpha=1[c];'
                 f"[f][c]overlay=x='-110*pow(1-min(1,max(0,(t-{slide})/0.35)),3)':y=0:eval=frame")
    else:
        place = '[f][1:v]overlay=0:0'
    graph = (f'[0:v]{fix + "," if fix else ""}trim=duration={b - a:.3f},setpts=(PTS-STARTPTS)/{speed},fps={FPS},{fill(w, h)},tpad=stop_mode=clone:stop_duration={length:.3f},format=rgba[f];'
             f'{place},format=yuv420p,fps={FPS}')
    mp.run(['ffmpeg', '-v', 'error', '-y', '-ss', str(a), '-i', source,
            '-loop', '1', '-i', band_png, '-filter_complex', graph, '-t', f'{length:.3f}',
            '-c:v', 'libx264', '-crf', '14', '-preset', 'medium', out])
    return out, length


def page(out, source, a, b, length, draw, w, h, name):
    """A take's span with frames drawn over it, `draw(t)` an RGBA w×h picture (or None for
    nothing at that moment): the titles and the closing, over the app."""
    frames = f'{V}/frames-{name}'
    shutil.rmtree(frames, ignore_errors=True); os.makedirs(frames)
    blank = None
    for n in range(round(length * FPS)):
        im = draw(n / FPS)
        if im is None:
            if blank is None:
                blank = f'{frames}/blank.png'
                Image.new('RGBA', (w, h), (0, 0, 0, 0)).save(blank)
            os.link(blank, f'{frames}/{n:04d}.png')
        else:
            im.save(f'{frames}/{n:04d}.png')
    speed = (b - a) / length
    graph = (f'[0:v]trim=duration={b - a:.3f},setpts=(PTS-STARTPTS)/{speed},fps={FPS},{fill(w, h)},tpad=stop_mode=clone:stop_duration={length:.3f},format=rgba[f];'
             f'[1:v]format=rgba[o];[f][o]overlay=0:0:eof_action=pass,format=yuv420p,fps={FPS}')
    mp.run(['ffmpeg', '-v', 'error', '-y', '-ss', str(a), '-i', source,
            '-framerate', str(FPS), '-i', f'{frames}/%04d.png', '-filter_complex', graph, '-t', f'{length:.3f}',
            '-c:v', 'libx264', '-crf', '14', '-preset', 'medium', out])
    shutil.rmtree(frames)
    return out, length


def words_over(w, h, t, lines, start, beat, shown=None, depth=1000, solid=0.8):
    """Words coming in a beat apiece over a scrim from the foot: `lines` of (text, font, colour,
    y), centred, the first at `start`; the scrim fading in over 0.3 s from `shown` (by default
    0.3 s before the first word). None before anything shows."""
    shown = start - 0.3 if shown is None else shown
    a = mp.ease((t - shown) / 0.3)
    if a <= 0: return None
    im = scrim(w, h, 'bottom', depth=depth, solid=solid)
    if a < 1: im.putalpha(im.getchannel('A').point(lambda v: int(v * a)))
    for n, (text, f, colour, y) in enumerate(lines):
        u = mp.ease((t - start - n * beat) / 0.2)
        if u <= 0: continue
        layer = Image.new('RGBA', (w, h), (0, 0, 0, 0)); ld = ImageDraw.Draw(layer)
        tw = ld.textlength(text, font=f)
        ld.text(((w - tw) / 2, y + 24 * (1 - u)), text, font=f, fill=colour + (255,))
        layer.putalpha(layer.getchannel('A').point(lambda v: int(v * u)))
        im.alpha_composite(layer)
    return im


def fade(im, k):
    """`im` (or None) at `k` of its strength."""
    if im is None or k >= 1: return im
    if k <= 0: return None
    im.putalpha(im.getchannel('A').point(lambda v: int(v * k)))
    return im


def assemble(out, segs, kinds, lands_at, sound):
    """The segments joined, each next one coming in over the slide before where it lands."""
    inputs, chain, last = [], [], '[0:v]'
    for path, _ in segs: inputs += ['-i', path]
    for i in range(1, len(segs)):
        chain.append(f'{last}[{i}:v]xfade=transition={kinds[i - 1]}:duration={mc.SLIDE}:offset={lands_at[i - 1] - mc.SLIDE:.3f}[x{i}]')
        last = f'[x{i}]'
    mp.run(['ffmpeg', '-v', 'error', '-y', *inputs, '-i', sound,
            '-filter_complex', ';'.join(chain), '-map', last, '-map', f'{len(segs)}:a',
            '-c:v', 'libx264', '-profile:v', 'high', '-level', '4.0', '-pix_fmt', 'yuv420p', '-r', str(FPS),
            '-b:v', '10M', '-maxrate', '11M', '-bufsize', '20M', '-g', '30',
            '-c:a', 'aac', '-b:a', '256k', '-ar', '44100', '-ac', '2', '-shortest', '-movflags', '+faststart', out])
