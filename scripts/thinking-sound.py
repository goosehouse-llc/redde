#!/usr/bin/env python3
"""Makes the sound voice mode plays while the agent works: Echo/Resources/Earcons/thinking.wav.

Someone typing on a keyboard, looped: about seven seconds of a real recording, runs of keys
with the pauses between them, played round and round. Asked for on 2026-10-27, after ElevenLabs'
calls played a typing sound while the agent worked ("is there a way to have the typing noise
back?"). Typing made from noise was tried first and sounded nothing like a keyboard; this is a
recording of the project owner's own keyboard, made for Redde, so it is Redde's to ship. Until
then the sound was a soft double pulse on one note.

From the recording: a stretch that starts and ends in a pause between keys (so the seam is a
pause too), rumble and hiss filtered off, the room's noise between keys lowered, the keys
evened out (a hard tap or the space bar was 25 dB over the softest), then brought up to about
about 14 dB under the old pulse's loudness (as loud, it was "kind of loud"), and 10 ms fades
at both ends. Needs ffmpeg.

    python3 scripts/thinking-sound.py <recording> [start end]   # seconds; 6.10 13.25 by default
Listen to the result on a Mac:   afplay Echo/Resources/Earcons/thinking.wav
"""
import math
import struct
import subprocess
import sys
import wave
from pathlib import Path

START, END = 6.10, 13.25   # the stretch of the 2026-10-27 recording that loops
GAIN = 0                   # dB, after evening out: about 14 dB under the pulse while it sounds (as loud: "kind of loud"; 5, then 10 dB down: still too loud)
LIMIT = 0.35               # its peak at most: about -9 dBFS, the listening tones' -10

FILTERS = ",".join([
    "atrim={start}:{end}", "asetpts=PTS-STARTPTS",
    "highpass=f=90", "lowpass=f=12000",                      # rumble, hiss
    "afftdn=nr=20:nf=-46",                                    # the room's steady noise
    "agate=threshold=0.006:ratio=2:range=0.25:attack=0.3:release=40",   # lower between keys
    "acompressor=threshold=-30dB:ratio=5:attack=0.5:release=60:makeup=1",  # the keys evened out
    f"volume={GAIN}dB", f"alimiter=limit={LIMIT}:attack=1:release=30:level=0",
    "afade=t=in:d=0.01", "areverse", "afade=t=in:d=0.01", "areverse",     # silent seam
])


def main() -> None:
    if len(sys.argv) not in (2, 4):
        sys.exit(__doc__)
    source = sys.argv[1]
    start, end = (float(sys.argv[2]), float(sys.argv[3])) if len(sys.argv) == 4 else (START, END)
    out = Path(__file__).resolve().parent.parent / "Echo" / "Resources" / "Earcons" / "thinking.wav"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", source, "-af", FILTERS.format(start=start, end=end),
                    "-ac", "1", "-ar", "44100", "-c:a", "pcm_s16le", "-map_metadata", "-1", str(out)], check=True)
    with wave.open(str(out)) as file:
        rate, count = file.getframerate(), file.getnframes()
        samples = [v / 32768 for v in struct.unpack(f"<{count}h", file.readframes(count))]
    window = int(0.05 * rate)
    loudest = max(math.sqrt(sum(v * v for v in samples[i:i + window]) / window)
                  for i in range(0, count - window, window // 2))
    peak = max(abs(v) for v in samples)
    print(f"{out.name}: {count / rate:.2f} s, loudest 50 ms {20 * math.log10(loudest):.1f} dB, "
          f"peak {20 * math.log10(peak):.1f} dBFS")


if __name__ == "__main__":
    main()
