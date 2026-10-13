#!/usr/bin/env python3
"""Makes the sound voice mode plays while the agent works: Echo/Resources/Earcons/thinking.wav.

A soft double pulse on one note, the A below the listening tones' upper note, played round and
round. One pitch, so it can't be taken for the two-note tones that say the microphone has opened
or closed, and quiet: its peak is 6 dB under theirs.

Run it again after changing a number here:   python3 scripts/thinking-sound.py
Listen to the result on a Mac:               afplay Echo/Resources/Earcons/thinking.wav
"""
import math
import struct
import wave
from pathlib import Path

RATE = 44100
LOOP = 3.0                # seconds from one double pulse to the next (2.2 until 2026-10-13: asked for more room)
NOTE = 442.5              # Hz: an octave under the listening tones' 885
PEAK = 10 ** (-16 / 20)   # the listening tones peak at -10 dBFS
#: when each pulse starts, how loud it is beside the first, and how fast it dies away (seconds)
PULSES = [(0.0, 1.0, 0.16), (0.34, 0.6, 0.20)]   # the second came 0.22 s after the first until the same day
ATTACK = 0.018            # seconds: softer than the listening tones, which start at once
#: the note's overtones, as the listening tones have them: twice the pitch at -20 dB, three times at -34
PARTIALS = [(1, 1.0), (2, 0.1), (3, 0.02)]


def sample(t: float) -> float:
    value = 0.0
    for start, level, decay in PULSES:
        age = t - start
        if age < 0:
            continue
        rise = 0.5 - 0.5 * math.cos(math.pi * min(age / ATTACK, 1))
        tone = sum(gain * math.sin(2 * math.pi * NOTE * harmonic * age) for harmonic, gain in PARTIALS)
        value += level * rise * math.exp(-age / decay) * tone
    return value


def main() -> None:
    samples = [sample(n / RATE) for n in range(int(LOOP * RATE))]
    scale = PEAK / max(abs(s) for s in samples)
    # The last few milliseconds are eased to nothing, so the loop's seam is silence meeting silence.
    fade = int(0.01 * RATE)
    for i in range(fade):
        samples[-1 - i] *= i / fade
    out = Path(__file__).resolve().parent.parent / "Echo" / "Resources" / "Earcons" / "thinking.wav"
    with wave.open(str(out), "wb") as file:
        file.setnchannels(1)
        file.setsampwidth(2)
        file.setframerate(RATE)
        file.writeframes(b"".join(struct.pack("<h", round(s * scale * 32767)) for s in samples))
    print(f"{out.name}: {LOOP} s, peak {20 * math.log10(PEAK):.0f} dBFS")


if __name__ == "__main__":
    main()
