#!/usr/bin/python3
"""The spoken lines of "A day with Redde" (make_day.py), said by Kokoro: Redde's and Sol's in Redde's
own voice (Settings.defaultKokoroVoice, as in bot_voices.py: Sol is the main agent, which speaks in
it), the person's in another. Made-up people only. Writes voice-day-<line>.wav here.

  KOKORO_URL=http://<host>:8880 day_voices.py        the lines not made yet
  KOKORO_URL=http://<host>:8880 day_voices.py all    every line again
"""
import json, os, sys, urllib.request

V = os.path.dirname(os.path.abspath(__file__))
REDDE, PERSON = 'am_onyx(2)+bm_george(1)', 'af_heart'
LINES = [
    ('hey', REDDE, "Rise and shine! It's Redde!"),
    ('headsup', REDDE, 'Dentist in thirty minutes! Bring your insurance card!'),
    ('pipes', PERSON, 'Bagpipes? Not now.'),
    ('pasta', REDDE, 'Ooh, pasta!'),
    ('call', REDDE, "Hi, it's Sol! Home says the garage door is still open. Want me to close it?"),
    ('yes', PERSON, 'Oh! Yes, please.'),
    ('done', REDDE, "Done! It's shut. Sleep tight!"),
    ('bye', REDDE, 'See you tomorrow!'),
    # The 2.3 cut (make_day23.py).
    ('headsup2', REDDE, 'Dentist at two thirty! Bring your insurance card!'),
    ('leave', REDDE, 'Time to go! Twenty-five minutes by car.'),
    ('coffee', REDDE, 'Ooh, coffee!'),
    ('sent', REDDE, 'Sent!'),
]


def main():
    base = os.environ.get('KOKORO_URL', '').rstrip('/')
    if not base: raise SystemExit('KOKORO_URL=http://<host>:8880 day_voices.py')
    for name, voice, words in LINES:
        if 'all' not in sys.argv[1:] and os.path.exists(f'{V}/voice-day-{name}.wav'): continue
        body = json.dumps({'model': 'kokoro', 'input': words, 'voice': voice, 'response_format': 'wav', 'speed': 1.0}).encode()
        request = urllib.request.Request(f'{base}/v1/audio/speech', body, {'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=120) as reply, open(f'{V}/voice-day-{name}.wav', 'wb') as out:
            out.write(reply.read())
        print(f'voice-day-{name}.wav')


if __name__ == '__main__':
    main()
