# redde-push

A Hermes plugin that notifies your iPhone, through [Redde](https://redde.goosehouse.org), when the
agent finishes a reply, waits for you, or gives up on a turn, also when Redde isn't running.

What a notification says is encrypted here, on your Hermes, with a key that only this plugin and
your phone hold. It travels through a relay run by Goosehouse and through Apple's push service;
both carry it without being able to read it. The design is in
[docs/push.md](https://github.com/goosehouse-llc/redde/blob/main/docs/push.md).

## Set up

```
hermes plugins install goosehouse-llc/redde/companion/hermes-plugin/redde-push --enable
```

Restart Hermes (`hermes gateway restart`, and `hermes serve` if you run the Dashboard).

Or leave the terminal out of it: with the Hermes Dashboard login saved in Redde, Settings ›
Voice › Notify when Redde is closed has an Install the Plugin button that has this Hermes fetch
and enable the same plugin. Hermes 0.21.5 and later load it at once; earlier ones still need the
restart above.

**If Redde is connected through the Dashboard**, that is all there is to do here. In Redde:
Settings › Voice › Notify when Redde is closed › Pair with your server. A notification on the
phone confirms the pairing.

**Otherwise** (Redde on the Hermes API, or a phone that isn't signed in to this Hermes), pair
with a code:

```
hermes redde-push pair
```

It shows a QR code and a link, and waits. In Redde: Settings › Voice › Notify when Redde is
closed › Pair with a code. A notification on the phone confirms the pairing.

Run the command as the user Hermes runs as, without `-p`: the pairing is kept in that Hermes home
and read by the gateway and the Dashboard from there.

## Updating

The install line again, with `--force` on the end, then restart Hermes as above. Your pairings are
kept: they live beside the plugin, not in it. (`hermes plugins update redde-push` works from Hermes
0.21.5; earlier releases answer that the plugin wasn't installed from git, which is how they see
one that came out of a folder of a repository.)

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
- **A command waits for approval**: the command and why it was stopped. For a turn over the
  Dashboard the notification has Approve and Deny, and opening the conversation brings back its
  card; Hermes waits five minutes for an answer by default (`approvals.timeout`).
- **The agent asks you a question**: the question and its choices. On Hermes 0.21.3 and later
  the notification takes your answer, typed or by a choice's button, and opening the conversation
  brings back its card.
- **A command run as root waits for your password, or a skill for a secret**: which command, or
  what is asked for. Hermes waits two minutes for a password and five for a secret. Over the
  Dashboard, on Hermes 0.21.3 and later; see below.
- **A turn ended without a reply**: the provider's error. Hermes doesn't tell a plugin that it
  has given up, only each time a request fails, so the plugin waits to see whether anything
  follows: 20 seconds after an error Hermes doesn't retry (a refused key), two and a half minutes
  after one it does (the provider is down), eleven after a rate limit. If the reply arrives
  after all, it takes the notification's place.
- **A task handed to a subagent came back**: what the agent says about it, or, over the Hermes
  API on 0.21.3 and later, where Hermes starts no turn for it, the task's own summary.

All of them only for conversations your phone has taken part in: over the Dashboard the app tells
the plugin which those are, and over the Hermes API every turn counts. A session at the terminal
or in Hermes Desktop stays quiet unless you choose `notify all`.

Hermes has a hook for a plugin when a reply finishes and when a command needs approval. For the
rest the plugin reads what Hermes hands every plugin after each answer from the model: a call to
the question tool there means a question is about to be asked. A password or a secret being
asked for appears nowhere a plugin is shown, so while a followed conversation runs tools the
plugin looks, twice a second, at the list the Dashboard keeps of what it is waiting on a person
for (the list it gives a client that reconnects). That list is Hermes's own business, not an
interface: a later Hermes may move it, and then those two notifications stop until the plugin
catches up. Nothing else depends on it.

The relay is sent the encrypted note and the secret that lets it through to your phone. It is
never sent the key, and it stores nothing that passes.

## What it keeps

`$HERMES_HOME/redde-push/`, readable only by you: `devices.json` (each phone's relay id, relay
secret and key) and `watch.json` (which sessions each phone follows). Delete the folder and
nothing is paired.

## Requirements

Hermes 0.21.0 or later; 0.21.3 or later is the one to have. On 0.21.0 the Dashboard stops a turn
twenty seconds after the app disconnects, so little is left to notify about; setting
`dashboard.ws_orphan_reap_grace_s: 0` in `config.yaml` turns that off. It also keeps no list of
what it is waiting on, so there a password or a secret goes unannounced, and a question's card
doesn't come back when the conversation is opened.

`cryptography`, which Hermes already depends on. Nothing else: the QR code is drawn by `qr.py`
here.

## Tests

In the Redde repository, beside this folder: `companion/hermes-plugin/tests` (unit tests, run
with Hermes's own Python) and `scripts/hermes-lab/lab.sh push`, which runs the plugin inside
unmodified Hermes releases. They are kept out of this folder because everything in it is copied,
and scanned, when the plugin is installed. The scan is also why this page and the plugin's code
avoid the name of the command that runs another as root: Hermes refuses to install a plugin from
GitHub that has it in either.
