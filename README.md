# Redde

An iPhone, iPad and CarPlay client for [Hermes](https://github.com/NousResearch/hermes-agent), the
open-source AI agent you run on your own machine, or for any OpenAI-compatible model server. Talk or
type, watch the agent think and use its tools, approve what it wants to run, and manage its
sessions, projects, skills, cron jobs and Kanban board from your phone.

[App Store](https://apps.apple.com/app/id6810900557) · [Website](https://redde.goosehouse.org)

No account, no analytics, no cloud of its own: every request goes only to the server you set up,
speech is recognized on the device, and credentials stay in the iOS Keychain.

## Features

- **Voice first.** On-device speech recognition, replies spoken by the built-in voice or your own
  Kokoro server, hands-free mode, barge-in, AirPods and CarPlay.
- **Your language.** Listen in any language on-device transcription supports, hear each reply in a
  voice for the language it's written in, and ask the agent to always answer in one language.
- **Spoken prefixes.** Start a spoken message with a word of your choice and Redde adds a text
  prefix, switches the conversation to a model you pick, or both. Voice and Siri only.
- **Watch it work.** Streaming reasoning, tool calls, subagents, and cards for approvals,
  clarifying questions, sudo prompts and secrets, also answerable from a notification.
- **Rich replies.** Markdown, highlighted code, tables, task lists, Mermaid diagrams and math,
  rendered offline with no third-party Swift dependencies.
- **Write it your way.** A draft for each conversation, pictures pasted or dropped in, files and
  video, dictation into the message field, a page of its own for a long message, and a Return
  key that sends if you want it to.
- **The whole agent.** The shared session ledger, projects, several servers and Hermes profiles,
  skills and toolsets, memory and context files, cron jobs and the Kanban board.
- **Set up by code.** Scan a QR code or open a setup link and the connection fills itself in. A
  device that is set up can show the code for the next one.
- **Everywhere on iOS.** Siri and Shortcuts, the Action Button, Control Center, widgets, a Live
  Activity, the share sheet, the camera, and Siri AI messaging on iOS 27 (opt-in).
- **Private.** An offline message queue, Face ID lock, and nothing collected.

## Requirements

- iOS 26 or later (Siri AI features need iOS 27).
- A backend, reached by one of three connections:

| Connection | Server | Best for |
| --- | --- | --- |
| **Hermes Dashboard** | `hermes serve` (port 9119), dashboard username and password, or a browser sign-in | Everything: live reasoning, approvals, slash commands, projects, Kanban, file editing |
| **Hermes API** | The Hermes gateway's API server (port 8642), `API_SERVER_KEY` | The shared session ledger with a single key |
| **OpenAI-compatible** | llama.cpp, llama-swap, vLLM, Ollama or a hosted provider | Talking straight to a model, with no agent |

Profiles need Hermes 0.21 or later. Over the Hermes API a named profile also needs
`gateway.multiplex_profiles` and that profile's own `API_SERVER_KEY`.

A Dashboard that signs you in with Google or another identity provider has no password to type:
tap **Sign in with a browser** (Hermes 0.21 or later). A server behind a reverse proxy that asks
for a header of its own takes it under Settings → Connection details → Custom headers, next to
the Cloudflare Access service token.

## Setup codes

Instead of typing an address and a key on the phone, hand Redde a setup code: a link, or a QR code
of it.

```sh
scripts/setup-code.py --name Home --dashboard http://hermes.home.example:9119 --user redde
```

The script asks for the password without showing it and prints the link, plus its QR code when
[`qrencode`](https://fukuchi.org/works/qrencode/) is installed. In Redde's setup screen choose
**Scan a setup code** or **Paste a setup link**; the iPhone Camera opens the code too, and so does
tapping the link in Messages or Mail. Redde shows what the code sets and where it points, and
saves nothing until you agree. It never overwrites a server that is already set up: the code is
added beside it.

Once one device is set up, Settings › Connection › **Set up another device** shows its code.
Passwords and keys are left out until you ask for them, which takes Face ID or the passcode.

The link is `https://redde.goosehouse.org/connect#` followed by any of these, percent-encoded:

| Parameter | Meaning |
| --- | --- |
| `name` | What the server is called in Redde |
| `dashboard`, `user`, `password` | Hermes Dashboard address and login |
| `api`, `key` | Hermes API server address and `API_SERVER_KEY` |
| `profile`, `profile-key` | A Hermes profile, and its own API key if it has one |
| `access-id`, `access-secret` | A Cloudflare Access service token |
| `model-url`, `model-key`, `model` | An OpenAI-compatible endpoint |
| `use` | `dashboard`, `api` or `model`: which connection Redde talks to (default: the first in the code) |

It is a web address so that iOS opens it in Redde wherever it is tapped (a universal link, which
no other app can claim), and so that a device without the app gets a page saying what to do. The
connection comes after the `#`, the part of an address a browser never sends, so the site doesn't
see it; the page is a static file ([`companion/website`](companion/website)) whose script only
hands the link to the app. To involve no website at all, use the app's own form, with the same
parameters after `redde://connect?` (`scripts/setup-code.py --app-link`).

A code with a password in it is as good as the password. Show it to your own devices, not in a
screenshot or a chat.

## Building

Requires Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
The Xcode project is generated and not committed.

```sh
xcodegen generate
open Echo.xcodeproj
```

The code name is Echo: targets, folders, the bundle ID (`com.goosehouse.echo`) and the app's own
`echo://` links keep it; everything a user sees says Redde, setup links (`redde://connect`) included.

To prefill your own servers in development builds, add a git-ignored
`Echo/Resources/LocalDefaults.json` with any of `transport`, `gatewayURL`, `serveURL`,
`serveUsername`, `fastLaneURL`, `fastLaneModel`, `kokoroURL`, `kokoroVoice`, `contextWindow`. It is
applied once on first launch and never ships.

### Tests

```sh
xcodebuild -project Echo.xcodeproj -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

Unit tests cover streaming and parsing, the transports, markdown, voice, profiles and automation.
Live tests run against the servers in `LocalDefaults.json` when they're reachable and skip otherwise.
The UI tests have a scheme of their own, `-scheme EchoUITests`; they drive the app in the simulator
on built-in demo conversations and need no server.
Debug builds accept launch flags for demos and screenshots, all listed in
[`Echo/App/DevHooks.swift`](Echo/App/DevHooks.swift).

## Repository

| Path | What's there |
| --- | --- |
| `Echo/` | The app: `App`, `Models`, `Services` (transports, voice, settings), `Views`, `Intents`, `CarPlay` |
| `Shared/` | Code shared with the extensions (attachments, widget snapshots, controls) |
| `EchoControls/`, `EchoShare/` | Widget and controls extension; share extension |
| `EchoTests/`, `EchoUITests/` | Tests |
| `companion/` | The website, the push-notification relay Worker and the Hermes plugin that feeds it, and a calendar MCP server for Hermes |
| `scripts/` | Setup codes, the build-number bump, the CarPlay simulator, and the Hermes lab for testing against stock gateways |
| `design/` | App Store screenshots and the scripts that make them, icon sources |
| `docs/` | [Architecture](docs/ARCHITECTURE.md), privacy policy, support page, App Store listing |

## Contributing

Pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md); first-time contributors sign the
[CLA](CLA.md) with a one-line comment when the bot asks. Report security problems privately, as
described in [SECURITY.md](SECURITY.md).

## License

[FSL-1.1-MIT](LICENSE.md), the Functional Source License. You can read, use, modify and self-host
Redde for any purpose except offering a competing commercial product. Each release becomes MIT on
its second anniversary.

The Redde name and app icons are not licensed for use in other products. Bundled third-party code
keeps its own license: KaTeX and Mermaid (MIT), KaTeX fonts (OFL).
