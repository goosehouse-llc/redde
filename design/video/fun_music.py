#!/usr/bin/python3
"""A bright little loop for the fun Phone tools cut, made here so there is nothing to license:
marimba arpeggios over C, G, A minor and F, a bouncing bass, a soft kick, claps and a shaker, and a
"bloop" wherever a caption pops in. Plain Python, no packages.

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


def render(seconds, out, pops=()):
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
