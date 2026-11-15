# Reddit post: 2.6, More agents

Drafted 2026-11-14 while 2.6 (295) waits for review. Post it the day 2.6 goes live, as a video post
with `design/video/redde-agents-reddit.mp4` (switching agents, several agents at once) and the body
below as its text. Change "out today" if it goes up on a later day.

Paste it as a clipboard with rich text and Markdown (as for 2.3.1): Reddit's rich editor shows raw
Markdown otherwise. Check the preview before posting.

Lines to check first, each kept only once seen working with 2.6, plugin 1.31 and bridge 0.10.1:

- The bridge's one-line install on a clean Mac, and Claude Code and Codex through it.
- Adding an agent from the registry from the phone (Pi or OpenCode).
- CarPlay with more than four bots (the All Bots card) and the Server row: the 11-14 fix, not yet
  tried in the car.
- 2.4 and 2.5 never got posts of their own; if they did, cut "Since the last post".

## Title

Redde 2.6: Claude Code, Codex, Antigravity and your Hermes bots, in one app

## Body

**Redde started as a voice and chat app for Hermes. With 2.6 it talks to other agents too: Claude Code, Codex, Antigravity, Gemini CLI and anything else that speaks ACP.**

**The video shows the part I use most: hopping between agents, and getting several of them on one job.**

Redde is a free iPhone, iPad, Mac, Apple Watch and CarPlay app for your own agents, and 2.6 is out today.

**As always, privacy comes first. Your chats go from your phone to your own computer and your own server, and on to the providers you choose, on your own keys. Nothing comes back to me.**

### Other agents, through the Redde bridge

- **The Redde bridge** is a small free program on your Mac or Linux box that hands your phone to the agents installed there. One line installs it, then scan its code in Redde:
    - `curl -fsSL https://raw.githubusercontent.com/goosehouse-llc/redde/main/companion/redde-bridge/install.sh | sh`
- **Everything you'd see at the terminal**, on your phone: steps, file changes as diffs, approvals, plans and questions, with notifications when Redde is closed. Chat or talk, in the car too.
    - Try: *"Fix the failing test in the notes app and show me the diff."* Approve it from the Lock Screen.
- **Pick the mode and model**, steer a reply mid-way, fork a chat, send a PDF, and see your plan's usage, where the agent offers it.
- **More agents from your phone**, from the official ACP registry: Pi, OpenCode, Cursor and dozens more. Update the bridge from the app too.
- **OpenClaw too**, through its Gateway: thinking, tool steps, approvals and slash commands (no file changes, since OpenClaw's own bridge doesn't send them). It's new, so tell me how it goes.
- **No computer handy?** Try the Demo Agent built into Redde (Set up connection → Claude Code, Codex and others → Try the Demo Agent).

### Switching and teaming up

- **All Agents:** every agent on a bridge in one list, or pick one from the chat list's title. Hold New Chat to start a chat on another server or agent.
- **Your Hermes bots stay put** while you're on the bridge, so Sol, your writer and your researcher are a tap away from Claude Code.
- **Bots that work together:** @mention one bot from another's chat, and you see it at work, its current step and its answer.
    - Try: in Sol's chat, *"@Quill tighten the opening of this post."*
- **Group chats:** a few bots in one room, each answering in turn; in voice mode, each in its own voice.
    - Try: in a group with your research and writing bots, *"Plan a weekend in Asheville."*
- **Workstreams:** ask any bot to work on something in the background. It hands the job to a chat of its own and tells you when it's done or needs you.

### A new drawer

- **The chat list starts with what needs you:** your next event, what's waiting, working and unread, approvals as a stack, and your bots in a row. Today, Planned, Board and Made are pages of their own.
- **Arcade**, a new theme: neon on navy by night, lavender by day.

### Also in 2.6

- **Inbox piles:** seven of them, with Receipts, Notifications and Promotions, plus up to eight of your own.
    - Try: *"Make a pile for anything from the kids' school."*
- **Maps for your agent:** places near you, how long the way takes with traffic now, and Apple Maps opened ready to go (Phone Tools → Maps).
    - Try: *"How long to the airport right now?"*
- **Price cards** with a deal meter, every store in one row, and Watch price.
    - Try: *"Find me noise-cancelling headphones under $300."*
- **Quote any message** in your next one, and suggested replies: a reply's options become chips at once.
- **CarPlay:** switch servers from the Ask tab, and an All Bots card when you have more bots than fit.
- Faster launch, typing and opening a chat.

### Since the last post: 2.4 and 2.5

- **Goals** with a plan, check-ins and how far along you are. **Memory you can see** and edit, and bring in what ChatGPT or Claude remembered.
- **Your Inbox:** Gmail or any mailbox, sorted on your server, and nothing sends until you approve it.
- **Apple Home and Health** as phone tools, off until you turn them on.
- **Models & Providers:** set your Hermes's models, fallbacks and keys from your phone.
- **Local calls:** a live call with no key and no bill, heard on the device.
- **Better battery life**, and bot photos.

Most of the Hermes side takes the Redde plugin 1.31: Settings → Redde Plugin offers the update. Other agents take the Redde bridge 0.10.

App Store: https://apps.apple.com/us/app/hermes-redde/id6810900557
Source: https://github.com/goosehouse-llc/redde

Which agent would you put on your phone first? Feedback and bug reports welcome.
