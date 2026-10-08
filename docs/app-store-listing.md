# App Store listing — Redde for Hermes

Character limits are Apple's. Everything here describes shipped, verified behaviour.

## Name (30)
Redde for Hermes

## Subtitle (30)
Talk, chat and run your agent

## Promotional text (170, editable without a new build)
New: notifications when Redde is closed, replies you can talk over, and your recent chats in CarPlay. Talk to your own agent at home, at your desk or in the car.

## Keywords (100, comma-separated, no spaces after commas; don't repeat words from the name)
voice,assistant,ai,agent,carplay,self-hosted,llm,ollama,llama,watch,siri,shortcuts,private,openai

## Description (4000)

Redde is a complete iPhone and iPad client for Hermes, the open-source AI agent, with CarPlay and an Apple Watch app. Talk to it or type, watch it think and use tools, approve what it wants to run, and manage everything it does: sessions, projects, profiles, scheduled jobs, and the Kanban board. It also talks straight to any OpenAI-compatible model server when you just want a fast answer.

You bring the backend. Redde has no account and no analytics, and your conversations go only to the server you configured.

TALK, DON'T TYPE
• Tap the mic, ask, hear the answer. Speech is recognized on your iPhone; the reply is spoken with the built-in voice or your own Kokoro server.
• Hands-free mode keeps the conversation going until you say "that's all".
• Interrupt mid-answer: just start talking, tap the mic, or type to steer the reply.
• In CarPlay, ask through the car's mic and speakers, in a new chat or a recent one. On Apple Watch, raise your wrist and ask.
• "Hey Siri, ask Redde…" works from the Lock Screen and AirPods. A Control Center button, a widget or the Action Button starts listening.
• On iOS 27, Siri can message your agent in your own words and read the reply back (opt-in).
• A voice orb moves with your voice and Redde's. Pause, replay, or have any reply read aloud.
• Spoken prefixes: start with a word you chose and Redde adds a text prefix or switches model. "Opus, review this diff" moves the chat to Opus.
• "Ask Redde a Question" in Shortcuts returns the answer as text.

SEE THE AGENT WORK
• Watch reasoning stream, with tool calls as they happen and a Live Activity for progress. Open a step to see what it returned.
• Lock the phone or switch apps: the reply carries on.
• Approve a risky command or answer the agent's question from a notification. Pair your Hermes and they arrive even when Redde is closed, encrypted end to end.
• Subagents get their own rows; tap one to follow, steer or stop it.

A FULL CLIENT, NOT JUST A MIC
• Conversations live in your gateway's session ledger: start on the phone, continue on the desktop, Telegram or the CLI. Search, pin, rename, fork, archive.
• Sessions by project, scheduled jobs with delivery targets and blueprints, and the Kanban board, live.
• Rich replies: Markdown, code, tables, task lists, zoomable Mermaid diagrams and math, at a text size you choose. Pictures, charts and PDFs from the agent open in place.
• Select part of a reply and ask about it. Regenerate, edit and resend, or search a long chat.
• Attach photos, videos and files, paste or drop them in, or dictate. Every chat keeps its draft. Mention a day and attach its calendar in one tap.
• Share text, links, photos or files to Redde from any app. Export chats as Markdown.
• A widget shows the last answer.
• Switch models mid-chat from the header or with /model.
• Skills and tool sets, on or off. Edit the agent's memory and context files, and create skills or let Redde draft one.

YOUR BACKEND, YOUR RULES
• Connect to Hermes through the Hermes Dashboard or the Hermes API, on your LAN, over a tailnet, or behind Cloudflare Access or a reverse proxy. Save several servers.
• Sign in to the Dashboard with a password, or in a browser with Google or another provider.
• Or go straight to any OpenAI-compatible endpoint: llama.cpp, llama-swap, vLLM or Ollama on your hardware, or a hosted provider with your key.
• Set up by scanning a QR code or opening a link, and pass it on to your other devices. Credentials stay in the Keychain.
• Face ID lock, seven themes with your own colors, app icons and voice orbs, iPad split view, keyboard shortcuts.
• No account, no analytics, no tracking. The one service we run is an optional relay for notifications, which it can't read.

REQUIRES
A Hermes agent (github.com/NousResearch/hermes-agent) or an OpenAI-compatible endpoint. Redde includes no model and no AI service of its own.

Hermes is an open-source project by Nous Research. Redde is an independent client, not affiliated with it.

## Header and Search Results (pictures, optional)
Two pictures App Store Connect has taken since October 2026, on the version page under Product Page Information → Header and Search Results. People on iOS 27 and later see them; without them the page and the search result look as before (screenshots in the search result). Both are in `design/screenshots/creative/`, made by `design/screenshots/creative.py`.

- Header (`header-3840x1646.png`, 21:9): "Type it. Or just say it." between two halves of a waveform. The top of the product page, above the icon and the name.
- Search results (`search-3840x2560.png`, 3:2): "Talk to your own AI agent. Voice and chat for Hermes." beside voice mode and a chat. Shown with the app in search in place of the first screenshots.

The words in both sit inside the "art safe area" of Apple's templates. Use Preview in App Store Connect before submitting: it shows each on iPhone and iPad, both ways up.

## What's New in 1.7 (4000)
Notifications when Redde is closed, replies you can talk over, more of your conversations in the car, and a better place to write.

• Notified when Redde is closed. iOS closes an app in the background within minutes, and until now Redde went quiet with it. Pair your Hermes in Settings → Voice → Notify when Redde is closed and it tells your iPhone itself: a reply is ready, a command waits for approval, the agent has a question or needs a password, a turn failed, a task it handed off came back. Approve, deny or answer from the notification. Notifications are encrypted between your Hermes and your iPhone, and the relay that carries them can't read them. It takes a small plugin on your Hermes; the screen shows the command that installs it. On the Hermes Dashboard, pairing is one tap.
• Talk over a reply. Start speaking while Redde is answering and it stops to listen. A cough or an "mm-hm" doesn't count. It is on with headphones from the start; Settings → Voice → Talk over replies adds the phone's speaker, and Interrupt with can make it only the word "stop", for a room where other people are talking. Not in the car.
• More in the car. CarPlay gains New Chat and Recent Chats, so you can start fresh or carry on an earlier conversation, and the voice card has Mute and End.
• Sign in with a browser. A Hermes Dashboard that signs you in with Google or another provider now works: Settings → Connection details → Sign in with a browser.
• Custom headers. A server behind a reverse proxy that asks for a header of its own can be sent it, in Settings → Connection details. Setup codes carry them too.
• A draft for every conversation. What you typed and didn't send stays with its conversation, also after Redde has been closed, and the list marks it Draft.
• More ways to write. Dictate into the message field with the mic beside it, paste a picture, and open a long message on a page of its own. Over the Hermes Dashboard you can attach a video; a long one is made smaller first. Return can send, if you choose that in Settings → Writing.
• Easier reading. Chat text size, in Settings → Appearance, sets conversations larger or smaller than the rest of the iPhone. A ring in the header shows how full the model's context is. When your server can't be reached, the conversations this iPhone has opened can still be read.
• Answer from the Lock Screen and the wrist. A command waiting for approval takes over the Live Activity, with Approve and Deny, and a finished reply's notification takes your next message. On Apple Watch, approvals and questions come to the wrist, and a watch whose iPhone uses the Hermes Dashboard now asks through the iPhone.
• One conversation, its own way. In the model menu on the Hermes Dashboard: Fast mode for models that have a faster tier, and Run commands without asking for the one conversation where you trust what the agent is doing. A bolt in the header shows while it is on. Touch and hold a conversation in the list to move it to a project.
• Your server, from the phone. Settings → Gateway shows what your Hermes is running and connected to, switches its MCP servers on and off and tests them, reads its logs, and restarts or updates Hermes. It needs the Hermes Dashboard login.
• A switch for the notification sound, in Settings → Voice.
• Fixes. Over the Dashboard on Hermes 0.21.3 and later, a command that needed approval was refused without asking and the agent's questions went unanswered: they reach you again. A file attached over the Dashboard now reaches the agent.

## Before submitting 1.7
Written ahead of the release, so unlike the rest of this page not all of it has been seen on a device yet.

In App Store Connect and on the web:
- The privacy policy and the support page as they are in `docs/` have to be published. On 2026-10-08 legal.goosehouse.org still served the policy of September 27, which says Goosehouse receives nothing and lacks even 1.6's paragraphs on setup links and scanning a code.
- Review notes from `app-review-notes.md`, with the key put in.
- The first archive with the notification extension (`com.goosehouse.echo.push`): Xcode's automatic signing has to make its App Store profile, with the app group.
- The Hermes plugin people install is whatever is on the main branch of the public repository, so the plugin that goes with this build has to be pushed before the release (it is, as 1.1.0).

On devices, to check first:
- Notifications with Redde closed, against a real Hermes with the plugin at 1.1.0: a reply and an approval arrive with their text, Approve and Deny answer, a question shows its choices as buttons and takes a typed answer, a failed turn says why. With Notification sound off they arrive silent. None of this can be seen in the simulator, where a simulated push skips the notification extension.
- CarPlay on a car's screen or the CarPlay Simulator: the four rows, Recent Chats, Mute and End. They have only been pressed by tests.
- Sign in with a browser against a Dashboard that uses a real identity provider (tried against Hermes's own username-and-password page), and custom headers through a real reverse proxy.
- Talk over replies beyond what was tried (an iPhone 15 Pro Max on its speaker and with AirPods): the earpiece, another phone, a reply several minutes long, only "stop" on headphones.
- Dictation into the message field with a real voice, a picture pasted on a device, and a video picked from Photos.
- Approve on the Live Activity behind an unlock, and on a real watch: approvals and questions on the wrist, and asking through the iPhone.
- Approvals over the Dashboard against a real Hermes 0.21.3 or later (checked against the lab's).
- The model menu's switches and Move to Project against a real server. The lab covered running without asking (a command then runs unasked, and is asked about again when it is off) and the move, on Hermes 0.21.0, 0.21.3 and 0.21.5. Fast mode has only ever been refused: turning it on takes an OpenAI, Anthropic or xAI model, which the lab doesn't have.
- Settings → Gateway against a real server. The lab covered the status, MCP servers, logs, the update check and a restart of a gateway started by hand, on Hermes 0.21.0, 0.21.3 and 0.21.5. Not covered anywhere: a restart where a service manager (launchd, systemd) runs the gateway, which is how most servers are set up, and applying an update, which has never been run for real.

## App Privacy (App Store Connect → App Privacy)
"Data Not Collected", unchanged in 1.7 (decided 2026-10-08, with the notification relay in view).

What that decision weighed: the optional relay keeps a paired iPhone's push token, the hash of a secret and the time of its last check-in, for as long as the pairing lasts and at most 120 days after the iPhone last checked in (`docs/push.md`, "What is where"). It has no account and nothing that says who the person is, the notifications pass through it encrypted and are not kept, and conversations, credentials and everything else go only to the person's own server. The privacy policy describes the relay in full, and the review notes point the reviewer to it. If Apple asks for the token to be on the label, the entry would be Identifiers → Device ID, for App Functionality, not linked to the user and not used for tracking, with the same entry in `Echo/Resources/PrivacyInfo.xcprivacy`.

## Export compliance
`ITSAppUsesNonExemptEncryption` stays `false` (`project.yml`). Besides HTTPS, 1.7 encrypts and decrypts notifications (X25519, HKDF-SHA256, AES-256-GCM) and hashes for its browser sign-in (SHA-256, for PKCE). All of it is CryptoKit, Apple's implementation in the operating system; the app contains no cryptography of its own and none from a third party. App Store Connect asks for documentation when an app implements proprietary algorithms, or standard ones "instead of, or in addition to, using or accessing the encryption within Apple's operating system". Redde does neither, so the answer to "What type of encryption algorithms does your app implement?" is "None of the algorithms mentioned above", and with the key set to `false` the question isn't asked at upload.

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
