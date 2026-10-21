#!/usr/bin/python3
"""A bright little loop for the fun Phone tools cut, made here so there is nothing to license:
marimba arpeggios over C, G, A minor and F, a bouncing bass, a soft kick, claps and a shaker, and a
"bloop" wherever a caption pops in. Plain Python, no packages.

`song='bots'` is the BOTS! cut's, a deep hip-hop groove (`render_deep`): boom-bap drums, a
round low bass, warm electric piano and a pad, the tune low on the keys, in a small room.
`song='chip'` is the same plan in chiptune (`render_chip`). Both are laid out
on the cut: a build over the title, a note as each letter lands and a boing as the Redde bot does,
the beat dropping on the first shot, the tune over the features, a light beat while the bots talk
(their lines, from bot_voices.py, laid in where they speak, the music dipping under them), back up
into the tune, and a closing phrase and last chord on the closing page.

  fun_music.py <seconds> <out.wav> [pop seconds...]
"""
import array, math, random, sys, wave

RATE = 44100
BPM = 112
BEAT = 60 / BPM
BAR = 4 * BEAT
# One chord a bar: its arpeggio notes (MIDI) and its bass note.
CHORDS = [([60, 64, 67, 72], 36), ([59, 62, 67, 71], 31), ([57, 60, 64, 69], 33), ([57, 60, 65, 69], 29)]
ARP = [0, 1, 2, 3, 2, 1, 2, 3]          # eighth notes through the chord
random.seed(7)


def hz(midi):
    return 440 * 2 ** ((midi - 69) / 12)


class Track:
    def __init__(self, seconds):
        self.n = int(seconds * RATE)
        self.s = array.array('f', bytes(4 * self.n))

    def add(self, at, length, voice):
        """Adds `voice(t)` for `length` seconds from `at`."""
        start = int(at * RATE)
        for i in range(max(0, start), min(self.n, start + int(length * RATE))):
            self.s[i] += voice((i - start) / RATE)


def marimba(f, loud):
    two = 2 * math.pi
    return lambda t: loud * (math.sin(two * f * t) * math.exp(-t / 0.32)
                             + 0.32 * math.sin(two * 3.93 * f * t) * math.exp(-t / 0.05)
                             + 0.12 * math.sin(two * 9.8 * f * t) * math.exp(-t / 0.012))


def bell(f, loud):
    two = 2 * math.pi
    return lambda t: loud * (math.sin(two * f * t) + 0.4 * math.sin(two * 5.4 * f * t) * math.exp(-t / 0.2)) * math.exp(-t / 0.7)


def bass(f, loud):
    two = 2 * math.pi
    return lambda t: loud * min(1, t / 0.006) * (math.sin(two * f * t) + 0.25 * math.sin(two * 2 * f * t)) * math.exp(-t / 0.28)


def kick(loud):
    # A falling sine: 110 Hz down to 48 over a tenth of a second.
    return lambda t: loud * math.sin(2 * math.pi * (48 * t + 62 * 0.035 * (1 - math.exp(-t / 0.035)))) * math.exp(-t / 0.13)


def noise(loud, decay, bright=0.0):
    last = [0.0]
    def voice(t):
        x = random.uniform(-1, 1)
        y = x - bright * last[0]     # a touch of high-pass
        last[0] = x
        return loud * y * math.exp(-t / decay)
    return voice


def bloop(loud):
    # Up from 420 Hz to about 1,000 in a tenth of a second, quickly gone.
    return lambda t: loud * math.sin(2 * math.pi * (420 * t + 600 * t * t / 0.2)) * math.exp(-t / 0.07)


def boing(loud):
    # A spring: 330 Hz wobbling nine times a second and settling, gone in half a second.
    phase = [0.0]
    def voice(t):
        phase[0] += 2 * math.pi * (330 + 140 * math.exp(-t / 0.12) * math.sin(2 * math.pi * 9 * t)) / RATE
        return loud * math.sin(phase[0]) * math.exp(-t / 0.16)
    return voice


# The BOTS! song: chiptune, laid out on the cut. 120 bpm, so a bar is two seconds and the bars can
# be counted from the first shot: the title's two bars build into it.
CHIP_BEAT = 0.5
CHIP_BAR = 4 * CHIP_BEAT
# C, A minor, F, G: (pad and arpeggio notes, bass root).
PROG = [([60, 64, 67], 48), ([57, 60, 64], 45), ([57, 60, 65], 41), ([55, 59, 62], 43)]
# The tune, two four-bar phrases, a bar to each chord: (beat, note, beats).
TUNE_A = [[(0, 76, .5), (.5, 79, .5), (1, 84, 1), (2, 83, .5), (2.5, 79, .5), (3, 76, 1)],
          [(0, 81, .5), (.5, 79, .5), (1, 76, 1), (2, 72, .5), (2.5, 76, .5), (3, 81, 1)],
          [(0, 77, .5), (.5, 81, .5), (1, 84, 1), (2, 81, .5), (2.5, 77, .5), (3, 81, 1)],
          [(0, 79, 1), (1, 81, .5), (1.5, 83, .5), (2, 86, 1.5)]]
TUNE_B = [[(0, 76, .5), (.5, 79, .5), (1, 84, 1), (2, 86, .5), (2.5, 84, .5), (3, 79, 1)],
          [(0, 81, .5), (.5, 84, .5), (1, 88, 1), (2, 86, .5), (2.5, 84, .5), (3, 81, 1)],
          [(0, 77, .5), (.5, 81, .5), (1, 84, .5), (1.5, 86, .5), (2, 84, .5), (2.5, 81, .5), (3, 77, 1)],
          [(0, 86, 1), (1, 83, .5), (1.5, 79, .5), (2, 83, 1), (3, 86, 1)]]
# The way back after the voices: the second phrase with its last bar climbing to the tonic.
TUNE_C = TUNE_B[:3] + [[(0, 79, .5), (.5, 83, .5), (1, 86, .5), (1.5, 89, .5), (2, 91, 2)]]
# "Level clear", over the closing page's last line: up the C chord in triplets, then high C.
JINGLE = [(0, 67, 1 / 3), (1 / 3, 72, 1 / 3), (2 / 3, 76, 1 / 3), (1, 79, .5), (1.5, 76, .5), (2, 84, 2)]


class Osc:
    """A phase that moves on as it is read, a sample at a time, so the pitch can bend."""
    def __init__(self):
        self.phase = 0.0

    def step(self, f):
        self.phase = (self.phase + f / RATE) % 1.0
        return self.phase


def shape(t, length, attack=0.004, decay=0.09, sustain=0.6, release=0.04):
    a = t / attack if t < attack else 1 - (1 - sustain) * min(1, (t - attack) / decay)
    return a * max(0.0, min(1.0, (length - t) / release))


def pulse(f, duty, loud, length, vibrato=0.0, sustain=0.6, attack=0.004, slide=0.0):
    """A square-ish wave, `duty` of each cycle up: 0.125 thin, 0.25 the classic lead, 0.5 hollow.
    `vibrato` in semitones, coming in after a moment; `slide` bends up into the note."""
    osc = Osc()
    def voice(t):
        bend = vibrato * math.sin(2 * math.pi * 5.5 * t) * min(1, max(0, (t - 0.14) / 0.2)) - slide * math.exp(-t / 0.025)
        return loud * (1 if osc.step(f * 2 ** (bend / 12)) < duty else -1) * shape(t, length, attack=attack, sustain=sustain)
    return voice


def triangle(f, loud, length):
    osc = Osc()
    return lambda t: loud * (4 * abs(osc.step(f) - 0.5) - 1) * shape(t, length, sustain=0.85, decay=0.2, release=0.02)


def chip_kick(loud):
    osc = Osc()
    return lambda t: loud * (4 * abs(osc.step(48 + 130 * math.exp(-t / 0.028)) - 0.5) - 1) * math.exp(-t / 0.1)


def chip_snare(loud):
    osc, hiss = Osc(), noise(1.0, 0.075, 0.5)
    return lambda t: loud * (0.8 * hiss(t) + 0.5 * (4 * abs(osc.step(185) - 0.5) - 1) * math.exp(-t / 0.03))


def crash(loud):
    return noise(loud, 0.55, 0.85)


def blip(loud):
    # Up an octave in six hundredths of a second: a caption landing.
    osc = Osc()
    return lambda t: loud * (1 if osc.step(760 * 2 ** min(1, t / 0.06)) < 0.25 else -1) * math.exp(-t / 0.08)


def chip_boing(loud):
    osc = Osc()
    return lambda t: loud * (1 if osc.step(392 * 2 ** (0.9 * math.exp(-t / 0.12) * math.sin(2 * math.pi * 10 * t))) < 0.5 else -1) * math.exp(-t / 0.15)


def power_up(loud, length):
    # A glide from low to high, getting louder: the machine coming on.
    osc = Osc()
    return lambda t: loud * min(1, t / length) * (1 if osc.step(140 * 2 ** (3.2 * t / length)) < 0.25 else -1) * shape(t, length, release=0.02)


def riser(loud, length):
    hiss = noise(1.0, 1e9, 0.85)
    return lambda t: loud * (t / length) ** 2 * hiss(t) * shape(t, length, attack=0.01, release=0.01)


def spoken(path):
    """A WAV of 16-bit mono speech as samples at RATE, from -1 to 1 (Kokoro's are 24 kHz)."""
    with wave.open(path) as w:
        rate, raw = w.getframerate(), array.array('h', w.readframes(w.getnframes()))
    step = rate / RATE
    return [raw[min(len(raw) - 1, int(i * step))] / 32768 * (1 - (i * step) % 1)
            + raw[min(len(raw) - 1, int(i * step) + 1)] / 32768 * ((i * step) % 1)
            for i in range(int(len(raw) / step))]


def lay_voices(track, voices):
    """The bots' lines laid in at their times (`spoken`), the music a third as loud while a bot
    speaks (a tenth of a second either side, eased), and each line as loud as the music's loudest."""
    if not voices: return
    s, music = track.s, max(1e-6, max(abs(v) for v in track.s))
    lines = [(at, spoken(path)) for at, path in voices]
    spans = [(at - 0.12, at + len(line) / RATE + 0.1) for at, line in lines]
    for i in range(track.n):
        t = i / RATE
        near = max((min(1, (t - a) / 0.15 + 1, (b - t) / 0.25 + 1) for a, b in spans if a - 0.15 < t < b + 0.25), default=0)
        if near > 0: s[i] *= 1 - 0.68 * near
    for at, line in lines:
        gain = music / max(1e-6, max(abs(v) for v in line))
        start = int(at * RATE)
        for j, v in enumerate(line):
            if 0 <= start + j < track.n: s[start + j] += v * gain


def render_chip(seconds, out, pops, lands, boings, voices=(), cues=None):
    """The chiptune BOTS! song on the cut's `cues` (seconds): `groove` the first shot (the beat drops there),
    `quiet` where the bots start talking (chords and hats only under them), `back` after the last
    of their lines (the tune again, from the next bar), `outro` the closing page."""
    cues = cues or {}
    g0 = cues.get('groove', 2 * CHIP_BAR)
    at_bar = lambda k: g0 + k * CHIP_BAR
    quiet = round((cues['quiet'] - g0) / CHIP_BAR) if 'quiet' in cues else 10 ** 6
    back = math.ceil((cues['back'] + 0.3 - g0) / CHIP_BAR) if 'back' in cues else quiet
    outro = round((cues.get('outro', seconds - 5) - g0) / CHIP_BAR)
    track = Track(seconds)
    first = -math.floor(g0 / CHIP_BAR)
    last = math.ceil((seconds - g0) / CHIP_BAR)
    track.add(max(0, at_bar(first) - 0.25), 0.25 + max(0, at_bar(first)), power_up(0.05, 0.25 + max(0, at_bar(first))))
    for k in range(first, last):
        t0 = at_bar(k)
        notes, root = PROG[k % 4]
        part = ('title' if k < 0 else 'groove' if k < quiet else 'quiet' if k < back
                else 'again' if k < outro else 'outro')
        n = k - (0 if part == 'groove' else back if part == 'again' else outro if part == 'outro' else 0)
        beats = lambda *bs: [t0 + b * CHIP_BEAT for b in bs]
        if part == 'outro':
            if n == 0:
                for b, note, length in JINGLE:
                    track.add(t0 + b * CHIP_BEAT, length * CHIP_BEAT, pulse(hz(note + 12), 0.25, 0.11, length * CHIP_BEAT, vibrato=0.2))
                for at in beats(0, 1, 2, 3): track.add(at, 0.25, triangle(hz(36), 0.32, 0.24))
                for at in beats(0, 2): track.add(at, 0.3, chip_kick(0.5))
                for at in beats(1, 3): track.add(at, 0.2, chip_snare(0.16))
            elif n == 1:
                # The last chord, held to the end.
                ring = seconds - t0
                for note in (72, 76, 79, 84):
                    track.add(t0, ring, pulse(hz(note), 0.25 if note == 84 else 0.5, 0.045, ring, vibrato=0.15, sustain=0.75))
                track.add(t0, ring, triangle(hz(36), 0.32, ring))
                track.add(t0, 0.3, chip_kick(0.55)); track.add(t0, 2.5, crash(0.12))
            continue
        # Bass: an octave bounce in eighths, half notes while the bots talk; the title's first bar has none.
        if part == 'quiet':
            for at in beats(0, 2): track.add(at, 2 * CHIP_BEAT, triangle(hz(root - 12), 0.3, 2 * CHIP_BEAT - 0.02))
        elif not (part == 'title' and k == first):
            for e in range(8):
                track.add(t0 + e * CHIP_BEAT / 2, CHIP_BEAT / 2, triangle(hz(root - 12 + (12 if e % 2 else 0)), 0.3, CHIP_BEAT / 2 - 0.02))
        # Chords: held and hollow on the title and under the voices; a thin arpeggio in sixteenths otherwise.
        if part in ('title', 'quiet'):
            for note in notes:
                track.add(t0, CHIP_BAR, pulse(hz(note), 0.5, 0.028, CHIP_BAR - 0.02, attack=0.08, sustain=0.8))
        if part in ('groove', 'again') or (part == 'title' and k == -1):
            loud = 0.05 if part == 'title' else 0.04 if (part == 'groove' and n < 8) or part == 'again' else 0.065
            octave = 12 if not (part == 'groove' and n >= 8) else 24
            for e in range(16):
                note = notes[(0, 1, 2, 1)[e % 4] if e % 8 < 4 else (2, 1, 0, 1)[e % 4]] + octave
                track.add(t0 + e * CHIP_BEAT / 4, CHIP_BEAT / 4, pulse(hz(note), 0.125, loud, CHIP_BEAT / 4 - 0.01, sustain=0.5))
        # The tune, with an echo a dotted eighth later; harmony a third below when it comes back.
        tune = (TUNE_A + TUNE_B)[n] if part == 'groove' and n < 8 else TUNE_C[n % 4] if part == 'again' else None
        if tune:
            for b, note, length in tune:
                d = length * CHIP_BEAT
                track.add(t0 + b * CHIP_BEAT, d, pulse(hz(note), 0.25, 0.1, d - 0.02, vibrato=0.22, slide=0.6 if length >= 1 else 0))
                track.add(t0 + b * CHIP_BEAT + 0.375, d, pulse(hz(note), 0.25, 0.035, d - 0.02, vibrato=0.22))
                if part == 'again':
                    track.add(t0 + b * CHIP_BEAT, d, pulse(hz(note - (4 if note % 12 in (4, 9, 11) else 3)), 0.5, 0.04, d - 0.02))
        # Drums.
        if part == 'quiet':
            track.add(t0, 0.3, chip_kick(0.22))
            for at in beats(0.5, 1.5, 2.5, 3.5): track.add(at, 0.05, noise(0.025, 0.015, 0.9))
            if k == back - 1:
                # Up into the tune again, once the last line has been said.
                rise_from = max(t0, cues.get('back', t0) + 0.1)
                track.add(rise_from, t0 + CHIP_BAR - rise_from, riser(0.1, t0 + CHIP_BAR - rise_from))
                for e in range(8): track.add(t0 + (2 + e / 4) * CHIP_BEAT, 0.15, chip_snare(0.05 + 0.02 * e))
            continue
        if part == 'title':
            if k == -1:
                for at in beats(*[e / 2 for e in range(8)]): track.add(at, 0.05, noise(0.03, 0.015, 0.9))
                for e in range(8): track.add(t0 + (2 + e / 4) * CHIP_BEAT, 0.15, chip_snare(0.04 + 0.018 * e))
            continue
        if part in ('groove', 'again') and n == 0:
            track.add(t0, 2.0, crash(0.11))
        for at in beats(0, 2, 2.5): track.add(at, 0.3, chip_kick(0.5))
        fill = (part == 'groove' and n in (7, quiet - 1)) or (part == 'again' and k == outro - 1)
        for at in (beats(1, 3, 3.25, 3.5, 3.75) if fill else beats(1, 3)): track.add(at, 0.2, chip_snare(0.17))
        for e in range(16 if part == 'again' else 8):
            step = CHIP_BEAT / (4 if part == 'again' else 2)
            track.add(t0 + e * step, 0.05, noise(0.035 if e % 2 else 0.02, 0.014, 0.9))
    for at, note in lands:
        track.add(at, 0.22, pulse(hz(note), 0.25, 0.1, 0.2, sustain=0.5))
    for at in boings:
        track.add(at, 0.6, chip_boing(0.09))
    for at in pops:
        track.add(at, 0.25, blip(0.07))
    # Rounded off a little: a square wave is all edges.
    smooth, y = 1 - math.exp(-2 * math.pi * 7000 / RATE), 0.0
    for i in range(track.n):
        y += smooth * (track.s[i] - y)
        track.s[i] = y
    lay_voices(track, voices)
    return finish(track, seconds, out)


# The BOTS! song: a deep hip-hop groove in A minor, 96 bpm, the sixteenths swung. 96 bpm puts the
# bars where 120 did at the cut's turns: the first shot, back after the voices, the last chord.
DEEP_BEAT = 60 / 96
DEEP_BAR = 4 * DEEP_BEAT
DEEP_STEP = DEEP_BEAT / 4
DEEP_SWING = 0.03
# A minor 7, F major 7, C add 9, G 6: (the keys' chord, the bass root).
DEEP_PROG = [([57, 60, 64, 67], 33), ([53, 57, 60, 64], 29), ([55, 60, 62, 64], 36), ([55, 59, 62, 64], 31)]
# A bar's drums by sixteenth, boom-bap: the kick, the backbeat, a ghost before the one.
DEEP_KICK = {0: 1.0, 7: 0.6, 10: 0.85}
DEEP_SNARE = (4, 12)
# The bass by sixteenth: (step, semitones over the root, sixteenths long), sliding into the last.
DEEP_BASS = [(0, 0, 6), (7, 0, 2.5), (10, 0, 2.5), (13, 7, 1), (14, 12, 2)]
# The keys' tune, low and lazy, two four-bar phrases: (beat, note, beats).
RIFF_A = [[(0, 76, .5), (.5, 74, .5), (1, 72, .5), (1.5, 69, 1.5), (3.5, 72, .5)],
          [(0, 74, .5), (.5, 72, .5), (1, 69, .5), (1.5, 65, 1.5), (3.5, 67, .5)],
          [(0, 72, .5), (.5, 76, .5), (1, 79, 1), (2, 76, .5), (2.5, 74, .5), (3, 72, 1)],
          [(0, 74, 1), (1, 71, .5), (1.5, 67, 1), (2.5, 69, .5), (3, 71, 1)]]
RIFF_B = [[(0, 81, .5), (.5, 79, .5), (1, 76, .5), (1.5, 72, 1), (2.5, 74, .5), (3, 76, 1)],
          [(0, 77, .5), (.5, 76, .5), (1, 72, .5), (1.5, 69, 1), (2.5, 72, .5), (3, 74, 1)],
          [(0, 76, .5), (.5, 79, .5), (1, 84, 1), (2, 83, .5), (2.5, 79, .5), (3, 76, 1)],
          [(0, 79, 1), (1, 74, .5), (1.5, 71, .5), (2, 74, 1), (3, 71, 1)]]
RIFF_END = [(0, 72, .5), (.5, 76, .5), (1, 79, .5), (1.5, 84, 1.5), (3, 83, .5), (3.5, 79, .5)]


def keys(f, loud, length):
    """An electric piano: a sine bent by another at its own pitch, the bend dying away, and a
    glassy tine at the start."""
    c, m, tine = Osc(), Osc(), Osc()
    def voice(t):
        bend = (1.6 * math.exp(-t / 0.25) + 0.25) * math.sin(2 * math.pi * m.step(f))
        x = math.sin(2 * math.pi * c.step(f) + bend) + 0.15 * math.sin(2 * math.pi * tine.step(f * 7)) * math.exp(-t / 0.02)
        return loud * x * math.exp(-t / 1.4) * max(0.0, min(1.0, (length - t) / 0.08)) * min(1, t / 0.003)
    return voice


def deep_bass(f, loud, length, slide_from=None):
    """A round, low bass: a sine pushed a little into a square so phone speakers, which can't
    play the fundamental, still give it its pitch; it can slide up into its note."""
    osc = Osc()
    def voice(t):
        g = f * (slide_from / f) ** max(0.0, 1 - t / 0.07) if slide_from else f
        return loud * math.tanh(2.4 * math.sin(2 * math.pi * osc.step(g))) / math.tanh(2.4) \
            * shape(t, length, attack=0.006, decay=0.35, sustain=0.75, release=0.06)
    return voice


def soft_pad(notes, loud, length):
    """Triangles a little apart on each note, faded in and out: warm, under everything."""
    oscs = [(Osc(), hz(n) * d) for n in notes for d in (0.997, 1.003)]
    return lambda t: loud * sum(4 * abs(o.step(f) - 0.5) - 1 for o, f in oscs) / len(oscs) \
        * shape(t, length, attack=0.4, decay=0.1, sustain=1, release=0.5)


def deep_kick(loud):
    osc, click = Osc(), noise(1.0, 0.0015, 0.2)
    return lambda t: loud * math.tanh(1.8 * (math.sin(2 * math.pi * osc.step(46 + 80 * math.exp(-t / 0.04))) * math.exp(-t / 0.36)
                                             + 0.2 * click(t)))


def deep_snare(loud):
    body, hiss = Osc(), noise(1.0, 0.16, 0.25)
    return lambda t: loud * (0.7 * hiss(t) + 0.55 * math.sin(2 * math.pi * body.step(175 * (1 + 0.3 * math.exp(-t / 0.01)))) * math.exp(-t / 0.07))


def tom(f, loud):
    osc = Osc()
    return lambda t: loud * math.sin(2 * math.pi * osc.step(f * (1 + 0.6 * math.exp(-t / 0.03)))) * math.exp(-t / 0.22)


def rim(loud):
    osc, tick = Osc(), noise(1.0, 0.006, 0.8)
    return lambda t: loud * (tick(t) + 0.6 * math.sin(2 * math.pi * osc.step(1700)) * math.exp(-t / 0.012))


def clap(loud):
    hiss = noise(1.0, 1e9, 0.7)
    def voice(t):
        hits = sum(math.exp(-(t - d) / 0.006) for d in (0, 0.011, 0.022) if t >= d)
        return loud * hiss(t) * 0.5 * (hits + (0.8 * math.exp(-(t - 0.022) / 0.11) if t >= 0.022 else 0))
    return voice


def room(dry, mix=0.2):
    """A small room (Freeverb's combs and all-passes, shorter), `mix` of it added back."""
    out = array.array('f', bytes(4 * len(dry)))
    for delay in (1116, 1188, 1277, 1356):
        buf, store, i = [0.0] * delay, 0.0, 0
        for n, x in enumerate(dry):
            y = buf[i]
            store = y * 0.6 + store * 0.4
            buf[i] = x + store * 0.7
            i = (i + 1) % delay
            out[n] += y * 0.25
    for delay in (225, 556):
        buf, i = [0.0] * delay, 0
        for n in range(len(out)):
            y = buf[i]
            buf[i] = out[n] + y * 0.5
            out[n] = y - out[n]
            i = (i + 1) % delay
    for n in range(len(out)):
        out[n] = dry[n] + mix * out[n]
    return out


def render_deep(seconds, out, pops, lands, boings, voices=(), cues=None):
    """The BOTS! song on the cut's `cues`, as `render_chip`'s, with its own bar: the pad swelling
    and the bass and kick coming in over the title, a tom fill into the drop, the beat, bass and
    keys with the tune over the features, the pad and a light beat while the bots talk (kick, rim,
    hats), a snare roll and fill back into the tune, and the closing phrase and a C chord to end."""
    cues = cues or {}
    bar = DEEP_BAR
    g0 = cues.get('groove', 2 * bar)
    at_bar = lambda k: g0 + k * bar
    quiet = round((cues['quiet'] - g0) / bar) if 'quiet' in cues else 10 ** 6
    back = math.ceil((cues['back'] + 0.3 - g0) / bar) if 'back' in cues else quiet
    outro = round((cues.get('outro', seconds - 5) - g0) / bar)
    track, wet = Track(seconds), Track(seconds)        # the second goes through the room
    first = -math.floor(g0 / bar)
    last = math.ceil((seconds - g0) / bar)
    # Before the first bar: the pad swelling, a low boom as the title's letters start to fall.
    lead_in = at_bar(first)
    if lead_in > 0.05:
        wet.add(0, lead_in + 0.5, soft_pad(DEEP_PROG[3][0], 0.09, lead_in + 0.5))
        track.add(0.25, 1.2, deep_kick(0.5)); track.add(0.25, lead_in - 0.25, deep_bass(hz(31), 0.35, lead_in - 0.3))
    for k in range(first, last):
        t0 = at_bar(k)
        notes, root = DEEP_PROG[k % 4]
        part = ('title' if k < 0 else 'groove' if k < quiet else 'quiet' if k < back
                else 'again' if k < outro else 'outro')
        n = k - (back if part == 'again' else outro if part == 'outro' else 0)
        step = lambda i: t0 + i * DEEP_STEP + (DEEP_SWING if i % 2 else 0)

        def fill():
            # The last beat down the toms, into a crash on the next bar.
            for i, f in zip(range(12, 16), (147, 147, 110, 82)):
                track.add(step(i), 0.45, tom(f, 0.34))

        def drums(light=False, claps=False):
            for i, loud in DEEP_KICK.items():
                if not light or i == 0: track.add(step(i), 0.6, deep_kick(0.7 * loud * (0.6 if light else 1)))
            for i in DEEP_SNARE:
                if light:
                    track.add(step(i), 0.05, rim(0.1))
                else:
                    track.add(step(i), 0.4, deep_snare(0.34)); wet.add(step(i), 0.4, deep_snare(0.12))
                    track.add(step(i), 0.3, clap(0.1 if claps else 0.05))
            if not light: track.add(step(15), 0.15, deep_snare(0.05))
            for i in range(16):
                if not light or i % 2 == 0:
                    track.add(step(i), 0.03, noise((0.03 if i % 2 == 0 else 0.016) * (0.7 if light else 1), 0.016, 0.88))

        def bass_and_keys(soft=False):
            for j, (i, semis, length) in enumerate(DEEP_BASS):
                before = DEEP_BASS[j - 1][1] if j else None
                slide = hz(root + before) if (i == 14 and before is not None) else None
                track.add(step(i), length * DEEP_STEP + 0.05, deep_bass(hz(root + semis), 0.42 * (0.7 if soft else 1), length * DEEP_STEP, slide))
            for i, length in ((0, 6), (10, 4)):
                for note in notes:
                    wet.add(step(i), length * DEEP_STEP, keys(hz(note), 0.045, length * DEEP_STEP))

        if part == 'title':
            # The pad, the bass on the one and a half-time beat, and the fill into the drop.
            wet.add(t0, bar, soft_pad(notes, 0.09, bar))
            for note in notes: wet.add(t0, bar, keys(hz(note), 0.05, bar))
            track.add(t0, bar, deep_bass(hz(root), 0.4, bar - 0.1))
            track.add(step(0), 0.6, deep_kick(0.6)); track.add(step(8), 0.6, deep_kick(0.55))
            track.add(step(4), 0.05, rim(0.08)); track.add(step(12), 0.4, deep_snare(0.2))
            for i in range(0, 12, 2): track.add(step(i), 0.03, noise(0.022, 0.016, 0.88))
            fill()
            continue
        if part == 'outro':
            if n == 0:
                drums(claps=True); bass_and_keys()
                for b, note, length in RIFF_END:
                    wet.add(t0 + b * DEEP_BEAT, length * DEEP_BEAT, keys(hz(note - 12), 0.12, length * DEEP_BEAT))
                fill()
            elif n == 1:
                # Home on C: the chord struck and left to ring, a low boom under it.
                ring = seconds - t0
                track.add(t0, 0.6, deep_kick(0.75)); track.add(t0, 2.5, crash(0.08))
                track.add(t0, ring, deep_bass(hz(36), 0.42, ring - 0.05))
                for note in (48, 55, 60, 64, 67, 74):
                    wet.add(t0, ring, keys(hz(note), 0.05, ring))
                wet.add(t0, ring, soft_pad([60, 64, 67], 0.08, ring))
            continue
        if part == 'quiet':
            # Under the bots: the pad, the bass long and low, kick and rim and hats.
            drums(light=True)
            track.add(t0, bar, deep_bass(hz(root), 0.3, bar - 0.08))
            wet.add(t0, bar, soft_pad(notes, 0.07, bar))
            if k == back - 1:
                roll_from = max(8, math.ceil((cues.get('back', t0) + 0.1 - t0) / DEEP_STEP))
                for i in range(roll_from, 12): track.add(step(i), 0.14, deep_snare(0.06 + 0.035 * (i - roll_from)))
                fill()
            continue
        # The groove: the beat, the bass, the keys, and the tune on the keys, low.
        if n == 0: track.add(t0, 2.0, crash(0.08))
        drums(claps=part == 'again' or n >= 6)
        bass_and_keys()
        if (part == 'groove' and n in (3, 7, quiet - 1)) or (part == 'again' and k == outro - 1):
            fill()
        line = (RIFF_A + RIFF_B)[n] if part == 'groove' and n < 8 else RIFF_B[n % 4] if part == 'again' else None
        if line:
            for b, note, length in line:
                d = length * DEEP_BEAT
                wet.add(t0 + b * DEEP_BEAT, d + 0.3, keys(hz(note - 12), 0.12, d + 0.3))
                if part == 'again': wet.add(t0 + b * DEEP_BEAT, d + 0.3, keys(hz(note), 0.04, d + 0.3))
    for at, note in lands:
        wet.add(at, 0.9, keys(hz(note - 12), 0.14, 0.9))
    for at in boings:
        track.add(at, 0.6, boing(0.16))
    for at in pops:
        track.add(at, 0.3, bloop(0.11))
    for i, v in enumerate(room(wet.s, 0.28)):
        track.s[i] += v
    lay_voices(track, voices)
    return finish(track, seconds, out)


def bar_length(song):
    """The song's bar in seconds: what its turns are counted in."""
    return DEEP_BAR if song == 'bots' else CHIP_BAR

def render(seconds, out, pops=(), song='phone', lands=(), boings=(), voices=(), cues=None):
    if song in ('bots', 'chip'):
        return (render_deep if song == 'bots' else render_chip)(seconds, out, pops, lands, boings, voices, cues)
    track = Track(seconds)
    bars = int(seconds / BAR) + 1
    for b in range(bars):
        notes, root = CHORDS[b % 4]
        t0 = b * BAR
        intro = b == 0                                     # the first bar: marimba alone
        for i, k in enumerate(ARP):
            loud = 0.16 if i % 2 == 0 else 0.11
            track.add(t0 + i * BEAT / 2, 0.9, marimba(hz(notes[k] + 12), loud))
        if b % 2 == 1:                                     # a sparkle on top every other bar
            track.add(t0 + 3.5 * BEAT, 1.4, bell(hz(notes[-1] + 24), 0.05))
        if intro:
            continue
        for beat, loud in ((0, 0.34), (1.5, 0.22), (2, 0.3), (3.5, 0.18)):
            track.add(t0 + beat * BEAT, 0.5, bass(hz(root), loud))
        for beat in (0, 2):
            track.add(t0 + beat * BEAT, 0.3, kick(0.42))
        for beat in (1, 3):
            track.add(t0 + beat * BEAT, 0.22, noise(0.13, 0.045, 0.6))
        for e in range(8):
            if e % 2 == 1:
                track.add(t0 + e * BEAT / 2, 0.06, noise(0.04, 0.012, 0.9))
    for at in pops:
        track.add(at, 0.3, bloop(0.2))
    return finish(track, seconds, out)


def finish(track, seconds, out):
    # Fade in over the first half second and out over the last two and a half, then level it.
    s = track.s
    for i in range(track.n):
        t = i / RATE
        s[i] *= min(1, t / 0.5) * min(1, max(0, (seconds - t) / 2.5))
    peak = max(1e-6, max(abs(v) for v in s))
    gain = 0.7 / peak
    pcm = array.array('h', (int(max(-1, min(1, v * gain)) * 32767) for v in s for _ in (0, 1)))
    with wave.open(out, 'wb') as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm.tobytes())
    return out


if __name__ == '__main__':
    render(float(sys.argv[1]), sys.argv[2], [float(p) for p in sys.argv[3:]])
