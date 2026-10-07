# Push relay

A Cloudflare Worker that carries notifications from a person's Hermes to their iPhone without
being able to read them. `src/index.js` starts with the routes; [docs/push.md](../../docs/push.md)
has the design. The same Worker still serves the older single-household webhook routes
(`/register`, `/hermes`).

## What it needs

| | |
|---|---|
| KV namespace `STORE` | registrations, pairing answers in transit, the cached APNs token |
| `APNS_KEY` (secret) | the `.p8` from the Apple developer account, as PEM |
| `APNS_KEY_ID` (secret) | that key's 10-character id |
| `APNS_TEAM_ID`, `APNS_TOPIC` (vars) | the team, and the app's bundle id |
| `PUSH_LIMIT` (rate limit binding) | 120 notes a minute per pairing; without it there is no limit |
| `HMAC_SECRET`, `REGISTER_SECRET` (secrets) | only for the household routes |

The public address the app and the plugin expect is `https://redde-push.goosehouse.org`
(`PushService.defaultRelay`, `core.DEFAULT_RELAY`). Give the Worker that custom domain, or change
the two constants to wherever it lives.

Registration (`POST /v1/devices`) takes no credentials: a registration is useless without the
secret it was made under, and a push can only reach a token Apple issued for this app. It does
write to KV, so a rate limiting rule on that path in the Cloudflare dashboard is worth having.

## Run it

```
node --test test/relay.test.mjs        # the routes, against an in-memory KV and a stand-in Apple
node test/local.mjs 18980              # the relay on this machine, for the Hermes lab
npx wrangler deploy                    # the real one
npx wrangler tail                      # watch it; nothing a note says is ever logged
```
