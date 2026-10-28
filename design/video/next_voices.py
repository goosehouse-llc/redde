#!/usr/bin/python3
"""The next release's video's spoken lines (make_next.py), said by Kokoro: Redde's in its own voice
(Settings.defaultKokoroVoice, as in bot_voices.py), the person's in another. Made-up people only.
Writes voice-next-<line>.wav here.

  KOKORO_URL=http://<host>:8880 next_voices.py
"""
import json, os, urllib.request

V = os.path.dirname(os.path.abspath(__file__))
REDDE, PERSON = 'am_onyx(2)+bm_george(1)', 'af_heart'
LINES = [
    ('hey', REDDE, "Hey! It's Redde! Pick up!"),
    ('call', REDDE, "Hi, it's Redde! Your package just came!"),
    ('done', REDDE, "Done! I'll remind you at six."),
    ('thanks', PERSON, 'Thanks! Can you remind me to bring it in at six?'),
    ('ask', PERSON, 'Tell Milo a bedtime story about our dog, Pickles.'),
    ('story', REDDE, 'Once upon a time, a little dog named Pickles found a star in the backyard. '
                     'It was small and warm, and it hummed when he sniffed it.'),
    ('bye', REDDE, 'Call you later!'),
]


def main():
    base = os.environ.get('KOKORO_URL', '').rstrip('/')
    if not base: raise SystemExit('KOKORO_URL=http://<host>:8880 next_voices.py')
    for name, voice, words in LINES:
        body = json.dumps({'model': 'kokoro', 'input': words, 'voice': voice, 'response_format': 'wav', 'speed': 1.0}).encode()
        request = urllib.request.Request(f'{base}/v1/audio/speech', body, {'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=120) as reply, open(f'{V}/voice-next-{name}.wav', 'wb') as out:
            out.write(reply.read())
        print(f'voice-next-{name}.wav')


if __name__ == '__main__':
    main()
