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
- **Watch it work.** Streaming reasoning, tool calls, subagents, and cards for approvals,
  clarifying questions, sudo prompts and secrets, also answerable from a notification.
- **Rich replies.** Markdown, highlighted code, tables, task lists, Mermaid diagrams and math,
  rendered offline with no third-party Swift dependencies.
- **The whole agent.** The shared session ledger, projects, several servers and Hermes profiles,
  skills and toolsets, memory and context files, cron jobs and the Kanban board.
- **Everywhere on iOS.** Siri and Shortcuts, the Action Button, Control Center, widgets, a Live
  Activity, the share sheet, and Siri AI messaging on iOS 27 (opt-in).
- **Private.** An offline message queue, Face ID lock, and nothing collected.

## Requirements

- iOS 26 or later (Siri AI features need iOS 27).
- A backend, reached by one of three connections:

| Connection | Server | Best for |
| --- | --- | --- |
| **Hermes Dashboard** | `hermes serve` (port 9119), dashboard username and password | Everything: live reasoning, approvals, slash commands, projects, Kanban, file editing |
| **Hermes API** | The Hermes gateway's API server (port 8642), `API_SERVER_KEY` | The shared session ledger with a single key |
| **OpenAI-compatible** | llama.cpp, llama-swap, vLLM, Ollama or a hosted provider | Talking straight to a model, with no agent |

Profiles need Hermes 0.21 or later. Over the Hermes API a named profile also needs
`gateway.multiplex_profiles` and that profile's own `API_SERVER_KEY`.

## Building

Requires Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
The Xcode project is generated and not committed.

```sh
xcodegen generate
open Echo.xcodeproj
```

The code name is Echo: targets, folders, the bundle ID (`com.goosehouse.echo`) and the `echo://` URL
scheme keep it; everything a user sees says Redde.

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
Debug builds accept launch flags for demos and screenshots, all listed in
[`Echo/App/DevHooks.swift`](Echo/App/DevHooks.swift).

## Repository

| Path | What's there |
| --- | --- |
| `Echo/` | The app: `App`, `Models`, `Services` (transports, voice, settings), `Views`, `Intents`, `CarPlay` |
| `Shared/` | Code shared with the extensions (attachments, widget snapshots, controls) |
| `EchoControls/`, `EchoShare/` | Widget and controls extension; share extension |
| `EchoTests/`, `EchoUITests/` | Tests |
| `companion/` | The website, the push-notification relay Worker, and a calendar MCP server for Hermes |
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
