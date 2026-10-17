"""The lab's stand-in for a voice: a tone whose length says how much text it was for."""
import math
import struct
import sys
from array import array


def tone(seconds, rate):
    """A 440 Hz tone at 0.3 of full scale, as 16-bit little-endian mono."""
    samples = array("h", (int(0.3 * 32767 * math.sin(2 * math.pi * 440 * i / rate)) for i in range(int(seconds * rate))))
    if sys.byteorder == "big":
        samples.byteswap()
    return samples.tobytes()


def wav(pcm, rate):
    """`pcm` (16-bit mono) as a WAV file."""
    return (b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16)
            + b"data" + struct.pack("<I", len(pcm)) + pcm)
