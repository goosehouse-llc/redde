# App Store listing — Redde for Hermes

Character limits are Apple's. Everything here describes shipped, verified behaviour.

## Name (30)
Redde for Hermes

## Subtitle (30)
Talk, chat and run your agent

## Promotional text (170, editable without a new build)
New in 2.0: bots. Give each of your Hermes agents a face, a voice and a job, put them in a group chat, and talk with the whole crew, hands-free.

## Keywords (100, comma-separated, no spaces after commas; don't repeat words from the name)
voice,assistant,ai,agent,carplay,self-hosted,llm,ollama,bots,watch,siri,shortcuts,private,openai

## Description (4000)

Redde is a complete iPhone and iPad client for Hermes, the open-source AI agent, with CarPlay and an Apple Watch app. Talk or type, watch it think and use tools, approve what it runs, and give it a crew: bots with faces and voices of their own, alone or in group chats.

You bring the backend. Redde has no account and no analytics, and your conversations go only to the server you configured.

BOTS
• Each Hermes profile is a bot with a face, a voice and a chat of its own. Start one from a template (Researcher, Writer, Coder, Home, Planner) and make its job, personality, model, face and tools your own.
• Type @ to hand work to another bot. Put two to six in a group chat and they answer in turn; talk to the room and each answers in its own voice.
• Give a bot a schedule and its answer arrives in its chat, with a notification, even with Redde closed. Mute any chat for a while.
• Ask a bot from Siri, CarPlay, the Apple Watch or a spoken word.

TALK, DON'T TYPE
• Tap the mic, ask, hear the answer, or show it what the camera sees. Speech is recognized on your iPhone; the reply is spoken by the built-in voice, a Kokoro server or your Hermes.
• Hands-free mode keeps the conversation going until you say "that's all". Talk over an answer, or type, to steer it.
• In CarPlay, ask through the car's mic and speakers, in a new chat, a recent one or a bot's. On Apple Watch, raise your wrist and ask.
• "Hey Siri, ask Redde…" works from the Lock Screen and AirPods. A Control Center button, a widget or the Action Button starts listening.
• Spoken prefixes: a word you chose adds a text prefix, switches model or goes to a bot: "Opus, review this diff".
• Siri takes a note for your agent; Shortcuts can ask and get the answer as text.

SEE THE AGENT WORK
• Watch reasoning and tool calls live, with a Live Activity for progress; lock the phone or leave the chat and the reply carries on.
• The list shows what's working, what needs you and what's unread.
• Approve a risky command or answer the agent's question from a notification, out loud, or with a nod in AirPods. Pair your Hermes and notifications arrive with Redde closed, encrypted end to end.

A FULL CLIENT, NOT JUST A MIC
• Conversations live in your gateway's session ledger: start on the phone, continue on the desktop, Telegram or the CLI. Search inside them, pin, rename, fork, archive, or go incognito.
• Projects, scheduled jobs and the Kanban board.
• Phone tools: your agent can use your iPhone's calendar, reminders, contacts, photos and files, set alarms, write on a widget, and start calls and texts, each only if you allow it.
• Rich replies: Markdown, code, tables, task lists, Mermaid diagrams and math. Pictures, charts, PDFs and audio open in place.
• Select part of a reply and ask about it. Regenerate, edit and resend, or switch models with /model.
• Attach photos, videos, files or a day's calendar; share to Redde from any app.
• Skills, tool sets, memory and context files. The server too: MCP servers, logs, restart, update, files and an SSH terminal.

YOUR BACKEND, YOUR RULES
• Connect to Hermes through the Hermes Dashboard or the Hermes API, on your LAN, over a tailnet, or behind Cloudflare Access or a reverse proxy. Save several servers and sync them with iCloud. Sign in with a password or a browser.
• Or go straight to any OpenAI-compatible endpoint: llama.cpp, llama-swap, vLLM or Ollama on your hardware, or a hosted provider with your key.
• Set up by QR code or link. Credentials stay in the Keychain.
• Face ID lock, seven themes with your own colors, app icons and voice orbs, iPad split view, keyboard shortcuts.
• The one service we run is an optional relay for notifications, which can't read them.

REQUIRES
A Hermes agent (github.com/NousResearch/hermes-agent) or an OpenAI-compatible endpoint; bots need Hermes. Redde includes no model and no AI service of its own.

Hermes is an open-source project by Nous Research. Redde is an independent client, not affiliated with it.

## Header and Search Results (pictures, optional)
Two pictures App Store Connect has taken since October 2026, on the version page under Product Page Information → Header and Search Results. People on iOS 27 and later see them; without them the page and the search result look as before (screenshots in the search result). Both are in `design/screenshots/creative/`, made by `design/screenshots/creative.py`.

- Header (`header-3840x1646.png`, 21:9): "Type it. Or just say it." between two halves of a waveform. The top of the product page, above the icon and the name.
- Search results (`search-3840x2560.png`, 3:2): "Talk to your own AI agent. Voice and chat for Hermes." beside voice mode and a chat. Shown with the app in search in place of the first screenshots.

The words in both sit inside the "art safe area" of Apple's templates. Use Preview in App Store Connect before submitting: it shows each on iPhone and iPad, both ways up.

## What's New in 2.0 (4000)
Bots: a crew for your agent. Each Hermes profile is now a bot, with a face, a voice and a chat of its own, and bots can work together in group chats.

• Bots. Under Bots in the conversation list, each profile on your Hermes has a chat of its own. New Bot starts from Blank or a template (Researcher, Writer, Coder, Home, Planner) and fills in its name, job, personality, face and tools, all yours to change. Edit Bot changes them later, Hide puts one away and Reorder Bots sets their order. Type @ in a bot's chat to hand work to another; what bots send each other reads as theirs.
• Faces. Each bot is a little creature of its own. Change Face picks its shape, eyes, mouth, mark and color, kept on your server for every Redde there.
• Group chats. New Group Chat puts two to six bots in a room your Hermes runs: they answer in turn, or only the one you tag. Replies show as they are written, files and pictures go with your messages, and a reply that stopped partway can be retried. Hermes Desktop's rooms are listed too, to read.
• Talk to the whole crew. Talk in a group chat opens the voice screen on the room. The bots answer one after another, each read as it writes, in a voice of its own, its face up while it speaks.
• A voice for each bot, from your Kokoro server or your iPhone's voices. Voice… picks another.
• Schedules. Schedules… gives a bot something to do at a time: every day, on weekdays, on some days, every few hours, or once. Its answer comes into its chat, and with your Hermes paired a notification comes too, even with Redde closed.
• Notifications and mute. A paired phone hears from group chats: each bot's message, and a bot waiting on you, with Reply, Approve and Deny. Mute… quiets a bot's chat or a group chat for an hour, eight hours, until morning, or until you turn it back on.
• Bots wherever you ask. "Hey Siri, ask Home in Redde" opens Home's chat and listens. CarPlay has a Bots tab, the Apple Watch a Bots section, and a spoken prefix can go to a bot: "Home, turn off the porch light."
• On either connection. Bots, their faces and group chats come with the Hermes Dashboard's login, on the Dashboard or the Hermes API connection. With the Hermes API alone, Add Bot adds a profile by its name.
• Redde has a face. The new app icon is Redde's own face, and so is the voice orb: it blinks, looks at you while you talk and speaks with the reply. An icon or orb you picked stays.
• Incognito chats. New Incognito Chat is kept nowhere: not on the phone, in notifications or in widgets, and it is deleted from your server when you leave it. Your agent is asked to save nothing from it.
• Sync with iCloud. Settings → iCloud → Sync with iCloud brings your servers, their keys and your settings to your other iPhones, iPads and Macs. Keys and passwords go in iCloud Keychain, end-to-end encrypted. Off until you turn it on.
• At a glance. The conversation list shows a spinner while your agent works, Needs you while it waits on you, and a dot for a reply you haven't seen, with Mark as Read and Mark as Unread.
• The Hermes API, further. A reply now runs on your server and carries on when you leave the chat or lock the phone; it is there when you come back. Fast mode works there too, and with the Dashboard's login, subagent transcripts and files.
• Kanban and projects. View Changes shows a card's attached change, and Ask to Apply It has your agent put it in place. Add to Project is in a conversation's ••• menu.
• Fixes. A reply read by Kokoro or your Hermes no longer goes on in two voices (GitHub issue 11). A card's question, a share or a Siri draft can start a new conversation (issue 21). A noise heard as one letter isn't sent. Where a model wrote a message as if it came from you, the reply says so in its place. In CarPlay, Stop and Pause keep the voice card up. A Hermes API chat left waiting on an approval shows it again.

## Before submitting 2.0
Written ahead of the release. What a phone has shown is said where it has.

In App Store Connect and on the web:
- 1.9 was approved on 2026-10-18.
- The build is 2.0 (267). Archive it from a clean build of origin/main once this is committed and pushed (and `xcodegen generate` after pulling).
- The promotional text, the keywords ("llama" gave way to "bots"; "ollama" stays), the description (a BOTS section; widgets, subagents, Siri's iOS 27 drafts and the sign-in providers left out to make room) and What's New all changed. `scripts/app-store-push.py all` makes the 2.0 version and sends them; then `notes` for the review notes, which have BOTS and ICLOUD sections and the car's Bots tab.
- Screenshots: two bot slots after the panorama on both sets (`03-bots`, `04-crew`, the iPad's `03-ipad-bots`, `04-ipad-crew`), made 2026-10-20; the later ones renumbered by renaming, unchanged; "Make it yours" and the server's screens left out. `all` sends the new pictures and puts them in order.
- The app icon is new: Redde Face is the primary icon in this build, and the App Store takes the icon from the build. The website still shows the old one.
- App Privacy stays "Data Not Collected". Sync with iCloud keeps the servers and settings in the user's own iCloud (the key-value store, and iCloud Keychain for keys and passwords); none of it reaches us. Incognito chats send nothing new anywhere.
- The privacy manifest needs nothing new: iCloud's key-value store is not a required-reason API, and UserDefaults (CA92.1) and file timestamps (C617.1) are declared already.
- Export compliance: the answer stays as it is. iCloud Keychain's encryption is Apple's.
- First release with the iCloud key-value storage entitlement (`com.apple.developer.ubiquity-kvstore-identifier`): the distribution profile has to carry it. Development builds on Marta have had it since 2026-10-19.
- Group chat notifications and a schedule's notes need the push plugin 1.5.0, on GitHub main since 2026-10-20. Pairing installs it; a Hermes with an older one is offered the update.
- A bot's schedules run by themselves on Hermes 0.21.5 and later; 0.21.0 and 0.21.3 need `gateway.multiplex_profiles` on. The Schedules screen says so.
- The website says "coming soon in 1.9" and nothing of bots.

Not known to have been tried on a device: Sync with iCloud on a real Apple Account, group chat notifications and schedule notes (the plugin on the Hermes they were built against is older than 1.5.0), Add Bot on the Hermes API alone, and the Apple Watch's Bots section.

## What's New in 1.9 (4000)
Search inside your messages, a terminal on your server, Hermes projects, and replies in your Hermes's voice.

• Search inside messages. Search in the conversation list now looks inside your conversations too. Those that match only in a message are listed under In messages, with the words around the match; open one and Redde goes to the word. It uses the Hermes Dashboard address, on either Hermes connection.
• A terminal. Settings → Terminal, or More in a chat, opens a shell on your Hermes server over SSH. From a chat it starts in the conversation's folder. Redde makes a key on this iPhone, keeps it in the Keychain and shows the line to add to the server, and the first time it shows the server's fingerprint and asks before going on.
• Projects. New Project in the conversation list makes a Hermes project over a folder of that name in ~/Projects on your server, or uses the folder if it is already there. Start a conversation in a project and your agent works in its folder; the chat's header names the project. Renaming or removing a project leaves the folder and its conversations as they are. Projects need the Hermes Dashboard.
• Your Hermes's voice. Settings → Voice → Hermes reads replies out with the voice your Hermes is set up with: ElevenLabs, OpenAI, Gemini, one running on your server, or Hermes's default, Edge, which is Microsoft's online voice. No voice key goes on the iPhone, and Say a test sentence shows which voice speaks. It uses the Hermes Dashboard login, on either Hermes connection; without one, the built-in voice reads replies as before.
• Scheduled runs, out of the way. Hermes keeps each run of a scheduled job as a conversation, and on a busy server they buried the rest. They now wait in a Scheduled runs section at the end of the list, folded until you open it, and stay out of the car's Chats. A run you pinned stays pinned.
• Fixes. Opening another conversation, or starting a new one, while your agent works no longer stops it: on a Hermes connection it finishes on your server, and the reply is there when you come back. With New conversation in voice mode on, the Talk button in a chat now carries that chat on; Siri, the Action Button, a control or opening Redde still start a new one. SOUL.md and the memory files in Settings open where your Hermes keeps them, in Docker too, where they looked empty.

## Before submitting 1.9
Written ahead of the release. What a phone has shown is said where it has.

In App Store Connect and on the web:
- 1.8 went live on 2026-10-15.
- The build is 1.9 (266). Archive it from a clean build of origin/main once this is pushed.
- The promotional text, the description (four lines) and What's New changed. `scripts/app-store-push.py all` makes the 1.9 version and sends them. It was run on 2026-10-16, before the Hermes voice was added to What's New and the description: run it again. No screenshot shows a 1.9 feature, so none were retaken. Run it from the checkout that has the Phone tools slots (`09-tools`, `08-ipad-tools`, made on 2026-10-14 and not yet committed): from one that still has the plan slots, `all` would put the plan pictures back.
- Review notes from `app-review-notes.md`: a TERMINAL section is new, and the "new in 1.8" labels are gone. Send them with `scripts/app-store-push.py notes`.
- Export compliance: the answer stays as it is, and the paragraph below says why now that the terminal speaks SSH.
- App Privacy stays "Data Not Collected". The terminal connects only to a server the user names, and its key never leaves the device.
- The privacy manifest needs nothing new: the new packages call only file-timestamp APIs, already declared (C617.1), and swift-crypto has its own manifest.
- The licences of SwiftTerm and the SwiftNIO packages are in Settings → About → Acknowledgements.
- The website says "coming soon in 1.9" (deployed 2026-10-16) and doesn't mention the Hermes voice.
- App Privacy stays "Data Not Collected" with the Hermes voice too: the reply's text goes to the user's own Hermes, which takes it on to the voice provider the user set up there. Settings says so, and names that provider.

On devices, to check first:
- The terminal has logged in to a real server from an iPhone. Not tried: starting in a chat's folder, a changed server key, the iPad with a keyboard.
- Search inside messages, projects and the scheduled runs fold have been tried in the simulator, in UI tests and against Hermes 0.21.0 to 0.22.2 in the lab, not on a phone.
- Leaving a conversation while the agent works (issue 12): tried in the lab on Hermes 0.21.0 to 0.22.2, not on a phone.
- The Hermes voice (issue 7): against Hermes 0.21.0 to 0.22.2 in the lab with stand-in voices (`lab.sh speech`), and on an iPhone 15 Pro Max as a development build. Not yet heard with a real provider, nor with Edge.
- The Talk button (issue 14) and the context files (issue 15) are on an iPhone 15 Pro Max as a development build, not yet tried by hand. Issue 15 has run against Hermes in the lab with a home of its own, not in Docker.

## What's New in 1.8 (4000)
Phone tools, the camera in voice mode, answers out loud or with a nod, notes by Siri, and more in the car.

• Phone tools. Your agent can now use what is on your iPhone, if you let it: look up and add calendar events and reminders, look up a contact, find a photo by its date or by what it shows, keep files in Redde's folder in the Files app, set alarms and timers, write on a widget, and start a call or a text for you. Settings → Phone tools switches on each area by itself, and adding, changing and deleting always ask you first. What it reads goes to your own server and nowhere else. It takes Redde's plugin on your Hermes (that screen installs or updates it) and the Hermes Dashboard login, and it works while Redde is open.
• Alarms and timers. Ask for a timer or a wake-up and your agent sets one of iOS's own: it counts down on the Lock Screen and rings like any other alarm.
• A widget your agent writes on. Add “From Your Agent” to your Home Screen or Lock Screen, and your agent can leave you a line there: today's plan, or something to remember at three. If your iPhone is paired for notifications, it can write on it while Redde is closed.
• Calls and texts. Ask your agent to call someone or text them, by name or by number. iOS asks before a call goes out, and a text opens in Messages for you to send.
• Show it. Turn on the camera in voice mode and ask about what is in front of you: each question goes with a picture of that moment.
• Approve out loud. With Settings → Voice → Answer requests by voice, Redde reads out a command that is waiting for your approval and listens for "approve" or "deny", in voice mode and in the car. A question from your agent is read out the same way. Passwords are never asked for aloud.
• Or with a nod. With AirPods Pro, AirPods Max, or AirPods 3 or later, nod a couple of times to approve, or shake your head to deny.
• Take a note. For something you want kept, not answered: say "Hey Siri, take a note in Redde", use the Note to Redde control in Control Center or on the Action Button, or tap Take a Note on the car's screen. Your agent files it in a chat called Notes, and nothing is read back. Without a connection the note waits on the iPhone and goes when it can.
• Stop and Pause in the car. The voice screen has Stop and Pause at the top. Pause holds the microphone while Redde listens, or the reply while it thinks or speaks, until you tap Resume.
• Short answers in the car. Turn it on in Settings → Voice or on the car's Ask tab, and a question you ask by voice in the car gets two or three sentences. Say "more" for the rest.
• A calmer voice screen in the car, in four looks. Settings → Appearance → CarPlay voice screen plays the one you pick as it will look on the car.
• A thinking sound. Settings → Voice → Thinking sound plays a quiet pulse while your agent works and nothing is being said, in the car or always.
• Progress on the Lock Screen. When your agent keeps a task list for a longer job, the Live Activity shows how far it has got and the task in hand.
• Pictures, together. Several pictures in a message are set out together. Tap one to see it full screen, swipe to the next, and pinch or double-tap to zoom.
• Fixes. Tapping a notification no longer closes Redde. Thinking can be folded away while a reply is still coming. "Jump to latest" goes away once you have scrolled back to the end of a conversation, and new text is followed from there again.

## Before submitting 1.8
Written ahead of the release. Most of 1.8 has been tried in the simulator and in tests only; what a phone or a car has shown is said where it has.

In App Store Connect and on the web:
- 1.7.1 came through review on 2026-10-13 (App Store Connect shows it ready for distribution), so the 1.8 version could be made.
- The build is 1.8 (265). 263 went to App Store Connect on 2026-10-13 without the fix for the crash when a notification is tapped, and 264 with it; on 2026-10-14 1.8 was taken back out of review so that it carries the whole of Phone tools (alarms and timers, the widget, calls and messages) and the camera in voice mode, which 265 adds. Archive from a clean build, which is also what trains Siri's phrases, the new "Take a note in Redde" among them.
- Review notes from `app-review-notes.md`, with the key put in. They are rewritten for 1.8: Phone tools, and the four permissions the version adds (Reminders, Contacts, Photos, and Motion & Fitness for the nod). The Calendar permission's words changed too. Rewritten again on 2026-10-14 for the alarms, the widget, calls and messages, the Alarms permission and the camera in voice mode: send them again with `scripts/app-store-push.py notes`. The first version went to App Store Connect on 2026-10-13, sent by `scripts/app-store-push.py notes` with the test key that 1.0's notes held. The notes of 1.1 through 1.7.1 had all gone in with `<<REVIEW KEY>>` still in them, so reviewers had no key for the test steps in those; the script now puts it in.
- App Privacy stays "Data Not Collected" (below).
- The privacy manifest (`Echo/Resources/PrivacyInfo.xcprivacy`) has a second required-reason entry: file timestamps, reason C617.1 (files inside the app's own container), because Phone tools' Files area lists the files in Redde's folder with when each was changed. An upload that uses such an API without its reason is answered with ITMS-91053.
- The privacy policy and the support page as they are in `docs/` have to be published before the release. On 2026-10-13 legal.goosehouse.org still served the policy of September 27 and the old support page, which say nothing of the notification relay (live since 1.7), of Phone tools, of notes or of the nod. The policy's effective date in `docs/privacy.md` is the day this was written; make it the day it goes up.
- The copy on this page and the screenshots in `design/screenshots/` are in App Store Connect since 2026-10-13: `scripts/app-store-push.py` made the 1.8 version there and sent the promotional text, the description, What's New and the one screenshot that changed. That is the CarPlay slot, `07-car`, drawn again for 1.8: the Ask tab with Take a Note and Short Answers under the cards, and the voice card with Stop and Pause. After a change to this page, `scripts/app-store-push.py status` says what differs and `all` sends it. The promotional text, the description and What's New changed on 2026-10-14, after that push, and the plan slot made way for a Phone tools slot on both devices (`09-tools`, `08-ipad-tools`): send them again with `all`.
- Still to go in by hand: the build, the submission, and a new iPhone App Preview, `design/video/redde-app-preview-phone-tools.mp4` (29.2 s, 886×1920, with music; made 2026-10-14, not in git): put it first, before the general one. It shows the Lock Screen and the Home Screen for a moment each, with Redde's own countdown and widget on them; if App Review objects to anything outside the app in a preview, that is where. The scripts don't send previews.
- The Hermes plugin people install is whatever is on the main branch of the public repository. This release needs 1.3.0 (alarms, the widget, calls and messages); main had 1.2.0 on 2026-10-14, and 1.3.0 goes there when this is pushed. Push before the release, or the new areas are offered by no one's Hermes.
- The website still says "coming soon in 1.6 and 1.7".

On devices, to check first:
- Seen on an iPhone 15 Pro Max on 2026-10-14, with plugin 1.3.0: a call to a contact by name (iOS asked, the call went out) and a timer that counted down and rang. Not seen: a text in the Messages sheet and what the tool hears on Cancel, an alarm for a time of day, the widget written on by a real agent, the widget filled by a notification with Redde closed, the camera in voice mode (the simulator has no camera, and whether the camera and the microphone get along is unknown).
- Phone tools on a phone, against a real Hermes with the plugin at 1.2.0. Seen on an iPhone 15 Pro Max on 2026-10-12: the agent found the most recent photo, fetched it and described it. Not seen: the fetched photo shown in the reply, a photo found by what it shows (the simulator cannot classify pictures, so the looking has only run on a Mac), how long a real library takes and what it does to the battery, a reminder or an event added through the phone, the question Redde asks before a change, deleting photos, and Files. The lab ran every tool on Hermes 0.21.0, 0.21.3 and 0.21.5 with a stand-in model.
- Several photos in one reply. An agent asked for a few calls the photo tool once for each; that a later call is not lost is tested with a stand-in plugin only.
- Approving out loud: a real microphone, a real agent's request read aloud in the middle of a turn, and the car. Tested with a stand-in recognizer and voice.
- The nod: nobody has nodded at it. The detector is tested on made-up head movement; AirPods and the Motion & Fitness question have not been tried.
- Take a note by Siri, by the control and in the car. The filing was run with a scripted server; Siri, the control and a real agent's filing have not been tried.
- CarPlay on a car's screen: Stop, Pause and Resume, the four looks and whether their pictures play as they do in Settings, the Short Answers row and its switch, and Take a Note. All drawn with `scripts/carplay-preview.sh`, which is not a car. Pause with a Kokoro voice has not been heard.
- Short answers in the car against a real agent: what it makes of the request, and "more".
- The thinking sound, by ear: beside a reply, and in a car. Its pulses were spaced out on 2026-10-13 and nobody has listened since.
- The task list on the Live Activity: seen on the simulator's Lock Screen. Not seen: the Dynamic Island, a real agent's list, a phone.
- Pictures: the group and the viewer were driven in the simulator (tap, swipe, pinch, double tap). Not on a phone, not with real photos, and not on an iPad.
- "Jump to latest": fixed and tested in the simulator on iOS 26.3 and 27.0.
- Everything under "Before submitting 1.7.1" and "Before submitting 1.7" that was still owed is still owed.

## What's New in 1.7.1 (4000)
Voice on the iPhone 11 and iPhone SE, a new look for CarPlay, and audio that plays in the conversation.

• Voice on iPhone 11 and iPhone SE (2nd generation). On these iPhones voice mode and the microphone in the message field said on-device transcription wasn't available for your language, whatever the language. Apple's newer speech recognition isn't available on them, so Redde now listens there with the one behind keyboard dictation. It runs on the iPhone too, and nothing you say leaves it.
• CarPlay, in color. The Ask tab's cards are wider and a color each: blue to Ask, gold to Talk, green for a New Chat. Settings → Appearance → CarPlay cards has five more looks to pick from.
• A livelier voice card in the car. Columns of lights jump with each syllable while Redde speaks, and a light sweeps to and fro while it thinks.
• Audio in replies. When your agent sends a sound file, such as a summary spoken by its speech tool, the conversation shows a player where the file's path used to be: play, pause, and drag to move along. Files your agent sent also come back when you open a chat again. Like pictures and documents, this uses the Hermes Dashboard login in Settings → Connection details.

## Before submitting 1.7.1
- The build is 1.7.1 (262). Archive from a clean build.
- Voice on an iPhone 11 or SE (2nd generation) has not been tried by anyone: neither is at hand, the simulator cannot transcribe with the dictation model, and the tests that pass ran on a Mac (`SpeechRecognizerTests`, each with both transcribers). Somebody with one of those iPhones should try voice mode and the microphone in the message field first, over TestFlight if need be. The line above says it works.
- CarPlay on a car: the wide cards in each of the six looks and the voice card's new pictures have been drawn with `scripts/carplay-preview.sh`, not yet looked at on a car's screen. Whether the voice card's pictures play there as they do on the mock-up is the thing to see.
- Audio in a reply: played on an iPhone 15 Pro Max on 2026-10-12, from a file a real Hermes delivered. Still to see: that the player is there again after the chat is opened afresh from the list. MP3, Ogg Opus, M4A, WAV and FLAC decode in the iOS 27 simulator; iOS 26 has not been checked, where a file that doesn't decode is shown as a file to open.
- Everything under "Before submitting 1.7" that was still owed is still owed.

## What's New in 1.7 (4000)
Notifications when Redde is closed, replies you can talk over, new CarPlay screens, and a better place to write.

• Notified when Redde is closed. Until now Redde went quiet once iOS closed it. Pair your Hermes in Settings → Voice → Notify when Redde is closed and it tells your iPhone itself: a reply is ready, a command waits for approval, the agent has a question or needs a password, a turn failed, a task it handed off came back. Approve, deny or answer from the notification. Notifications are encrypted between your Hermes and your iPhone, and the relay that carries them can't read them. It takes a small plugin on your Hermes; over the Hermes Dashboard, Redde installs it for you and pairing is one tap.
• Talk over a reply. Start speaking while Redde is answering and it stops to listen. A cough or an "mm-hm" doesn't count. It is on with headphones from the start; Settings → Voice → Talk over replies adds the phone's speaker, and Interrupt with can make it only the word "stop", for a room where other people are talking. Not in the car.
• A new look in the car. CarPlay opens on buttons to Ask, Talk or start a New Chat, with your chats on a tab of their own. The voice card has a moving waveform, Mute and End.
• Sign in with a browser. A Hermes Dashboard that signs you in with Google or another provider now works: Settings → Connection details → Sign in with a browser.
• Custom headers. A server behind a reverse proxy that asks for a header of its own can be sent it, in Settings → Connection details. Setup codes carry them too.
• A draft for every conversation. What you typed and didn't send stays with its conversation, also after Redde has been closed, and the list marks it Draft.
• More ways to write. Dictate into the message field with the mic beside it, paste a picture, and open a long message on a page of its own. Over the Hermes Dashboard you can attach a video; a long one is made smaller first. Return can send, if you choose that in Settings → Writing.
• Easier reading. Chat text size, in Settings → Appearance, sets conversations larger or smaller than the rest of the iPhone. A ring in the header shows how full the model's context is. When your server can't be reached, the conversations this iPhone has opened can still be read.
• Answer from the Lock Screen and the wrist. A command waiting for approval takes over the Live Activity, with Approve and Deny, and a finished reply's notification takes your next message. On Apple Watch, approvals and questions come to the wrist, a chat list lets you carry a conversation on, and Ask Redde is a complication. A watch whose iPhone uses the Hermes Dashboard asks through the iPhone.
• One conversation, its own way. In the model menu on the Hermes Dashboard: Fast mode for models that have one, and Run commands without asking for a conversation where you trust the agent; a bolt in the header shows while it is on. Touch and hold a conversation in the list to move it to a project.
• The agent's plan, as a checklist. When Hermes keeps a task list for a longer job, the reply shows what is done, what it is on, and what is left.
• Two new widgets. Needs you: a command waiting for approval or a question from your agent, on the Home Screen or Lock Screen; a tap opens the conversation. Context: how full the model's context is.
• Voice, your way. Your own stop phrases, in Settings → Voice, for another language or a word you prefer. “Hey Siri, ask Work in Redde” opens voice mode on a Hermes profile.
• Your server, from the phone. Settings → Gateway shows what your Hermes is running and connected to, switches its MCP servers on and off and tests them, reads its logs, and restarts or updates Hermes. Settings → Files opens its folders: look at a file, edit a text one, upload, delete. Both need the Dashboard login.
• A switch for the notification sound.
• Fixes. Over the Dashboard on Hermes 0.21.3 and later, approvals and the agent's questions reach you again, and an attached file reaches the agent.

## Before submitting 1.7
Written ahead of the release, so unlike the rest of this page not all of it has been seen on a device yet.

In App Store Connect and on the web:
- The privacy policy and the support page as they are in `docs/` have to be published. On 2026-10-08 legal.goosehouse.org still served the policy of September 27, which says Goosehouse receives nothing and lacks even 1.6's paragraphs on setup links and scanning a code.
- Review notes from `app-review-notes.md`, with the key put in.
- The copy on this page and the screenshots in `design/screenshots/` (retaken for 1.7 on 2026-10-10, with new slots for CarPlay, the server's screens and the task list): `scripts/app-store-push.py all` sends both, given an App Store Connect API key. It leaves the review notes, the Apple Watch set and the Header and Search Results pictures alone.
- The build is 1.7 (261). Archive from a clean build, which is also what trains Siri's phrases, the new "Ask <a profile> in Redde" among them.
- The first archive with the notification extension (`com.goosehouse.echo.push`): Xcode's automatic signing has to make its App Store profile, with the app group.
- The first archive with the watch's complication extension (`com.goosehouse.echo.watchkitapp.widgets`), new in build 261: Xcode has to make its App ID and profile too. It has no entitlements of its own. Nothing here has built it for a device: the simulator builds don't sign.
- The Hermes plugin people install is whatever is on the main branch of the public repository, so the plugin that goes with this build has to be pushed before the release (it is, as 1.1.0).

On devices, to check first:
- Notifications with Redde closed, against a real Hermes with the plugin at 1.1.0: a reply and an approval arrive with their text, Approve and Deny answer, a question shows its choices as buttons and takes a typed answer, a failed turn says why. With Notification sound off they arrive silent. None of this can be seen in the simulator, where a simulated push skips the notification extension.
- CarPlay on a car's screen: the two tabs (Ask's three cards under the name of the open chat, with the recent chats below them; the Chats list and its check beside the open chat), the voice card's moving waveform in Listening and Speaking and the turning spark in Thinking, the backdrop behind the card (iOS 27) in the car's light and dark appearance, End and Mute at the top of the card. Build 261 as first made was seen on a car on 2026-10-10: its three buttons were tiny and the card had no picture. Both are reworked since and have been drawn with CarPlay's own views (`scripts/carplay-preview.sh`), which is not a car: on a screen 240 points high the picture comes out about 46 points across, and it is the full 150 from 360 points up. Also worth a look: the car's own Back button on the card, which closes the card without ending the conversation.
- Sign in with a browser against a Dashboard that uses a real identity provider (tried against Hermes's own username-and-password page), and custom headers through a real reverse proxy.
- Talk over replies beyond what was tried (an iPhone 15 Pro Max on its speaker and with AirPods): the earpiece, another phone, a reply several minutes long, only "stop" on headphones.
- Dictation into the message field with a real voice, a picture pasted on a device, and a video picked from Photos.
- Approve on the Live Activity behind an unlock, and on a real watch: approvals and questions on the wrist, and asking through the iPhone.
- Approvals over the Dashboard against a real Hermes 0.21.3 or later (checked against the lab's).
- The model menu's switches and Move to Project against a real server. The lab covered running without asking (a command then runs unasked, and is asked about again when it is off) and the move, on Hermes 0.21.0, 0.21.3 and 0.21.5. Fast mode has only ever been refused: turning it on takes an OpenAI, Anthropic or xAI model, which the lab doesn't have.
- A task list from a real model. The lab's stand-in model wrote and ticked a list on Hermes 0.21.0, 0.21.3 and 0.21.5, over both connections, live and reopened; no real model has, and no device has shown the card. Ask for something with several steps ("plan it as a to-do list and work through it") and watch the Tasks card under the reply. On the Hermes API with 0.21.3 or later a list ticked in a later message comes back with only the items that message named: that is Hermes forgetting the list between messages there, not the app.
- The Needs you and Context widgets on a device. In the simulator, against the lab's Hermes 0.21.5: a real approval showed on the widget, stayed while the app was closed, a tap opened its conversation with the card, and Deny took it off. Not seen anywhere: the Lock Screen sizes on a Lock Screen (only drawn in tests), a tinted or clear Home Screen, and an entry arriving through a notification while Redde is closed, which only a device can show since a simulated push skips the extension. To try that last one: pair notifications, close Redde, have the agent ask for approval, and look at the widget before opening anything.
- The watch's chat list and the Ask Redde complication on a real watch. In the watch simulator, against the lab's Hermes API: the list showed the server's chats, opening one brought up its last exchange, and the next question went into it (the server's count of its messages said so); the complication's four sizes were drawn inside the app and its link opened the input. Never seen: the complication on a watch face, or a tap on it. The complication is a new extension target (`com.goosehouse.echo.watchkitapp.widgets`): the first archive has Xcode make its App ID and profile, as it did for the push extension.
- Installing the plugin from the notifications screen on a real Hermes. The lab ran it on 0.21.0, 0.21.3 and 0.21.5 with the app's client: installed and switched on everywhere, running at once only on 0.21.5, as the screen says. The screen itself was only driven on a made-up server. Not tried: the install followed by pairing on a real server, and a Hermes that can't reach GitHub.
- Settings → Files against a real server and on a device. The lab covered the client on Hermes 0.21.0, 0.21.3 and 0.21.5 (up, down, replace, edit, delete, credentials kept out), and the screen was driven against the lab's 0.21.5 in the simulator: the home folder, Go to Folder, a download into the preview, a text file in the editor. Not tried: uploading from the Files app or from Photos (the pickers can't be driven in a test), a file anywhere near 100 MB, a slow connection, and a server that keeps its file manager to one folder.
- "Hey Siri, ask <a profile> in Redde" on a device, from a clean build (Siri's phrases are trained then). Nothing here could speak to Siri: a launch flag stood in for it in the simulator, where the app moved to the named profile and opened voice mode, and the built app's Siri metadata lists the action with its three phrases. Also unseen: whether Siri picks up a profile added after install without the app being opened once more.
- A stop phrase of your own, said aloud, in the language it is in. The matching is unit-tested and voice mode was driven with a stand-in recogniser; no real recogniser has heard one. Worth trying one in a language other than English, and with "Interrupt with" on Only "stop".
- Settings → Gateway against a real server. The lab covered the status, MCP servers, logs, the update check and a restart of a gateway started by hand, on Hermes 0.21.0, 0.21.3 and 0.21.5. Not covered anywhere: a restart where a service manager (launchd, systemd) runs the gateway, which is how most servers are set up, and applying an update, which has never been run for real.

## App Privacy (App Store Connect → App Privacy)
"Data Not Collected", unchanged in 1.7 (decided 2026-10-08, with the notification relay in view) and in 1.8.

1.8's Phone tools read the calendar, reminders, contacts and photos, and the label is about what the developer collects: all of it goes to the person's own server, at their agent's request and with the area switched on by them, and none of it to Goosehouse. What Redde makes out in photos stays in a file on the device. Head movement for the nod is read on the device and kept nowhere. App Store Connect's label is unchanged; the purpose strings in `project.yml` and the privacy policy say what each permission is for.

What that decision weighed: the optional relay keeps a paired iPhone's push token, the hash of a secret and the time of its last check-in, for as long as the pairing lasts and at most 120 days after the iPhone last checked in (`docs/push.md`, "What is where"). It has no account and nothing that says who the person is, the notifications pass through it encrypted and are not kept, and conversations, credentials and everything else go only to the person's own server. The privacy policy describes the relay in full, and the review notes point the reviewer to it. If Apple asks for the token to be on the label, the entry would be Identifiers → Device ID, for App Functionality, not linked to the user and not used for tracking, with the same entry in `Echo/Resources/PrivacyInfo.xcprivacy`.

## Export compliance
`ITSAppUsesNonExemptEncryption` stays `false` (`project.yml`). Besides HTTPS, 1.7 encrypts and decrypts notifications (X25519, HKDF-SHA256, AES-256-GCM) and hashes for its browser sign-in (SHA-256, for PKCE). All of it is CryptoKit, Apple's implementation in the operating system; the app contains no cryptography of its own and none from a third party. Since 1.9 the terminal speaks SSH through Apple's open-source swift-nio-ssh, with standard algorithms only (curve25519-sha256 and ecdh-sha2-nistp256/384/521 key exchange, aes128-gcm and aes256-gcm, ssh-ed25519 and ecdsa-sha2 keys, hmac-sha2-256). Its primitives come from swift-crypto, which on Apple's platforms is CryptoKit itself (`@_exported import CryptoKit`; its vendored BoringSSL is built only for Linux, Android, Windows, WASI and OpenBSD, and a 1.9 build links none of it), and the device's own key is CryptoKit's Ed25519. So the cryptography is still all the operating system's. App Store Connect asks for documentation when an app implements proprietary algorithms, or standard ones "instead of, or in addition to, using or accessing the encryption within Apple's operating system". Redde does neither, so the answer to "What type of encryption algorithms does your app implement?" is "None of the algorithms mentioned above", and with the key set to `false` the question isn't asked at upload.

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
