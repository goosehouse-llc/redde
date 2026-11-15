#!/usr/bin/python3
"""The agents cut's spoken lines (make_agents.py), said by Kokoro in Redde's own voice
(Settings.defaultKokoroVoice): its hello over the title and its send-off on the closing page. The
voice round's lines are bot_voices.py's (voice-redde/scout/quill.wav: the main agent, Sol here,
speaks in Redde's voice). Writes voice-agents-<line>.wav here.

  KOKORO_URL=http://<host>:8880 agents_voices.py
"""
import json, os, urllib.request

V = os.path.dirname(os.path.abspath(__file__))
REDDE = 'am_onyx(2)+bm_george(1)'
LINES = [
    ('hello', REDDE, "Hi! I'm Redde. Meet the team!"),
    ('bye', REDDE, 'Go team!'),
]


def main():
    base = os.environ.get('KOKORO_URL', '').rstrip('/')
    if not base: raise SystemExit('KOKORO_URL=http://<host>:8880 agents_voices.py')
    for name, voice, words in LINES:
        body = json.dumps({'model': 'kokoro', 'input': words, 'voice': voice, 'response_format': 'wav', 'speed': 1.0}).encode()
        request = urllib.request.Request(f'{base}/v1/audio/speech', body, {'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=120) as reply, open(f'{V}/voice-agents-{name}.wav', 'wb') as out:
            out.write(reply.read())
        print(f'voice-agents-{name}.wav')


if __name__ == '__main__':
    main()
