# Reddit post: 2.3.1, Proactive

Drafted 2026-11-02, before 2.3.1 is on the App Store. Post it the day 2.3.1 goes live, as a video
post with `design/redde-day23-reddit.mp4` (59.4 s, "A day with Redde") and the body below as its
text. Change "out today" if it is posted on a later day.

Lines to check first, each kept only once it has been seen working on a phone with 2.3.1 and the
Redde plugin 1.14 on the Hermes:

- Morning Ideas arriving three mornings running (one good day in three on 10-29 to 10-31, before
  the calendar-call wording and the tool-call patch).
- A Places arrival firing on the way in, not at the door (10-31: a 0.5-mile arrival came late).
- A Shortcuts automation with "Ask a Redde Bot a Question"; a watch handed to another agent; the
  Quiet Hours digest. None has been run for real yet.
- The purchase card, asked as below (plugin 1.14.4).
- 2.2's lines: a scheduled call ("if the garage is still open at 11 tonight, call me": the agent has to
  set a job that calls) and "Home, …" switching the call to Home's voice. GPT-Live is in every
  build since it moved to WebSocket (no GPT_LIVE flag left), so it stays.

## Title

Redde 2.3.1: Proactive. This is where it gets fun...

## Body

**Until now, I've focused on the standard features we all know and love: chats, bots, voice. **
**Now it's time for proactive ones: an agent that acts before you ask, closing the gap with Grok Bot, Muse and the like.**

The video is one day with it. Crammed, trying to show as much as possible in the one minute I can. But there's far more new than fits in a minute, so below is everything, each with something to say or try to see it for yourself. 2.2 slipped out without a post, so its voice features are at the end.

Redde is a free iPhone, iPad, Mac, Apple Watch and CarPlay app for your own Hermes agent, and 2.3.1 is out today.

Oh, and now a native macOS app too!

Most of it takes the Redde plugin on your Hermes. Settings → Agent → **Ahead of Your Day** installs or updates it and turns the daily jobs on in one step.

### **Your Hermes agent now gets ahead of your day, plus 2.2's live voice (too much for one video, so here's a list to try) **

**As always, privacy comes first. The proactive features are all off until you turn them on, and nothing comes back to me: your data goes only to your own server, and to services you choose, on your own keys.**

**Ahead of your day**

- **Morning Ideas.** A few things worth doing today, as cards to swipe: right to have your agent do it, left for not now. Hold one for More Like This, Fewer Like This or Later. It learns from your swipes.
  Try: turn it on, then tomorrow morning swipe the deck.
- **Heads-ups** before your events, with what to bring and who's coming.
  Try: *"Give me a heads-up 30 minutes before my dentist appointment with what I need to bring."*
- **Leave-By Alerts.** Redde checks your calendar and Apple Maps on your iPhone and tells you when to leave, by car, transit or on foot, with the traffic checked again close to the time.
  Try: add an event with a street address and wait for the nudge.
- **Week Ahead** on Sunday and an **Evening Wrap-up** each night.
  Try: *"What does my week look like?"*
- **Up Next** on your Home Screen counts down to your next event and shows what's waiting for you.
- **Health-aware days**, if you allow it: last night's sleep and today's steps shape your ideas and wrap-up. Off until you turn it on, and the numbers only go to your own server.

**It comes back on its own**

- **Watches.** Your agent keeps checking and tells you only when something changes.
  Try: *"Keep an eye on the price of AirPods Pro and tell me if it drops below $180."*
- **Follow-ups.** Loose ends don't get dropped.
  Try: *"Check back with me Friday about the contractor's quote."*
- **Hand-offs.** A watch can wake another bot instead of you.
  Try: *"Watch the NAS's free space every morning and hand it to Ops if it drops under 10%."*

**It reacts to your day**

- **Places.** Set Home, Work or the gym. Arriving or leaving tells the agent you choose.
  Try: Settings → Agent → Places → Home → when I arrive, *"Turn on the porch light."*
- **Shortcuts triggers.** "Ask a Redde Bot a Question" works in any automation.
  Try: when CarPlay connects, ask Home *"Is the garage door closed?"*
- **Routines.** Any chat can become a routine: the menu → Make This a Routine, with a schedule if you like.
  Try: *"Every weekday at 7, tell me what to wear for the weather."*
- **Quiet Hours** hold the non-urgent ones and hand you a short digest when they end.
- **Agent Activity** is the log of everything your agents did on their own, and **Before Acting** sets how much each one may do unasked.

**Answers as cards**

Ask for these and the answer comes as a card, not a wall of text:

- *"What's on my calendar tomorrow?"* Your day as a timeline, free time marked. Tap a gap to add an event.
- *"Will it rain this afternoon?"* The weather by the hour.
- *"Coffee shops within a 10-minute walk."* Places on a map, with ratings and hours.
- *"Find me cheap options for a 5090."* Products to buy, with your agent's pick, prices, ratings and stock.
- *"Compare the Sony XM6 and the AirPods Max."* Side by side.
- *"Draft an email to my landlord about the leak."* An email to check and edit before it goes.
- *"Packing list for a weekend in Boston."* A checklist with a progress ring.
- *"Turn off the office lights."* Your home's devices, with toggle controls.
- *"Set a timer for 12 minutes."* A countdown.
- *"Did the Heat win last night?"*, *"Chili for 6"*, *"Is AA 1234 on time?"*, *"Where can I watch Severance?"*, *"180 °C in Fahrenheit"*, *"How's NVDA today?"*: scores, recipes that scale, flights, where to watch, conversions and stocks.

**Also in 2.3.1**

- **Redde for Mac**, a native app with menus, shortcuts and text zoom. It's included in the same free download.
- **17 languages.** The whole app, and voice mode listens and answers in the one you pick.
- **Approvals in plain words.** Before your agent runs something, the card says what it will delete (in red), what it changes, and whether Hermes restarts.
- **Keys asked for.** When your agent needs an API key, it asks in Redde, and what you paste goes sealed straight to your server, never into the chat.
- **Current Location**, if you turn it on: your agent hears roughly where you are, only when you ask about places, directions or the weather.
- **US or metric**, for your agent, the weather and distances.

**And 2.2, which never got a post: Voice**

- **Live voice.** Voice mode becomes a real call: pick ElevenLabs, GPT-Live, Gemini Live or Grok Voice in Settings → Voice → Voice mode and add your key. It talks and listens at once, so you can interrupt it. It answers small talk itself, and anything real goes to your agent, then it says the answer in its own words. Each service bills your key per minute.
  Try: mid-answer, cut in with *"Actually, make it tomorrow instead."*
- **Your agents can call you.** Turn on Calls from Agents (Settings → Notifications) and pick who may. When something shouldn't wait, it rings like a phone call, Lock Screen included, and tells you why in its own voice.
  Try: *"If the garage is still open at 11 tonight, call me."*
- **A voice for every bot.** Each bot can have its own engine and voice (Edit Bot → Voice), with a sample of every voice before you pick it.
  Try: in a call, *"Home, is the back door locked?"* Home answers, in Home's voice.
- **Wake phrases.** With Redde open on your iPhone, iPad or your car's screen, say "Hey" and an agent's name. It listens on the device, and it's off until you turn it on (Settings → Voice → Wake Phrase).
  Try: *"Hey Home, turn the lights off."*
- **Group chats as calls.** Voice mode in a group chat is a live call: each bot answers in its own voice.
  Try: in a group with your research and writing bots, *"Plan a weekend in Asheville."*
- **ElevenLabs reads your replies**, on your own key, each bot in an ElevenLabs voice of its own. Kokoro voices can be blended.
- **Plugins.** Settings → Plugins browses Nous Research's catalog and installs Hermes plugins for your agent or one bot. Official and verified ones come first, and you see what each sends, costs and adds before you install it.
- **Bots make Kanban cards**, in their own chats and in group chats.
  Try: *"Make a Kanban card to renew the car registration by the 15th."*
- **A wallpaper** behind your chats, with the text, and light or dark, following it.
- **On Apple Watch**, each bot reads its replies in its own voice.

App Store: https://apps.apple.com/us/app/hermes-redde/id6810900557
Source: https://github.com/goosehouse-llc/redde

What would you have your agent watch for you? Feedback and bug reports welcome.
