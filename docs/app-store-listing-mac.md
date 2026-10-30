# App Store listing — Hermes Redde for Mac

The Mac app's own version page in App Store Connect: the same App Store record as the iPhone and
iPad app (bundle id com.goosehouse.echo, one purchase for all three), platform macOS. Name,
subtitle, privacy label, categories, age rating and in-app purchases are the record's and shared;
what is here is what each platform's version holds of its own. Sent with
`scripts/app-store-push.py copy --mac` (and `screenshots --mac`, `notes --mac`). Character limits
are Apple's. Only what has been seen working on a Mac is claimed: chat, both Hermes connections,
the Dashboard sign-in, bots and group chats, the Hermes screens, iCloud sync, menus and text zoom.
Not claimed: voice mode, live voice, phone tools, notifications with Redde closed (the Mac has no
push yet), CarPlay, the Watch, Siri, wake phrases, calls, alarms, the terminal.

## Promotional text (170, editable without a new build)
New: Redde on the Mac, a native app for your Hermes agent. One purchase with iPhone and iPad, and your servers and settings follow you with iCloud.

## Keywords (100, comma-separated, no spaces after commas; don't repeat words from the name)
assistant,ai,agent,self-hosted,llm,ollama,bots,chat,private,openai,client,mac,macos,local,llama

## Description (4000)

Redde is a native Mac client for Hermes, the open-source AI agent. Type to your agent, watch it think and use tools, approve what it runs, and give it a crew: bots with faces of their own, alone or in group chats. It is the same Redde as on iPhone and iPad, one purchase for all three.

You bring the backend. Redde has no account and no analytics, and your conversations go only to your server.

BOTS
• Each Hermes profile is a bot with a face and a chat of its own. Start one from a template (Researcher, Writer, Coder, Home, Planner) and make its job, personality, model, face and tools your own.
• Type @ to hand work to another bot. Put two to six in a group chat and they answer in turn.
• Give a bot a schedule and its answer arrives in its chat.

SEE THE AGENT WORK
• Watch reasoning and tool calls live. The chat list shows what's working, what needs you and what's unread.
• Approve a risky command or answer the agent's question right in the chat.

A FULL CLIENT
• Chats live in your gateway's session ledger: start on the iPhone, continue on the Mac, the desktop or the CLI. Search them, pin, rename, fork, archive, or go incognito.
• Projects, scheduled jobs and the Kanban board, in the sidebar beside the conversation.
• Rich replies: Markdown, code, tables, Mermaid diagrams, math, and cards with maps, places and the weather. Pictures and PDFs open in place.
• Ask about part of a reply, regenerate, edit and resend, or switch models with /model.
• Attach pictures and files, or paste them.
• Skills, tools, plugins, memory and context files; on the server, MCP servers, logs, updates and files.
• Menus and keyboard shortcuts for the conversation, and text zoom (⌘+, ⌘−, ⌘0).

YOUR BACKEND, YOUR RULES
• Connect to Hermes through the Hermes Dashboard or the Hermes API, on your LAN, over a tailnet, or behind Cloudflare Access, Pangolin or a reverse proxy. Save several servers and see all their chats in one list. Sign in with a password or a browser.
• Or go straight to any OpenAI-compatible endpoint: llama.cpp, llama-swap, vLLM or Ollama on your hardware, or a hosted provider with your key.
• Set up from a setup link made on your iPhone, or turn on Sync with iCloud and your servers and settings come over, keys through iCloud Keychain, end-to-end encrypted.
• Credentials stay in the Keychain. Touch ID lock, seven themes with your own colors.

REQUIRES
A Hermes agent (github.com/NousResearch/hermes-agent) or an OpenAI-compatible endpoint; bots need Hermes. Redde includes no model and no AI service of its own. macOS 26.

Hermes is an open-source project by Nous Research. Redde is an independent client, not affiliated with it.

## What's New in 2.3.1 (4000)
Your agent, ahead of your day, and new cards.

• Ahead of your day. Turn them on in one step, in Settings → Agent → Ahead of Your Day: Morning Ideas to swipe, a Week Ahead, an Evening Wrap-up, and heads-ups before events. They take the Redde plugin 1.10 on your Hermes.
• Your day as a timeline. Ask what's on your calendar and the answer is a card: your events to scale, free time marked. Click an empty spot to start a message that adds one. Pick which calendars your agent looks at, and one color for every event if you like.
• New answer cards: the weather by the hour, places on a map with hours and walks, an email to check before it goes, and a checklist to tick.
• Approvals in plain words: before your agent runs something, the card says what it deletes, in red, and what it changes.
• Leave-By Alerts: while Redde is open, it looks at your calendar and Apple Maps and tells you when to leave.
• Current Location: your agent hears roughly where you are, only when you ask about places, directions or the weather.
• Keys asked for: when your agent needs an API key, it asks in Redde, and what you paste goes sealed to your server.
• Settings is a window of its own, with the back button where you expect it, and sections open from anywhere on their row. Text zoom reaches the sidebar too.

## Before submitting the Mac's 2.3.1
- The Mac's 2.3 (279) released first: App Store Connect makes no new macOS version while 2.3 waits.
- Try on the Mac first (none of this has run on a Mac yet, only built): the calendar timeline and click-to-add line, the new cards, Current Location's permission and answer, Leave-By Alerts with Calendar access and a notification, the Settings window and its sections, Keys Asked For.
- `scripts/app-store-push.py copy --mac`, then `notes --mac` (the notes gain location and calendar uses).

## What's New in 2.3 (4000)

## Before submitting the Mac's 2.3
- In App Store Connect, Hermes Redde → Add Platform → macOS, if `copy --mac` can't make the version itself (the API may want the platform added first).
- Try on a Mac with the App Store build (TestFlight): sign in on both connections, a bot chat, a group chat, an attachment, Settings → iCloud. Voice mode and phone tools are in the app but untried on a Mac: try them or say nothing of them (as here).
- Once the Mac app is on sale, the iPad app no longer appears in the Mac App Store for Apple silicon Macs: the Mac gets this one (one bundle id).
