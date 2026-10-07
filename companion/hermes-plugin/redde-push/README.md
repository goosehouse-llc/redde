# redde-push

A Hermes plugin that notifies your iPhone, through [Redde](https://redde.goosehouse.org), when the
agent finishes a reply or waits for your approval, also when Redde isn't running.

What a notification says is encrypted here, on your Hermes, with a key that only this plugin and
your phone hold. It travels through a relay run by Goosehouse and through Apple's push service;
both carry it without being able to read it. [docs/push.md](../../../docs/push.md) has the design.

## Set up

```
hermes plugins install goosehouse-llc/redde/companion/hermes-plugin/redde-push --enable
```

Restart Hermes (`hermes gateway restart`, and `hermes serve` if you run the Dashboard), then:

```
hermes redde-push pair
```

It shows a QR code and a link, and waits. In Redde: Settings › Voice › Notify when Redde is
closed › Scan the code it shows. A notification on the phone confirms the pairing.

Run the command as the user Hermes runs as, without `-p`: the pairing is kept in that Hermes home
and read by the gateway and the Dashboard from there.

## Commands

| | |
|---|---|
| `hermes redde-push pair` | pair a phone |
| `hermes redde-push list` | the paired phones |
| `hermes redde-push test` | send each a test notification |
| `hermes redde-push remove <name or id>` | forget a phone |
| `hermes redde-push notify mine` | notify about conversations the phone took part in (the default) |
| `hermes redde-push notify all` | notify about every conversation on this Hermes |

## What is sent, and when

- **A reply finished**: the conversation's title and the reply's first 500 characters.
- **A command waits for approval**: the command and why it was stopped.

Both only for conversations your phone has taken part in: over the Dashboard the app tells the
plugin which those are, and over the Hermes API every turn counts. A session at the terminal or in
Hermes Desktop stays quiet unless you choose `notify all`.

The relay is sent the encrypted note and the secret that lets it through to your phone. It is
never sent the key, and it stores nothing that passes.

## What it keeps

`$HERMES_HOME/redde-push/`, readable only by you: `devices.json` (each phone's relay id, relay
secret and key) and `watch.json` (which sessions each phone follows). Delete the folder and
nothing is paired.

## Requirements

Hermes 0.21.0 or later. `cryptography`, which Hermes already depends on. Nothing else: the QR code
is drawn by `qr.py` here.

## Tests

```
python -m unittest discover -s tests          # with Hermes's own Python
../../../scripts/hermes-lab/lab.sh push       # inside unmodified Hermes releases
```
