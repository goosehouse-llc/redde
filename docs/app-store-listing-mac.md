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

## What's New in 2.3 (4000)

## Before submitting the Mac's 2.3
- In App Store Connect, Hermes Redde → Add Platform → macOS, if `copy --mac` can't make the version itself (the API may want the platform added first).
- Try on a Mac with the App Store build (TestFlight): sign in on both connections, a bot chat, a group chat, an attachment, Settings → iCloud. Voice mode and phone tools are in the app but untried on a Mac: try them or say nothing of them (as here).
- Once the Mac app is on sale, the iPad app no longer appears in the Mac App Store for Apple silicon Macs: the Mac gets this one (one bundle id).
