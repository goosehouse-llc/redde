import Foundation

/// The highlights shown once after an update ("What's New in Redde 1.7.1"). One entry per
/// version that has something worth showing; a version without an entry shows nothing.
nonisolated enum WhatsNew {
    struct Item: Identifiable, Equatable, Sendable {
        var symbol: String
        var title: String
        var detail: String
        /// Only on iPhone: an iPad has no such thing (its list is a sidebar).
        var phoneOnly = false
        /// Only on iPad.
        var padOnly = false
        /// A button under it that sets the thing up (`WhatsNewView`).
        var action: Action?
        var id: String { title }
    }

    /// What an item's button does.
    enum Action: Equatable, Sendable {
        /// Opens the Ahead of Your Day setup (`AheadOfYourDay`), offered once (asked 2026-10-30).
        case aheadOfYourDay
    }

    struct Release: Identifiable, Equatable, Sendable {
        var version: String
        var items: [Item]
        var id: String { version }
    }

    /// Newest first. Keep each to a handful of lines a person reads in ten seconds.
    static let releases: [Release] = [
        Release(version: "2.3", items: [
            Item(symbol: "sunrise", title: String(localized: "Ahead of your day"),
                 detail: String(localized: "Morning Ideas to swipe, a Week Ahead, an Evening Wrap-up, and heads-ups before events with what to bring. Turn them on in Settings → Agent. They take the Redde plugin 1.10 on your Hermes."),
                 action: .aheadOfYourDay),
            Item(symbol: "car", title: String(localized: "Leave-By Alerts"),
                 detail: String(localized: "Redde looks at your calendar and Apple Maps on this device and tells you when to leave, a few minutes early. Only events with a street address. Settings → Agent.")),
            Item(symbol: "calendar.day.timeline.left", title: String(localized: "Your day as a timeline"),
                 detail: String(localized: "Ask what's on your calendar: your events to scale, free time marked, a line for now. Tap an empty spot to add one. Pick the calendars your agent looks at in Settings → Agent → Calendars.")),
            Item(symbol: "rectangle.on.rectangle", title: String(localized: "New answer cards"),
                 detail: String(localized: "The weather by the hour with rain called out, places on a map with hours and walks, an email to check before it goes, a checklist to tick, and new cards for things to buy, your home's devices, reminders and timers, comparisons and game scores.")),
            Item(symbol: "hand.raised", title: String(localized: "Approvals in plain words"),
                 detail: String(localized: "Before your agent runs something, the card says what will happen: what it deletes, in red, and what it changes.")),
            Item(symbol: "location", title: String(localized: "Current Location"),
                 detail: String(localized: "Turn it on in Settings → Agent and your agent hears roughly where you are, only when you ask about places, directions or the weather.")),
            Item(symbol: "mappin.and.ellipse", title: String(localized: "Places and Health"),
                 detail: String(localized: "Arriving at Home or Work can tell the agent you pick, and, if you allow it, last night's sleep and today's steps shape your morning ideas. Settings → Agent."),
                 phoneOnly: true),
            Item(symbol: "globe", title: String(localized: "Your language"),
                 detail: String(localized: "Redde in 17 languages, and voice mode listens and answers in the one you pick.")),
            Item(symbol: "laptopcomputer", title: String(localized: "Redde for Mac"),
                 detail: String(localized: "A native Mac app in the same purchase, with your conversations beside the chat, menus and shortcuts."),
                 phoneOnly: true),
        ]),
        Release(version: "2.2", items: [
            Item(symbol: "waveform.and.mic", title: String(localized: "Live voice"),
                 detail: String(localized: "Pick GPT-Live, Gemini Live, Grok Voice or ElevenLabs in Settings → Voice → Voice mode and add your key for it: voice mode becomes a call you can interrupt, and the voice hands real work to your agent. Each bot can have its own (Edit Bot → Voice). The service bills your key by the minute.")),
            Item(symbol: "phone.arrow.down.left.fill", title: String(localized: "Your agents can call you"),
                 detail: String(localized: "Turn on Calls from Agents in Settings → Notifications and pick who may: when something shouldn't wait, an agent rings your iPhone like a phone call. Answer and it says why, in its own voice, and you talk. It takes the Redde plugin 1.8.0 on your Hermes.")),
            Item(symbol: "person.3.fill", title: String(localized: "Group chats as calls"),
                 detail: String(localized: "Turn on Group Chats as Calls in Settings → Voice → Voice mode: voice mode in a group chat becomes a live call, and each bot answers in its own live voice.")),
            Item(symbol: "speaker.wave.2.fill", title: String(localized: "ElevenLabs reads replies"),
                 detail: String(localized: "Pick ElevenLabs in Settings → Voice → Reading voice, on your own key, and each bot reads in an ElevenLabs voice of its own. A bot can have a reading voice of its own too, in Edit Bot → Voice.")),
            Item(symbol: "ear", title: String(localized: "Wake phrases"),
                 detail: String(localized: "With Redde open, say “Hey” and an agent's name to talk to it, or “Hey Home, turn the lights off” to ask at once. Turn it on, and change the phrases, in Settings → Voice → Wake Phrase. It listens on the device.")),
            Item(symbol: "puzzlepiece.extension", title: String(localized: "Plugins"),
                 detail: String(localized: "Settings → Plugins finds Hermes plugins in Nous Research's catalog and installs them on your server, for your agent or, in Edit Bot, for one bot. See what each sends, costs and adds first. It takes the Hermes Dashboard login.")),
            Item(symbol: "paintpalette", title: String(localized: "A wallpaper"),
                 detail: String(localized: "Pick the color behind your chats beside the accent and your bubbles, in Settings → Appearance. The text on it, and light or dark, follow it, so replies stay readable.")),
            Item(symbol: "rectangle.split.3x1", title: String(localized: "Kanban for bots"),
                 detail: String(localized: "Edit Bot → Tools offers Kanban, so a bot can make cards, in its own chat and in group chats.")),
            Item(symbol: "applewatch", title: String(localized: "Bots' voices on the watch"),
                 detail: String(localized: "On Apple Watch each bot reads its replies in its own voice, as on the iPhone."),
                 phoneOnly: true),
        ]),
        Release(version: "2.1.1", items: [
            Item(symbol: "cloud.sun", title: String(localized: "Weather and time, looked up"),
                 detail: String(localized: "Weather cards fill themselves in, now and by the hour and day, and your agent knows your local time when you ask. It takes the Redde plugin 1.7.1 on your Hermes: Settings → Redde Plugin offers the update.")),
            Item(symbol: "photo.on.rectangle", title: String(localized: "Pictures on every device"),
                 detail: String(localized: "Pictures sent from Hermes Desktop, or from Redde on another device, show in your chats. On the Hermes API, with the Dashboard login saved, the pictures you send are kept on your server too, so they show elsewhere.")),
            Item(symbol: "car", title: String(localized: "CarPlay, quicker"),
                 detail: String(localized: "Pick a bot and the voice screen comes up at once, in its face, while its chat opens. A speaking bot's face is bigger, with sound bars, and moves with what you hear."),
                 phoneOnly: true),
            Item(symbol: "slider.horizontal.3", title: String(localized: "Also", comment: "What's New: a heading over smaller additions"),
                 detail: String(localized: "Each bot can read at a speed of its own (Edit Bot → Voice → Speed). Servers behind Pangolin connect with a Link's access token. Settings → Appearance can take bots or projects out of the chat list. And a new face shape: the house.")),
            Item(symbol: "checkmark.seal", title: String(localized: "Fixes", comment: "What's New: a heading over bug fixes"),
                 detail: String(localized: "Opening Redde no longer stops music playing in another app. In the car, the first question of a drive no longer says no API key is stored. The main agent stays in the bots list when it's the only one.")),
        ]),
        Release(version: "2.1", items: [
            Item(symbol: "rectangle.stack", title: String(localized: "Every server in one list"),
                 detail: String(localized: "All Servers, in the server menu at the top of the conversation list, shows every saved server's chats in one list, each tagged with its server. All Profiles does the same for your Hermes profiles.")),
            Item(symbol: "map", title: String(localized: "Cards in replies"),
                 detail: String(localized: "Your agent can show a map with pins or a route, a list of places and the weather under its reply. Tap a map for directions. It takes the Redde plugin on your Hermes.")),
            Item(symbol: "link", title: String(localized: "Link previews"),
                 detail: String(localized: "Settings → Appearance → Link previews puts a linked page's title and picture under the message. Off until you turn it on: to make the card, Redde opens the page itself.")),
            Item(symbol: "square.grid.2x2", title: String(localized: "Bots, further"),
                 detail: String(localized: "Bots sit as faces in a grid, with their pictures from Hermes Desktop. Edit Bot switches each bot's skills and the main agent's tools, Topology maps your bots and their group chats, and there are two new colors.")),
            Item(symbol: "car", title: String(localized: "CarPlay"),
                 detail: String(localized: "The Bots tab shows a card for each bot, its face in its mood. The voice screen shows the bot you're talking to, and the car opens on the tab you left. With Stop and Skip in the car on (Settings → Voice), say “stop” or “skip” while a reply plays."),
                 phoneOnly: true),
            Item(symbol: "iphone.gen3", title: String(localized: "iPhone Duo"),
                 detail: String(localized: "Open or close it mid-chat and carry on where you were. Half open, the voice screen and the chat keep off the fold."),
                 phoneOnly: true),
            Item(symbol: "checkmark.seal", title: String(localized: "Faster, and fixes"),
                 detail: String(localized: "Long conversations open at once, typing is smoother, and Settings opens as pages. Voice mode's stop cue is heard again, and replies stay on the loudspeaker.")),
        ]),
        Release(version: "2.0", items: [
            Item(symbol: "face.smiling", title: String(localized: "Bots"),
                 detail: String(localized: "Each profile on your Hermes is a bot, with a face, a voice and a chat of its own, under Bots in the conversation list. New Bot starts from a template (Researcher, Writer, Coder, Home, Planner) or from nothing, and its job, personality, model, face and tools are yours to change. Type @ in a bot's chat to hand something to another.")),
            Item(symbol: "bubble.left.and.bubble.right", title: String(localized: "Group chats"),
                 detail: String(localized: "New Group Chat puts two to six bots in a room, where they answer in turn, or only the one you tag. Their replies show as they are written, files go with your messages, and Hermes Desktop's rooms are there to read.")),
            Item(symbol: "waveform", title: String(localized: "Talk to the whole crew"),
                 detail: String(localized: "Talk in a group chat opens the voice screen on the room. The bots answer one after another, each in a voice of its own, its face up while it speaks.")),
            Item(symbol: "clock", title: String(localized: "Schedules, and quiet"),
                 detail: String(localized: "Schedules… gives a bot something to do at a time, such as every weekday at 7, and its answer comes into its chat with a notification, while your phone is off. Mute… quiets a bot's chat or a group chat for an hour, until morning, or until you turn it back on.")),
            Item(symbol: "car", title: String(localized: "Bots wherever you ask"),
                 detail: String(localized: "Say “Ask Home in Redde” to Siri, pick a bot in the car's Bots tab or on the Apple Watch, or give one a spoken word in Settings → Voice → Spoken prefixes: “Home, turn off the porch light.”")),
            Item(symbol: "face.smiling.inverse", title: String(localized: "Redde has a face"),
                 detail: String(localized: "The new app icon, and the voice orb: Redde's face blinks, looks at you while you talk and speaks with the reply. If you picked another icon or orb, you keep it.")),
            Item(symbol: "eyeglasses", title: String(localized: "Incognito, and iCloud"),
                 detail: String(localized: "New Incognito Chat, in a chat's ••• menu, is kept nowhere and deleted from your server when you leave it. Settings → iCloud → Sync with iCloud brings your servers, their keys and your settings to your other devices.")),
            Item(symbol: "ellipsis.bubble", title: String(localized: "At a glance"),
                 detail: String(localized: "The conversation list shows what your agent is doing: a spinner while it works, Needs you while it waits on you, and a dot for a reply you haven't seen. On the Hermes API, a reply now carries on on your server when you leave it.")),
            Item(symbol: "checkmark.seal", title: String(localized: "Fixes", comment: "What's New: a heading over bug fixes"),
                 detail: String(localized: "A reply read by Kokoro or your Hermes no longer goes on in two voices. A noise heard as one letter isn't sent. A card's question, a share or a Siri draft can start a new conversation.")),
        ]),
        Release(version: "1.9", items: [
            Item(symbol: "text.magnifyingglass", title: String(localized: "Search inside messages"),
                 detail: String(localized: "Search in the conversation list now looks inside your messages too. Matches are listed under In messages with the words around them, and opening one goes to the word. It uses the Hermes Dashboard address.")),
            Item(symbol: "apple.terminal", title: String(localized: "A terminal"),
                 detail: String(localized: "Settings → Terminal, or More in a chat, opens a shell on your server over SSH, in the chat's folder when there is one. Redde makes a key on this device and shows the line to add to the server.")),
            Item(symbol: "folder.badge.plus", title: String(localized: "Projects"),
                 detail: String(localized: "New Project in the conversation list makes a Hermes project over a folder in ~/\u{2060}Projects on your server. A conversation started in it works in that folder, and its header names the project. On the Hermes Dashboard.")),
            Item(symbol: "speaker.wave.2", title: String(localized: "Your Hermes's voice"),
                 detail: String(localized: "Settings → Voice → Hermes reads replies out with the voice your Hermes is set up with, such as ElevenLabs or one on your server, so no voice key goes on the phone. Say a test sentence shows which voice speaks. It uses the Hermes Dashboard login.")),
            Item(symbol: "clock.arrow.circlepath", title: String(localized: "Scheduled runs, out of the way"),
                 detail: String(localized: "Each run of a scheduled job is a conversation of its own. They now wait at the end of the list, folded until you open them, and stay out of the car's Chats.")),
            Item(symbol: "checkmark.seal", title: String(localized: "Fixes", comment: "What's New: a heading over bug fixes"),
                 detail: String(localized: "Opening another conversation no longer stops your agent: the reply is there when you come back. The Talk button in a chat keeps that chat, with New conversation in voice mode on too. SOUL.md and the memory files open where your Hermes keeps them, in Docker as well.")),
        ]),
        Release(version: "1.8", items: [
            Item(symbol: "iphone", title: String(localized: "Phone tools"),
                 detail: String(localized: "Settings → Phone tools lets your agent use what is on this device: the calendar, reminders, contacts, photos, a folder of files, alarms and timers, and a widget it writes on. It can start a call, which iOS asks you about, or write a text for you to send. You switch on each area yourself, and adding, changing or deleting always asks you first. It takes Redde's plugin on your Hermes, which that screen installs.")),
            Item(symbol: "camera.viewfinder", title: String(localized: "Show it"),
                 detail: String(localized: "In voice mode, tap the camera beside Hands-free and it takes the orb's place. Each question you ask goes with a picture of what it sees, so “what is this?” has an answer.")),
            Item(symbol: "hand.thumbsup", title: String(localized: "Approve out loud, or with a nod"),
                 detail: String(localized: "Turn on Settings → Voice → Answer requests by voice, and Redde reads out a command that waits for your approval and listens for “approve” or “deny”, in voice mode and in the car. With AirPods, Nod or shake to answer lets your head say it.")),
            Item(symbol: "note.text", title: String(localized: "Take a note"),
                 detail: String(localized: "For something you want kept, not answered. Say “Hey Siri, take a note in Redde”, add the Note to Redde control, or tap Take a Note in the car. Your agent files it in a chat called Notes. If your server can't be reached, the note waits and goes later.")),
            Item(symbol: "car", title: String(localized: "More in the car"),
                 detail: String(localized: "Stop and Pause on the voice screen: Pause holds the microphone or the reply until you tap Resume. Short answers in the car asks your agent for two or three sentences; switch it in Settings → Voice or on the car's Ask tab. And Settings → Appearance → CarPlay voice screen has four looks."),
                 phoneOnly: true),
            Item(symbol: "waveform", title: String(localized: "A sound while it thinks"),
                 detail: String(localized: "Settings → Voice → Thinking sound plays a quiet pulse while your agent works and nothing is being said, so silence isn't taken for a failure. And when the agent keeps a task list, the Live Activity shows how far it has got.")),
            Item(symbol: "photo.on.rectangle", title: String(localized: "Pictures, together"),
                 detail: String(localized: "Several pictures in a message stand together. Tap one to see it full screen, swipe to the next, and pinch or double-tap to zoom.")),
            Item(symbol: "checkmark.seal", title: String(localized: "Fixes", comment: "What's New: a heading over bug fixes"),
                 detail: String(localized: "Tapping a notification no longer closes Redde. Thinking can be folded away while a reply is still coming. “Jump to latest” goes away once you have scrolled back to the end of a conversation, and new text is followed from there again.")),
        ]),
        Release(version: "1.7.1", items: [
            Item(symbol: "mic", title: String(localized: "Voice on iPhone 11 and iPhone SE"),
                 detail: String(localized: "On an iPhone 11 or an iPhone SE (2nd generation), voice mode and the mic in the message field said your language wasn't available. Apple's newer speech recognition isn't on those iPhones, so Redde now listens with the one behind keyboard dictation. It stays on the iPhone, as before.")),
            Item(symbol: "car", title: String(localized: "CarPlay, in color"),
                 detail: String(localized: "The Ask tab's cards are wider and a color each: blue to Ask, gold to Talk, green for a New Chat. Settings → Appearance → CarPlay cards has five more looks. On the voice card, columns of lights jump with each syllable while Redde speaks, and a light sweeps to and fro while it thinks.")),
            Item(symbol: "play.circle", title: String(localized: "Audio that plays"),
                 detail: String(localized: "When your agent sends a sound file, such as a reply spoken by its speech tool, the conversation shows a player where the file's path used to be. Files your agent sent also come back when you open a chat again. Like pictures, this uses the Dashboard login in Settings → Connection details.")),
        ]),
        Release(version: "1.7", items: [
            Item(symbol: "bell.badge", title: String(localized: "Notified when Redde is closed"),
                 detail: String(localized: "Pair your Hermes in Settings → Voice → Notify when Redde is closed, and it tells this iPhone when a reply is ready or the agent waits for you. Approve, deny or answer from the notification. It takes a small plugin on your Hermes, which Redde installs for you over the Dashboard.")),
            Item(symbol: "waveform.badge.mic", title: String(localized: "Voice, your way"),
                 detail: String(localized: "Start speaking while Redde is answering and it stops to listen: on with headphones, and Settings → Voice → Talk over replies adds the speaker. Add stop phrases of your own there, and say “Hey Siri, ask Work in Redde” to talk to a Hermes profile.")),
            Item(symbol: "gearshape.2", title: String(localized: "Your server, from the phone"),
                 detail: String(localized: "Settings → Gateway shows what your Hermes is running, switches its MCP servers, reads its logs and restarts or updates it. Settings → Files opens its folders: look at a file, edit a text one, upload, delete. Both use the Dashboard login.")),
            Item(symbol: "checklist", title: String(localized: "The agent's plan, and two widgets"),
                 detail: String(localized: "When Hermes keeps a task list for a longer job, the reply shows it as a checklist. On the Home Screen or the Lock Screen, Needs you shows a command or a question that waits for you, and Context how full the model's context is.")),
            Item(symbol: "bolt", title: String(localized: "One conversation, its own way"),
                 detail: String(localized: "In the model menu on the Dashboard: Fast mode for models that have one, and Run commands without asking for a conversation you trust. Touch and hold a conversation in the list to move it to a project.")),
            Item(symbol: "car", title: String(localized: "In the car and on the wrist"),
                 detail: String(localized: "CarPlay has a new look: big buttons to Ask, Talk or start a New Chat, your chats on a tab of their own, and a voice card with a moving waveform, Mute and End. Apple Watch gets a list of your chats to carry one on, and Ask Redde as a complication for your watch face.")),
            Item(symbol: "square.and.pencil", title: String(localized: "Writing and reading"),
                 detail: String(localized: "Each conversation keeps its own draft. Dictate into the message field, paste a picture, attach a video, and open a long message on a page of its own. A text size for conversations in Settings → Appearance, and a ring in the header for how full the context is.")),
            Item(symbol: "person.badge.key", title: String(localized: "Sign in with a browser"),
                 detail: String(localized: "A Dashboard that signs you in with Google or another provider works now, and a server behind a reverse proxy can be sent the header it asks for. Both in Settings → Connection details.")),
            Item(symbol: "checkmark.seal", title: String(localized: "Fixes", comment: "What's New: a heading over bug fixes"),
                 detail: String(localized: "On Hermes 0.21.3 and later, approvals and the agent's questions reach you again over the Dashboard, a file attached there reaches the agent, and a message sent the moment a reply ends no longer comes back empty.")),
        ]),
        Release(version: "1.6", items: [
            Item(symbol: "applewatch", title: String(localized: "On your wrist"),
                 detail: String(localized: "Redde for Apple Watch: raise your wrist, tap Ask and say it. The answer is shown and read aloud. It asks through the Hermes API or your OpenAI-compatible endpoint: on the Dashboard, save the API address and key too, in Settings → Connection details.")),
            Item(symbol: "qrcode.viewfinder", title: String(localized: "Set up by code"),
                 detail: String(localized: "Scan a setup code and a server fills itself in. Settings → Connection → Set up another device shows the code for your iPad or a second phone.")),
            Item(symbol: "lock.iphone", title: String(localized: "A reply keeps going"),
                 detail: String(localized: "Lock the phone or switch apps, and the reply you asked for carries on to the end.")),
            Item(symbol: "sparkles", title: String(localized: "A place to start"),
                 detail: String(localized: "A new conversation opens with what's next on your calendar and the conversation you just left, one tap each.")),
            Item(symbol: "quote.bubble", title: String(localized: "Ask about part of a reply"),
                 detail: String(localized: "Choose Select text on a reply, select a sentence and tap Ask about this. It lands in your message as a quote.")),
            Item(symbol: "bolt", title: String(localized: "Long conversations, lighter"),
                 detail: String(localized: "A long thread takes a fraction of the memory it did and stays smooth while a reply streams.")),
        ]),
        Release(version: "1.5", items: [
            Item(symbol: "text.insert", title: String(localized: "Spoken prefixes"),
                 detail: String(localized: "Start a spoken message with a word of your choice and Redde swaps it for a text prefix, switches the conversation to a model you pick, or both. Off until you add one, in Settings → Voice. Typed messages are never changed.")),
            Item(symbol: "gauge.with.dots.needle.33percent", title: String(localized: "Reasoning effort, everywhere"),
                 detail: String(localized: "The level in Settings → Model now reaches whatever model you talk to, and the conversation you have open, not only new ones. Type /reasoning in a Hermes Dashboard chat to change just that one.")),
            Item(symbol: "brain", title: String(localized: "None", comment: "What's New: a new reasoning effort level, None, that skips thinking"),
                 detail: String(localized: "A new level that asks the model to skip thinking and answer straight away. Some models and servers decide that for themselves.")),
            Item(symbol: "airpods", title: String(localized: "Replies stay in your AirPods"),
                 detail: String(localized: "A question asked through AirPods sometimes got its answer from the phone's speaker. Not any more.")),
        ]),
        Release(version: "1.4", items: [
            Item(symbol: "server.rack", title: String(localized: "More than one server"),
                 detail: String(localized: "Save Home, Office or any other Hermes server and switch from Settings or the row above your conversations. Chats, cron jobs and Kanban follow the server you pick, and your setup is already the first one.")),
            Item(symbol: "globe", title: String(localized: "Your language"),
                 detail: String(localized: "Pick a Reply language and the language Redde listens for in Settings → Voice. Each reply is read by a voice for the language it's written in.")),
            Item(symbol: "hand.draw", title: String(localized: "Swipe to your conversations"),
                 detail: String(localized: "Swipe right on a chat and your conversation list slides in from the left. Tap the chat or drag it back to close."),
                 phoneOnly: true),
            Item(symbol: "rectangle.split.3x1", title: String(localized: "Room for your board"),
                 detail: String(localized: "Pick Kanban or Cron in the sidebar and it fills the screen beside it. Redde reopens where you left off."),
                 padOnly: true),
            Item(symbol: "arrow.up.forward.app", title: String(localized: "Choose where Redde opens"),
                 detail: String(localized: "Your last conversation, the conversation list or voice mode, in Settings → Voice. Voice mode can also start a new conversation every time.")),
            Item(symbol: "camera", title: String(localized: "Take a photo"),
                 detail: String(localized: "Tap + beside the message field and choose Camera to snap a picture and send it with your message.")),
            Item(symbol: "gauge.with.dots.needle.100percent", title: String(localized: "More thinking"),
                 detail: String(localized: "Reasoning effort now goes past High to X-High and Max, for frontier models like Claude and GPT. Find it in Settings → Model.")),
            Item(symbol: "speaker.wave.2", title: String(localized: "Louder replies"),
                 detail: String(localized: "Spoken replies play at full volume on the speaker, follow the volume buttons, and move to the earpiece when you raise the phone to your ear.")),
            Item(symbol: "hourglass", title: String(localized: "Long answers, better"),
                 detail: String(localized: "The live thinking keeps scrolling, each reply shows how long it took, and replies from your own model can take as long as they need.")),
            Item(symbol: "heart", title: String(localized: "Feed the goose"),
                 detail: String(localized: "Settings → About → Support Redde: leave a tip, a coffee, a snack or a dinner. It unlocks nothing; it keeps Redde going.")),
            Item(symbol: "checkmark.seal", title: String(localized: "Fixes", comment: "What's New: a heading over bug fixes"),
                 detail: String(localized: "Chats opened over the Hermes API load again, Redde says so when a profile is gone from a server, and Kokoro keeps talking when you switch to headphones.")),
        ]),
        Release(version: "1.3", items: [
            Item(symbol: "person.2", title: String(localized: "Hermes profiles"),
                 detail: String(localized: "Pick which profile Redde talks to, right under Name in Settings. Chats, projects, skills, tools, cron jobs and memory all follow it.")),
            Item(symbol: "key", title: String(localized: "A key for each profile"),
                 detail: String(localized: "On the Hermes API, each profile can have its own key, entered on the same screen. If something's wrong, Redde says how to fix it.")),
            Item(symbol: "network", title: String(localized: "Clearer connections"),
                 detail: String(localized: "Hermes Dashboard, Hermes API and OpenAI-compatible, now under Settings → Connection, with the Dashboard first.")),
            Item(symbol: "checkmark.seal", title: String(localized: "Fixes", comment: "What's New: a heading over bug fixes"),
                 detail: String(localized: "The Kanban column bar always shows, iPad's Chats, Cron and Kanban have room to breathe, and Settings explains locked memory files.")),
        ]),
    ]

    /// The app's version, e.g. "1.4".
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// What to show after an update from `lastSeen` to `current`: the current version's entry,
    /// once. Nothing on a fresh install (`isNewInstall`) or when the version has no entry.
    static func pending(lastSeen: String?, current: String, isNewInstall: Bool) -> Release? {
        guard !isNewInstall else { return nil }
        if let lastSeen, compare(lastSeen, current) != .orderedAscending { return nil }
        // The entries not seen yet, up to this version, newest first: a point release without
        // its own entry (1.4.2) still shows 1.4's to someone coming from 1.3, and nothing to
        // someone on 1.4.
        let unseen = releases.filter { release in
            compare(release.version, current) != .orderedDescending
                && lastSeen.map { compare(release.version, $0) == .orderedDescending } ?? true
        }
        guard let newest = unseen.first else { return nil }
        // A point release with an entry of its own (1.7.1) comes days after its version, and
        // most people reach it straight from the one before (1.6): they are shown what 1.7
        // brought as well, first, and someone on 1.7 only what is new since.
        let family = unseen.filter { sameMinor($0.version, newest.version) }
        return Release(version: newest.version, items: family.reversed().flatMap(\.items))
    }

    /// A version's highlights in full, as someone coming from the version before is shown them:
    /// what Settings → About opens.
    static func highlights(of version: String) -> Release? {
        pending(lastSeen: nil, current: version, isNewInstall: false)
    }

    /// "1.7.1" belongs to "1.7"; "1.8" does not.
    private static func sameMinor(_ a: String, _ b: String) -> Bool {
        a.split(separator: ".").prefix(2).elementsEqual(b.split(separator: ".").prefix(2))
    }

    /// Numeric, component by component: "1.10" is newer than "1.9".
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0 ..< max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    // MARK: - Seen state

    private static let seenKey = "whatsNewSeenVersion"

    static var lastSeen: String? { UserDefaults.standard.string(forKey: seenKey) }
    static func markSeen(_ version: String = currentVersion) { UserDefaults.standard.set(version, forKey: seenKey) }
}
