# App Store listing — Redde for Hermes

Character limits are Apple's. Everything here describes shipped, verified behaviour.

## Name (30)
Redde for Hermes

## Subtitle (30)
Talk, chat and run your agent

## Promotional text (170, editable without a new build)
New: Hermes profiles. Pick which agent Redde talks to, and its chats, skills and memory come with it. Talk to your own agent at home, at your desk or in the car.

## Keywords (100, comma-separated, no spaces after commas; don't repeat words from the name)
voice,assistant,ai,agent,carplay,self-hosted,llm,ollama,llama,chat,siri,shortcuts,private,openai

## Description (4000)

Redde is a complete iPhone and iPad client for Hermes, the open-source AI agent. Talk to it or type, watch it think and use tools, approve what it wants to run, and manage everything it does: sessions, projects, profiles, scheduled jobs, and the Kanban board. It also talks straight to any OpenAI-compatible model server, local or hosted, when you just want a fast answer.

You bring the backend. Redde has no account, no analytics, and no cloud of its own; every request goes only to the server you configured.

TALK, DON'T TYPE
• Tap the mic, ask, hear the answer. Speech recognition runs on your iPhone; the reply is spoken back with the built-in voice or your own Kokoro server.
• Hands-free mode keeps the conversation going until you say "that's all".
• Interrupt Redde mid-answer: tap the mic to cut in, or type while it's still replying to steer where it goes.
• In CarPlay, ask through the car's microphone and hear the answer through its speakers. Nothing to read while you drive.
• "Hey Siri, ask Redde…" works from the Lock Screen and with AirPods. A Control Center button and Lock Screen widget open Redde listening.
• On iOS 27, Siri can message your agent in your own words and read the reply back (opt-in).
• A voice orb that moves with your voice and Redde's. Pause, replay, or have any reply read aloud.
• Hold the phone to your ear to hear replies like a call.
• Use "Ask Redde a Question" in Shortcuts to get the answer back as text for your own automations.

SEE THE AGENT WORK
• Watch reasoning as it streams, with tool calls shown as they happen.
• Approve or deny a risky command from a notification, and answer the agent's questions without opening the app.
• Answer a sudo prompt or supply a missing secret from your phone.
• Delegated subagents appear as their own rows; tap one to follow its transcript live, steer it, or stop it.
• A Live Activity shows progress.

A FULL CLIENT, NOT JUST A MIC
• Every conversation lives in your gateway's session ledger, so what you start on the phone continues on the desktop, Telegram, or the CLI. Search, pin, rename, fork, archive.
• Sessions grouped by project. Scheduled jobs (cron) with delivery targets and prebuilt blueprints. The Kanban board, live.
• Rich replies: Markdown, highlighted code, tables, task lists, images, Mermaid diagrams you can zoom, and math.
• Pictures and files from the agent arrive in the chat ready to view: camera snapshots, charts, PDFs.
• Regenerate an answer, edit and resend a question, or search a long conversation.
• Attach photos and files; export conversations as Markdown.
• Share to Redde from any app: text, links, photos or files land in the composer, ready to send.
• Home Screen widgets show the last answer or start listening; the Action Button can open Redde listening.
• Switch models mid-conversation from the chat header or with /model.
• Skills and tool sets, on or off. Edit the agent's memory and context files in place.
• Create and edit skills, or describe one and let Redde draft it.

YOUR BACKEND, YOUR RULES
• Connect to Hermes through the Hermes Dashboard or the Hermes API, on your LAN, over a tailnet, or behind Cloudflare Access.
• Or skip the agent and go straight to any OpenAI-compatible endpoint: llama.cpp, llama-swap, vLLM, Ollama on your own hardware, or a hosted provider with your API key.
• Credentials stay in the Keychain. Speech recognition runs on the phone.
• Face ID lock, seven themes with your own accent and bubble colors, a choice of app icons and voice orbs, iPad split view, keyboard shortcuts.
• No account. No analytics. No tracking. The privacy label says "Data Not Collected" because that is what happens.

REQUIRES
A Hermes agent (github.com/NousResearch/hermes-agent) or an OpenAI-compatible endpoint, self-hosted or from a provider. Redde does not include a model or a hosted service.

Hermes is an open-source project by Nous Research. Redde is an independent client and is not affiliated with Nous Research.

## What's New in 1.4 (4000)
Several Hermes servers in one app.

• Save more than one Hermes server, say Home and Office, and switch between them from Settings or the server row at the top of your conversations. Each keeps its own addresses, keys, profile and model.
• Switching starts a fresh conversation, and your conversations, cron jobs and Kanban board follow the server you pick.
• Your existing setup becomes your first server when you update, keys and all.
• If the profile you picked no longer exists on the server, Redde says so and takes you to choose another.
• Take a photo right from the message field: tap + and choose Camera.
• Reasoning effort now goes past High to X-High and Max, for frontier models such as Claude and GPT.
• Long answers: the live thinking keeps scrolling, each reply shows how long it took in total, and the screen no longer goes dark while you wait in voice mode.

## What's New in 1.3 (4000)
Hermes profiles, clearer settings, and a round of fixes.

• Hermes profiles: pick which profile Redde talks to, right under Name in Settings. Chats, projects, skills, tools, cron jobs and memory all follow it, and the conversation list refreshes when you switch.
• On the Hermes API, each profile can have its own API key, entered on the same screen. If a key is wrong or the gateway doesn't serve that profile, Redde tells you how to fix it.
• Clearer connection names: Hermes Dashboard, Hermes API and OpenAI-compatible, now under Settings → Connection, with the Dashboard listed first.
• With only the Hermes API set up, Settings now explains why the context and memory files are locked, and takes you straight to adding your Dashboard login.
• The Kanban board's column bar now shows every time, and the selected column is easier to read.
• On iPad, Chats, Cron and Kanban get a row of their own in the sidebar instead of being cut off.

## What's New in 1.2 (4000)
A calmer, cleaner Redde.

• A new look: replies sit on the page under your agent's name, with its thinking and tools as small tags and copy, read aloud and retry right beneath. Long jobs show their steps as they run.
• Voice mode, redesigned: an orb at the top that moves with your voice while it listens and with Redde's while it answers. Pause an answer and resume it, replay it through the speaker, and stop or leave with one button.
• Choose from 25 voice orbs, including waveforms, glass and matte finishes, and speech bubbles.
• A new app icon, plus a picker with 12 more in Settings.
• Pick your own accent and bubble colors for each theme.
• On iOS 27, Siri can message your agent in your own words and read the reply back. Off until you turn it on in Settings.
• Start voice mode hands-free by default, or not: your choice in Settings.
• Clearer help when Redde can't reach your server, with the fix one tap away.
• Conversations grouped by day, with search always at hand.
• CarPlay gets the new look.
• Quicker first answers with llama-swap: if it has unloaded your model, Redde has it load again the moment you start a conversation or connect to your car.

## What's New in 1.1 (4000)
Redde is now in CarPlay. Open it on your car's screen, tap Ask Redde or Talk with Redde, and talk to your agent through the car's microphone and speakers. Answers are spoken, never shown, so your eyes stay on the road.

Also in 1.1:
• Pictures and files from your agent land right in the chat: camera snapshots, charts and PDFs arrive like messages, not file paths.
• Switch models mid-conversation: tap the model name in the chat header or type /model.
• Three new themes — Terminal, Amber CRT and Hermes. Terminal turns your messages into shell prompts.
• Tones tell you when the mic opens and closes, and messages queue up while a reply is streaming or you're offline.
• Smooth scrolling through long conversations, runnable commands in copyable code blocks, and AirPods high-quality microphone support.
• Readable diagrams: wide ones scroll sideways, and a tap opens them full screen with pinch to zoom.
• A new app icon, a refreshed setup screen, and Siri, widgets, notifications and the Live Activity all say Redde.

## What's New in 1.0
First release.

## Review notes
See `app-review-notes.md` (backend key for the reviewer, transport to select, what to expect).

## Categories
Primary: Productivity. Secondary: Utilities.

## Age rating
4+ (no flagged content; unrestricted web access is not offered).

## URLs
Privacy: https://legal.goosehouse.org/redde/privacy
Support: https://legal.goosehouse.org/redde/support
Marketing: https://redde.goosehouse.org

## Copyright
© 2026 Goosehouse LLC
