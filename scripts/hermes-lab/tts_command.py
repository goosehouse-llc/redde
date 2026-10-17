"""A voice that runs on the server, for the lab's speech-whole scenario: Hermes runs it as a
`type: command` TTS provider and reads the file it writes. A 440 Hz tone at 22.05 kHz (not the
24 kHz the app plays at, so the app's rate conversion is in the path), 50 ms for each character
of the text, as a 16-bit mono WAV.

usage: tts_command.py <text file> <output file>
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from lab_tone import tone, wav  # noqa: E402

text = Path(sys.argv[1]).read_text(encoding="utf-8")
Path(sys.argv[2]).write_bytes(wav(tone(len(text) * 0.05, 22050), 22050))
