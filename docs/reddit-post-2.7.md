# Reddit post: 2.7, Proactive

Drafted 2026-11-22 while 2.7 (296) waits for review. Post it the day 2.7 goes live, and change
"out today" if it goes up on a later day. The store now bills Redde as "Redde: Proactive AI", so
this post leads with the proactive work; agents asking each other comes second.

Media: there's no proactive video yet. Either post it as a text post, or attach the 2.7 App Preview
(`design/redde-27-app-preview-iphone.mp4`, agents asking each other, 29 s) and say so in the first
line. A screenshot of Things to Keep in Mind next to a heads-up that caught something would show
the lead best, once one has happened for real.

Paste it as a clipboard with rich text and Markdown (as for 2.3.1 and 2.6): Reddit's rich editor
shows raw Markdown otherwise. Check the preview before posting.

Before posting:

- Publish the plugin's GitHub release redde-push-1.36.0 first: Settings → Redde Plugin offers the
  update from it, and most of what's below needs 1.36.
- Lines to keep only once seen working on a real server with plugin 1.36 (so far only the plugin
  tests and the simulator have run them):
    - a heads-up that brings up a kept fact (the insurance example);
    - When You've Gone Quiet waking after a quiet stretch, and staying silent otherwise;
    - a watch slowing after two days of nothing.
- The App Store link is by id, so the old "hermes-redde" slug doesn't show.

## Title

Redde 2.7: your agent gets ahead of your day, and knows when to stay quiet

## Body

**Redde 2.7 is about being proactive without nagging. Your agent checks your plans against what you've told it, speaks up when something's missing, and otherwise stays quiet.**

Redde is a free iPhone, iPad, Mac, Apple Watch and CarPlay app for your own agents: Hermes, Claude Code, Codex and anything else that speaks ACP. 2.7 is out today.

**As always, privacy comes first. Your chats go from your phone to your own server and on to the providers you choose, on your own keys. Nothing comes back to me.**

### Things to keep in mind

- **Tell your agent once what's always true for you**, and its Heads-Ups, Morning Ideas and Week Ahead check every plan against it. They look at the days around each event too (the trip before it, the stay after it), and check your mail and calendar before they say anything.
    - Try: *"Whenever I drive into France I need the 3-day car insurance."* If the hotel booking runs a day past the policy, the heads-up says so, with what to do.
- **See and change the list** in Settings → Your Day → Things to Keep in Mind. Every bot reads the same list.

### Quieter on its own

- **When You've Gone Quiet**, a new Daily Job: after 12 to 72 hours without a word from you, your agent looks at what's waiting (an approval, a follow-up, tomorrow) and speaks up only if something needs you. Otherwise it runs without the model at all.
- **At Most a Day** in Quiet Hours: a cap on how many notifications reach you each day.
- **Ideas you leave alone come quietly**, into the drawer instead of a buzz, until you touch one again. **Don't Suggest This** on an idea keeps it away for good.
- **A watch that keeps finding nothing slows down**, then pauses, and tells you once.
- **A goal untouched for two weeks** asks whether you still want it, then pauses its check-ins. Keep Going brings it back.

### Goals you tick off

- A goal's plan now says which steps are yours and which are your agent's. Tick yours off from the goal or its Today tile. Your agent starts on its own steps as soon as you agree the plan, and asks about yours at its check-ins.
    - Try: *"Help me get the garage cleared out by Christmas."*

### Your agents ask each other

- **@mention any agent from any chat:** your Hermes bots, Claude Code and Codex on your bridge, and the bots on your other servers. Or let your agent ask one itself. The answer shows in your chat and your agent carries on with it, read aloud in voice mode.
    - Try: in Sol's chat, *"Ask @claude-code why the build is failing."*
- **Ask Me First**, on from the start: before one agent asks another, Redde asks you, on a card or out loud. Settings → Replies & Writing → Agents Talking to Each Other.

### Also in 2.7

- **Skills from Hermes's skills hub:** find one, see what it does, and install it, checked by Hermes's scanner first.
- **Pictures in agent chats:** what Claude Code or Codex sends or reads shows inline, and a file a reply names opens on your phone.
- **Save pictures** to Photos from any chat.
- **Briefings on Your Day:** switch each on or off, and what you've read is the same on every device. Clear a notification on one device and it's gone on the others.
- **A long paste** goes beside your message as a text file.
- **Report a Problem**, at the bottom of Settings: a report of your setup with nothing private in it, to copy or open as a GitHub issue.
- **Hermes 0.23** and its Webapp, smoother typing, and fixes for GitHub #78, #79, #81 and #83. Thanks for those reports.

The proactive pieces take the Redde plugin 1.36 on your Hermes: Settings → Redde Plugin offers the update. Pictures in agent chats take the Redde bridge 0.11.

App Store: https://apps.apple.com/app/id6810900557
Source: https://github.com/goosehouse-llc/redde

What's the one thing you'd want your agent to always keep in mind? Feedback and bug reports welcome.
