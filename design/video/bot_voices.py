#!/usr/bin/python3
"""The BOTS! cut's spoken lines, said by Kokoro in the voices the app gives those bots by default:
Redde's own (Settings.defaultKokoroVoice) and the two the demo roster's Scout and Quill fall on
(BotVoices.assign over Kokoro's English voices). The voice screen's take has no sound, so these go
on the soundtrack where each bot's turn is (make_preview.py bots). Writes voice-<line>.wav here.

  KOKORO_URL=http://<host>:8880 bot_voices.py
"""
import json, os, sys, urllib.request

V = os.path.dirname(os.path.abspath(__file__))
REDDE, SCOUT, QUILL = 'am_onyx(2)+bm_george(1)', 'bf_v0isabella', 'am_liam'
# (line, voice, words): the words are the demo round's (GroupFeed.playDemoRound) and the title's.
LINES = [
    ('hello', REDDE, "Hi! I'm Redde. Meet my crew!"),
    ('redde', REDDE, 'On it. Saturday at 8 is on your calendar, with an alarm at 6:45.'),
    ('scout', SCOUT, "The trail's open, but it's muddy past the second footbridge. Boots, not sneakers."),
    ('quill', QUILL, "And here's your invite: Falls Loop, Saturday at 8. Bring layers. Coffee's on me after."),
]


def main():
    base = os.environ.get('KOKORO_URL', '').rstrip('/')
    if not base: raise SystemExit('KOKORO_URL=http://<host>:8880 bot_voices.py')
    for name, voice, words in LINES:
        body = json.dumps({'model': 'kokoro', 'input': words, 'voice': voice, 'response_format': 'wav', 'speed': 1.0}).encode()
        request = urllib.request.Request(f'{base}/v1/audio/speech', body, {'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=120) as reply, open(f'{V}/voice-{name}.wav', 'wb') as out:
            out.write(reply.read())
        print(f'voice-{name}.wav')


if __name__ == '__main__':
    main()
