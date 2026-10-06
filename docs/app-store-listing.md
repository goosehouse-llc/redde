# App Store listing — Redde for Hermes

Character limits are Apple's. Everything here describes shipped, verified behaviour.

## Name (30)
Redde for Hermes

## Subtitle (30)
Talk, chat and run your agent

## Promotional text (170, editable without a new build)
New: Redde on Apple Watch, setup by QR code, and replies that carry on when the phone locks. Talk to your own agent at home, at your desk or in the car.

## Keywords (100, comma-separated, no spaces after commas; don't repeat words from the name)
voice,assistant,ai,agent,carplay,self-hosted,llm,ollama,llama,watch,siri,shortcuts,private,openai

## Description (4000)

Redde is a complete iPhone and iPad client for Hermes, the open-source AI agent, with CarPlay and an Apple Watch app. Talk to it or type, watch it think and use tools, approve what it wants to run, and manage everything it does: sessions, projects, profiles, scheduled jobs, and the Kanban board. It also talks straight to any OpenAI-compatible model server when you just want a fast answer.

You bring the backend. Redde has no account, no analytics, and no cloud of its own; every request goes only to the server you configured.

TALK, DON'T TYPE
• Tap the mic, ask, hear the answer. Speech recognition runs on your iPhone; the reply is spoken back with the built-in voice or your own Kokoro server.
• Hands-free mode keeps the conversation going until you say "that's all".
• Interrupt mid-answer: tap the mic to cut in, or type to steer the reply.
• In CarPlay, ask through the car's mic and hear the answer through its speakers. On Apple Watch, raise your wrist and ask.
• "Hey Siri, ask Redde…" works from the Lock Screen and AirPods. A Control Center button and Lock Screen widget open Redde listening.
• On iOS 27, Siri can message your agent in your own words and read the reply back (opt-in).
• A voice orb that moves with your voice and Redde's. Pause, replay, or have any reply read aloud.
• Spoken prefixes: start with a word you chose and Redde adds a text prefix or switches model. "Opus, review this diff" moves the chat to Opus.
• "Ask Redde a Question" in Shortcuts returns the answer as text for your automations.

SEE THE AGENT WORK
• Watch reasoning as it streams, with tool calls as they happen and a Live Activity for progress. Open a step to see what it returned.
• Lock the phone or switch apps and the reply carries on.
• Approve or deny a risky command, answer the agent's questions, a sudo prompt or a missing secret, all from a notification.
• Subagents get their own rows; tap one to follow its transcript, steer it, or stop it.

A FULL CLIENT, NOT JUST A MIC
• Every conversation lives in your gateway's session ledger: start on the phone, continue on the desktop, Telegram or the CLI. Search, pin, rename, fork, archive.
• Sessions grouped by project. Scheduled jobs with delivery targets and blueprints. The Kanban board, live.
• Rich replies: Markdown, highlighted code, tables, task lists, images, zoomable Mermaid diagrams, and math.
• Pictures and files from the agent arrive ready to view: snapshots, charts, PDFs.
• Select part of a reply and ask about it. Regenerate, edit and resend, or search a long chat.
• Attach photos and files, or drop them onto the chat. Mention a day and attach its calendar in one tap.
• Share to Redde from any app: text, links, photos or files land in the composer. Export chats as Markdown.
• Widgets show the last answer or start listening; the Action Button can open Redde listening.
• Switch models mid-conversation from the chat header or with /model.
• Skills and tool sets, on or off. Edit the agent's memory and context files in place, and create skills or let Redde draft one.

YOUR BACKEND, YOUR RULES
• Connect to Hermes through the Hermes Dashboard or the Hermes API, on your LAN, over a tailnet, or behind Cloudflare Access. Save several servers.
• Or go straight to any OpenAI-compatible endpoint: llama.cpp, llama-swap, vLLM, Ollama on your hardware, or a hosted provider with your key.
• Set up by scanning a QR code or opening a link, and pass it on to your other devices.
• Credentials stay in the Keychain.
• Face ID lock, seven themes with your own colors, app icons and voice orbs, iPad split view, keyboard shortcuts.
• No account, no analytics, no tracking. The privacy label says "Data Not Collected" because that is what happens.

REQUIRES
A Hermes agent (github.com/NousResearch/hermes-agent) or an OpenAI-compatible endpoint. Redde includes no model or hosted service.

Hermes is an open-source project by Nous Research; Redde is an independent client, not affiliated with Nous Research.

## Header and Search Results (pictures, optional)
Two pictures App Store Connect has taken since October 2026, on the version page under Product Page Information → Header and Search Results. People on iOS 27 and later see them; without them the page and the search result look as before (screenshots in the search result). Both are in `design/screenshots/creative/`, made by `design/screenshots/creative.py`.

- Header (`header-3840x1646.png`, 21:9): "Type it. Or just say it." between two halves of a waveform. The top of the product page, above the icon and the name.
- Search results (`search-3840x2560.png`, 3:2): "Talk to your own AI agent. Voice and chat for Hermes." beside voice mode and a chat. Shown with the app in search in place of the first screenshots.

The words in both sit inside the "art safe area" of Apple's templates. Use Preview in App Store Connect before submitting: it shows each on iPhone and iPad, both ways up.

## What's New in 1.6 (4000)
Redde comes to Apple Watch, sets itself up from a QR code, and keeps a reply going after the phone locks.

• Apple Watch. Raise your wrist, tap Ask and say it. The answer is shown and read aloud, through the watch or your AirPods, and Ask Redde can go on the Action button. The watch takes its connection from your iPhone and asks through the Hermes API or your OpenAI-compatible endpoint. If your phone uses the Hermes Dashboard, save the Hermes API address and key as well, in Settings → Connection details: the watch can't use the Dashboard.
• Set up by code. Scan a QR code, or open or paste a setup link, and the server's address and login fill themselves in. Redde shows what the code sets and saves nothing until you agree. To add an iPad or a second phone, open Settings → Connection → Set up another device and scan what it shows; passwords stay out of the code until you ask for them with Face ID.
• A reply keeps going. Lock the phone or switch apps and the reply you asked for carries on to the end.
• A place to start. A new conversation opens with a greeting and things to tap: what's next on your calendar, the conversation you just left, and what's on at home if your agent has Home Assistant.
• Ask about part of a reply. Choose Select text on a reply, select a sentence and tap Ask about this. It lands in your message as a quote.
• Follow-up questions. Turn on Suggest follow-up questions in Settings → Voice and three next questions appear after each reply, one tap to ask. Your OpenAI-compatible model writes them, so that connection has to be set up.
• The day's calendar, one tap away. Mention a day in your message and Redde offers that day's events to attach. Nothing is attached until you tap.
• Drop it in. Drag pictures, files, links or text onto a chat.
• Name your conversations. Rename, in the menu at the top of a chat.
• See what a tool did. Thinking and tool steps fold away under each reply; open a step to see what it was asked and what it returned.
• Long conversations, lighter. A long thread takes a fraction of the memory it did and stays smooth while a reply streams.
• Voice mode keeps the screen on while it listens and while it reads a reply.
• A livelier orb. Light moves inside the voice orb in three styles, Nebula, Aurora and Core, and there is a new Dark Glass orb. Settings → Voice orb.
• Small motions. Your message rises out of the field when you send it, pictures and diagrams open out of their thumbnails, a conversation opens out of its row, and Jump to latest shows a dot when something new is below.
• Fixes. The Live Activity no longer looks busy after a reply was cut off: it says the reply was interrupted, and clears when you open Redde. An open mic closes when the phone locks, unless you are hands-free or in the car.

## Before submitting 1.6
Written ahead of the release, so unlike the rest of this page not all of it has been seen on a device yet. To check first:
- Scanning a setup code with the camera (the simulator has none), and a setup link tapped in Messages on a phone.
- Dragging a picture or a file onto a chat from another app.
- The screen staying on in voice mode (the simulator never locks).
- Rename and a tool step's output against a real Hermes server; the calendar and Home cards with real data.
- The Apple Watch app on a real watch, asking through the Hermes API (the watch simulator allows connections a watch refuses, which is how the Dashboard route went untested). Its screenshots are in `design/screenshots/watch/`.

## What's New in 1.5 (4000)
Spoken prefixes that add text or switch the model, reasoning effort that reaches every model, and AirPods replies that stay in your AirPods.

• Spoken prefixes. Start a spoken message with a word of your choice ("Claude, …") and Redde swaps it for a text prefix, switches the conversation to a model you pick, or both, in voice mode and through Siri. Off until you add one, in Settings → Voice. Typed messages are never changed.
• Reasoning effort, everywhere. The level you pick in Settings → Model now applies to whatever model you talk to, and to the conversation you have open, not only to new ones. Type /reasoning high in a Hermes Dashboard chat and it changes that conversation too.
• None. A new level that asks the model to skip thinking and answer straight away. New installs start there. Some models and servers decide that for themselves.
• Replies through your AirPods. A question asked through AirPods sometimes got its answer from the phone's speaker. It stays in your ears now.
• A menu for effort. Seven levels no longer squeeze into one row.
• Lighter on the battery. Waiting for a reply and watching a model think take far less work, most of all in a long conversation.
• The model you pick is the model you get. On the Hermes API, a model from a second endpoint or provider now reaches it, and a provider your server has renamed or removed no longer stops the conversation.
• On a Mac. Opening voice mode no longer closes the app.

## What's New in 1.4 (4000)
More than one server, your own language, a quicker way around, and better voice replies.

• More than one Hermes server. Save Home, Office or any other server and switch from Settings or the row at the top of your conversations. Each keeps its own addresses, keys, profile and model, and your chats, cron jobs and Kanban board follow the server you pick. The setup you have now becomes your first server, keys and all.
• Your language. Pick a Reply language and Redde asks your assistant to answer in it, whatever language you write or speak in. Pick the language Redde listens for, and each reply is read by a voice for the language it's written in. Both are in Settings → Voice.
• Swipe to your conversations. On iPhone, swipe right on a chat and your conversation list slides in from the left.
• Room for your board. On iPad, pick Kanban or Cron in the sidebar and it fills the screen beside it.
• Choose where Redde opens: your last conversation, the conversation list or voice mode, in Settings → Voice. The conversation list also remembers whether you were on Chats, Cron or Kanban.
• A fresh start for voice. Turn on New conversation in voice mode, and opening voice mode from the app, Siri or the Action button starts a new conversation.
• Take a photo. Tap + beside the message field and choose Camera.
• More thinking. Reasoning effort now goes past High to X-High and Max, for frontier models such as Claude and GPT.
• Louder replies. Spoken replies play at full volume on the speaker, follow the volume buttons, and move to the earpiece when you raise the phone to your ear.
• Long answers, better. The live thinking keeps scrolling, each reply shows how long it took in total, and the screen stays on while you wait in voice mode. Replies from a model you run yourself (llama.cpp and other OpenAI-compatible servers) are no longer cut off after 10 minutes, and if the phone locks mid-reply, Redde tells you why it stopped.
• Feed the goose. Settings → About → Support Redde lets you leave a one-time tip: a coffee, a snack or a dinner. It unlocks nothing; every feature is already yours.
• Rate Redde. A link to the App Store review page, in Settings → About.
• Fixes. Chats opened over the Hermes API load again, clearer messages when a profile is gone from a server, Kokoro keeps talking when you switch to headphones or a car, readable buttons in every theme, a tidier message field, and many smaller fixes.

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
