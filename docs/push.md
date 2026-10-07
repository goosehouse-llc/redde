# Notifications when Redde is closed

While Redde runs, it posts its own notifications: a reply finished, a command waits for approval.
iOS closes an app in the background after seconds to minutes, and from then on Redde can say
nothing. This is how a person's own Hermes says it instead, without anyone in between being able to
read it.

It is off until someone pairs a Hermes, and nothing described here happens before that.

## The parts

```
Hermes (yours)                    relay (Goosehouse)            Apple            iPhone
 redde-push plugin  ── sealed ──▶  /v1/devices/…/push  ──────▶  APNs  ─────────▶  EchoPush extension
   has the key                      has the push address                           has the key
```

- **The plugin** (`companion/hermes-plugin/redde-push`) runs inside Hermes. Its hooks fire when a
  reply finishes and when a command waits for a person. It writes a short note (kind, session id,
  conversation title, the reply's first 500 characters or the command), seals it with AES-256-GCM
  under a key it shares with one phone, and posts the result to the relay.
- **The relay** (`companion/push-relay`, the `/v1` routes) is a Cloudflare Worker. It holds, for
  each pairing, the phone's APNs token, the SHA-256 of a secret, and when the phone last checked
  in. A post that carries the secret is forwarded to Apple as a notification whose visible text is
  always "Open Redde to see what's new" and whose payload is the sealed note. It has no key and
  keeps nothing of what passes.
- **Apple** delivers it. It sees what the relay sees.
- **The notification extension** (`EchoPush`) runs on the phone when the notification arrives,
  opens the note with the key from the Keychain and replaces the text. A note it can't open is
  shown as it came. If the app is in front it does the same itself (`Notifier.presentUnopened`),
  which also covers the simulator, where a simulated push skips extensions.

## Pairing

The key is agreed between the plugin and the phone; the relay only carries the two halves.

1. On the Hermes machine: `hermes redde-push pair`. The plugin makes an X25519 key pair and shows
   its public key as a link, `https://redde.goosehouse.org/connect#push=<key>`, and as a QR code
   of that link. The key sits after the `#`, which a browser never sends; with Redde installed,
   iOS opens the link in the app without loading the page.
2. In Redde: Settings › Voice › Notify when Redde is closed › scan the code (or paste the link,
   or open it). The app asks before doing anything. Then it asks iOS for a push token, makes its
   own key pair, registers the token at the relay under a fresh random secret (the relay is sent
   the secret's hash), and leaves its answer at the relay: its public key, and its relay id and
   secret sealed for the plugin.
3. The plugin, polling, takes the answer. Both sides now derive the same 64 bytes with
   HKDF-SHA256 from the X25519 shared secret (salt: the two public keys; info: `redde-push v1`):
   32 for notes, 32 for the answer's box. The plugin opens the box, stores the phone, and sends a
   first note. When that note opens on the phone, the pairing is confirmed.

The answer waits at the relay in a slot named by a hash of the plugin's public key, written once
by a registered phone, read once, gone after ten minutes. What makes the pairing trustworthy is
where the link was read: the person's own terminal. Someone who could replace the QR code there
could pair their own phone; the relay could not, since it never sees a private key.

## Which conversations notify

- Over the **Hermes API**, every turn notifies every paired phone: on a Hermes with the app paired,
  the API's client is the app.
- Over the **Dashboard**, a conversation notifies a phone once that phone has taken part in it.
  The app says so with a plugin command at the start of a turn
  (`command.dispatch redde-push "watch <session> <device ids>"`), once per conversation per
  launch. A turn typed at the terminal or in Hermes Desktop stays quiet.
- `hermes redde-push notify all` makes every conversation on that Hermes notify.

Approvals notify when a person is asked (`pre_approval_request` with a surface other than
`smart`). Over the Hermes API a stock Hermes doesn't hold a command for a person at all; the agent
is told it needs approval and says so in its reply.

Twice the same thing: while the app is still alive in the background it posts its own banner,
and the pushed one for the same event is removed (`Notifier.sweepRelayDuplicates`).

## What is where

| Where | What |
|---|---|
| Hermes, `$HERMES_HOME/redde-push/devices.json` (mode 600) | per phone: relay id, relay secret, the note key, a name |
| Hermes, `…/watch.json` | which sessions each phone follows (the last 500) |
| Relay (KV) | per pairing: APNs token, SHA-256 of the relay secret, sandbox or production, last check-in. Forgotten after 120 days without one, or when Apple says the token is dead |
| iPhone Keychain (app group, this device only, readable after first unlock) | per pairing: relay id, relay secret, the note key, the machine's name |

Removing a pairing in the app deletes it from the phone and the relay; the plugin learns from its
next note, which the relay turns away with 410, and forgets the phone. `hermes redde-push remove`
does it from the other end.

## Wire formats

Pairing link: `…/connect#push=<base64url X25519 public key>[&relay=<url>]`, or
`redde://connect?push=…`. The relay rides along only when it isn't the usual one, and the app
refuses a link for a relay it isn't set to.

Answer, at `PUT /v1/pairings/<rid>` where `rid` is the first 32 hex digits of
`SHA-256("redde-push rendezvous v1" ‖ offered key)`:

```json
{"pub": "<base64url X25519 public key>", "box": "<base64url nonce ‖ ciphertext ‖ tag>"}
```

The box is AES-256-GCM under the box key, additional data `redde-push pairing`, around
`{"id": "<relay id>", "send": "<relay secret>", "name": "<device name>"}`.

Note, the `payload` of `POST /v1/devices/<id>/push` and the `e` of the notification: standard
base64 of `key id (4 bytes) ‖ nonce (12) ‖ ciphertext ‖ tag (16)`. The key id is the first four
bytes of `SHA-256("redde-push key id" ‖ note key)`; the additional data is the relay id, so a note
opens only for the pairing it was sealed to. Inside:

```json
{"v": 1, "k": "reply", "s": "<session id>", "t": "<title>", "b": "<text>", "d": "<detail>", "n": "<machine>", "at": 1791330000}
```

`k` is `reply`, `approval`, `paired` or `test`. A kind the app doesn't know leaves the relay's
words in place. The plugin also sends an `apns-collapse-id`, a hash over the key, the kind and the
session, so a later note about the same thing replaces the earlier one; the relay learns only that
two notes belong together.

## Testing

```
node --test companion/push-relay/test/relay.test.mjs
python -m unittest discover -s companion/hermes-plugin/redde-push/tests   # needs `cryptography`
scripts/hermes-lab/lab.sh push           # the plugin inside Hermes 0.21.0, 0.21.3 and 0.21.5
scripts/hermes-lab/lab.sh push --app     # and the app in a simulator pairing with each
```

`EchoTests/PushTests.swift` checks the app against values the plugin's code produced, so the two
ends can't drift apart unnoticed. The lab runs the relay's own code under Node with a stand-in for
Apple. One thing no simulator shows: the extension opening a note while the app is closed. That
takes a real notification from Apple, so a phone and the deployed relay.

## Before this ships

- **The relay has to be deployed with the new routes**, reachable at the address in
  `PushService.defaultRelay` and `core.DEFAULT_RELAY` (`https://redde-push.goosehouse.org` as
  written; one constant each). See `companion/push-relay/README.md`.
- **The privacy policy changes.** Today it says Redde adds no intermediary and Goosehouse receives
  nothing. With a pairing, Goosehouse's relay receives the phone's push token and encrypted
  notifications, and Apple delivers them. That is opt-in and unreadable in transit, but it is no
  longer nothing; `docs/privacy.md` and the App Store privacy answers need to say so.
- **Export compliance.** The app now encrypts and decrypts with CryptoKit (AES-GCM, X25519, HKDF)
  beyond HTTPS. `ITSAppUsesNonExemptEncryption` is `false`; whether that still holds is worth a
  look before upload.
- **A new bundle id**, `com.goosehouse.echo.push`, for the extension: an App ID with the app
  group, which Xcode's automatic signing creates on the first archive.
- **On a phone**: pair with a real Hermes; lock the phone and close the app; a reply and an
  approval each arrive with their text; tapping one opens its conversation; Reply on a reply's
  banner sends into it.

## Not done

- Answering an approval that arrived as a notification once the app has been closed. It has no
  Approve and Deny buttons, and tapping it opens the conversation's transcript without the card:
  the app doesn't attach to a turn it didn't start in this run. Until that is built, such an
  approval is answered from another client, or times out. (While the app is still alive in the
  background, its own banner has the buttons, as before.)
- Clarifying questions, sudo and secret prompts don't notify.
- A note the extension couldn't open (the phone not yet unlocked since a restart) stays as the
  relay's words; the app doesn't go back and open it.
- A tapped notification opens its conversation on the server the app is on. One from another of
  the app's servers leaves the app where it was.
