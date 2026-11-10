# Changelog

What changed in each version of the Redde plugin (`redde-push`). Redde offers an update, in
Settings › Redde Plugin, to a Hermes whose plugin is older than the one the app goes with.

## 1.21.1 (2026-11-10)

- The phone's calendar tool is found when the agent searches for "agenda", "schedule",
  "meetings" or "appointments". Hermes's tool search lists a tool by its first sentence, which
  said only that the tool runs on the iPhone, and finds nothing for a query whose rarest word no
  tool has: asked for its agenda, an agent found no calendar and went looking elsewhere.

- A bot's schedule that answers in the bot's chat now notifies you with what the bot said there,
  not with the run's raw output. Hermes hands the run's output to the bot, which reads it and
  sums it up in its chat, and that chat is what a tap opens: the notification and the chat said
  two different things. (GitHub issue 63.) The plugin waits up to ten minutes for the bot's
  answer, then sends the output as before. It reads the bot's own `state.db`, read-only.
- A briefing's notification carries the session its run was in, so Redde can open that on a tap
  (a setting, off at first; GitHub issue 62). Each scheduled run writes its session down as it
  starts, in `redde-push/cron-runs.json`. Older versions of Redde leave it alone.

## 1.21.0 (2026-11-09)

- What Redde tells the agent with a message no longer has to be written into the message. Your
  reply language, your units, which calendars to look at and, on a question about places, roughly
  where you are went after the message as a note, "(Reply in Dutch.)", "(The user is near …)":
  the Dashboard takes no instructions with a message. Redde hid the note, but Hermes Desktop and
  every other app showed it, and so did the first line of the chat in the chat list. Redde after 2.4
  hands the note to the plugin instead, just before the message, and the plugin gives
  it to the model with that message only. The message is stored as you typed it. (GitHub issue
  72.) Older versions of Redde, and a Hermes without this version, work as before.
- The note is kept on the server for a moment, in `turn-notes.json`, readable only by you, and
  removed when the message's turn starts, or after two hours if it never does.

## 1.20.3 (2026-11-09)

- "Send me a message at 7am tomorrow that says good morning" is taken for what it is, a reminder.
  It got the note for emails and messages sent to somebody else, and the agent then set it up as
  a job that wakes a model, or set nothing. Tried with the local model nine asks three times
  each: all 27 set right, where 25 were.
- A reminder card sent without its `type` is still a reminder (a model left it out about one time
  in four: `kind` says what it is). It was turned away and the agent sent the card again.

## 1.20.2 (2026-11-09)

- A long pasted message (a log, a file) no longer holds a reply up. Before each answer the plugin
  reads the message to see what was asked for; over a long text with no full stops that took up to
  two seconds. It now reads the start and the end of a long message, where the asking is.
- A snooze set while the inbox was being checked is kept. The check read the account, talked to
  the mail server for a few seconds and saved everything it had read, so a snooze, a queued labels
  job or an email archived in those seconds was written over, and a snoozed email whose time was
  lost never came back. What changed meanwhile is now merged in, across Hermes's processes too.
- Fewer cards asked for by mistake: `echo $HOME` and "stock Ubuntu" are no share price, a temp
  file is no weather, clock skew and time zones in code are no asking the time, a BM25 score is no
  game, "the lights PR" is no home, and "send me the logs", "the error message", "a good book" or
  "order the results by date" ask for no review card. "What's on my schedule" is no scheduled job.

## 1.20.1 (2026-11-09)

- A reminder goes in Apple Reminders on the iPhone. Asked to remind you, an agent used to make a
  Redde notification on the Hermes (a "[redde-notify]" job), so nothing showed in Reminders. Now it
  uses the phone's Reminders tool first, so the reminder alerts on the iPhone, shows in Reminders
  and lands on the To Do list on its day. A job on the Hermes is only for when phone tools are off,
  and for a message at a time. The reminder's id goes on the card, for its Change and Cancel.

## 1.20.0 (2026-11-09)

- Lists: ask any agent for a to-do list (or groceries, packing, chores…) and it keeps it with
  `redde_list`. Each list is a tile on Redde's Today row, right after the Inbox, and stays there
  until it's deleted. Add to a list, check things off or clear the done ones in any chat, or on the
  phone. The lists are kept on this Hermes, the same for every bot.

## 1.19.6 (2026-11-08)

- A watch asked for in any chat (`keep_an_eye_on`) is made on the Watcher bot when the Hermes has a
  profile named `watcher`, so it runs with Watcher's tools and model. Without one, nothing changes:
  the watch stays with the agent that was asked. Redde's New Watch and its templates pick Watcher
  the same way.

## 1.19.5 (2026-11-08)

- A scheduled run with a long answer is asked to open with the outcome in one bold line and give
  the rest as a short numbered list, each point opening in bold. Redde lays that out as cards
  instead of a wall of text.
- A first paragraph that ends by announcing the report ("I have enough. Let me report the
  findings.") is left out of what reaches the phone, like the model's other working words. One
  that opens "Let me know…" stays.

## 1.19.4 (2026-11-06)

- A calendar card's events carry their calendar's colour (`color`, as the phone's calendar tool
  and Redde's calendar server now give it), so an iPad or a Mac that can't see that calendar
  draws it the colour it is on the iPhone.

## 1.19.3 (2026-11-06)

- An email's preview in the Inbox is its words: the start of the message read and decoded, not
  the raw parts of a multipart email (boundaries, headers, `=20`, base64, stylesheets).
- A goal's check-in keeps the rest of its report (a table, a list) with the goal, lines and all,
  for the goal's page in Redde.

## 1.19.2 (2026-11-06)

- An email read in Redde comes with its HTML too, so the reader shows it as its sender laid it
  out, pictures and all. Pictures sent inside the email are put in (up to 1.5 MB); pictures on
  the web load in the reader. Scripts, frames and page refreshes are taken out; an email over
  400 KB of HTML shows as text. The agent still gets the text alone.
- Unsubscribe from the app takes several emails at once (the Inbox's Select); one that can't be
  done is said, the rest still go.

## 1.19.1 (2026-11-06)

- A tagging rule can add several labels, up to five: the first stays in `arg`, the rest go in
  `also`. A plugin older than this keeps only the first. Agent Activity names them all
  ("Tagged Receipts, Paperless: Shop"), and Undo takes off every one the rule added, leaving any
  the email had already. Undo still works on entries written before this.
- `redde_mail` answers no longer say `"failed": []` when nothing failed. Hermes 0.22 reads "failed"
  near the start of an answer as a failed call and stops the turn after 8, so an agent
  unsubscribing from a pile of newsletters was stopped after 8 that worked. What wasn't done is now
  `not_done`, with why; an answer is an error only when nothing was done.
- The agent can unsubscribe from up to 25 senders in one call, behind one approval, and the
  approval names them ("Unsubscribe from 3 senders: Peacock, Carvana, YouTube"), where it said
  only "a sender's emails". Moving emails to the trash names each email too.

## 1.19.0 (2026-11-05)

- Notifications where you are: a device Redde is in use on says so (`/redde-push here <devices>
  <until>`), again every minute or so, and 0 as it is left. While one is, notes go only to the
  devices in use: at the Mac, the iPhone stays quiet, and the other way round. With none in use,
  every device gets them, as before. The widget's data, Leave-By wakes, calls and tests go where
  they always went. A device that stops saying so is forgotten within ten minutes at most.

## 1.18.1 (2026-11-05)

- Asked what's on the calendar, the agent is told that events it found in an email, a file or a
  page go on the agenda card too, with a `source` saying where ("From your email"), never an empty
  day for one that has them. Redde shows the source under the card (2026-11-05: Dec 17's
  appointments were in an attachment, and the card said "Nothing on your calendar"). Only in that
  turn's note: the card tool's description, in every prompt, is unchanged.

## 1.18.0 (2026-11-05)

- A card whose list came as JSON text (a review's "fields" written as a string) is drawn: the
  text is read as the list it is. Before, the check took its letters for labels, told the agent
  the card was shown, and the phone drew nothing (2026-11-05, a calendar copy Sol asked about).
- A watch whose answer opens by saying nothing changed stays quiet too (2026-11-05: a GTA 6 watch
  sent "Based on my research, here's the current status: **No price changes.** …" to the phone
  twice in a morning). A lead-in ending in a colon is skipped; a "but", "however" or "back in
  stock" in that opening paragraph still sends it.
- Email: a rule's switch and Add Tagging Rule work. Redde sent the rules wrapped in an object and
  `mail rules set` takes a list, so every save was turned down ("Rules are a list."); both are
  taken now, and Redde sends the list (2026-11-05).
- Email: `act group <ids> <important|needs_reply|fyi|newsletters>` puts an email in another of
  Redde's groups (an email's hold menu in Redde), kept there through later syncs, its Redde/…
  label in Gmail changed with it. Nothing moves on the mail server.
- Email: more receipts are spotted: "Your Amazon.com order of …", "Order shipped", and mail from
  auto-confirm@, shipment-tracking@, order-update@ and the like.
- A job the phone hides (Redde's Don't Show on a briefing, a "j:<profile>|<job>" mute) sends
  nothing.

## 1.17.0 (2026-11-05)

For Redde's email (asked 2026-11-03: "clear and smart email inbox control", for every Redde user,
not only Gmail).

- Email accounts over IMAP and SMTP with an app password (Gmail, iCloud, Fastmail, Yahoo, others;
  Outlook only where Microsoft still allows it), kept as `REDDE_MAIL_*` in the main .env through
  Redde's Keys Asked For; extra accounts with `REDDE_MAIL_ACCOUNTS`. A Hermes with the
  google-workspace skill's Gmail sign-in gets that account on the Gmail API too. Hermes's hosted
  Gmail connector is named, not used.
- The inbox is looked at every few minutes (2 to 30, 3 by default) from the schedules' thread:
  sender, subject, a 120-character snippet and flags, never whole emails. Sorted into important,
  needs reply, FYI and newsletters (receipts there, marked) by rules first (Gmail's categories,
  list and bulk headers, receipts); only what is left goes to the model, eight at a time, sender,
  subject and snippet only, as data. `mail settings` turns the model's part off.
- The person's rules (archive, mark read, label, move, tell me) run on every new email with no
  model; every action is logged and undoable (`mail log`, `mail act undo`). Rules never delete.
- `/redde-push mail …` for the app: status, list, read, act (archive, read, flag, trash, move,
  label, snooze, unsubscribe, undo), draft-edit, draft-send, rules, log, setup-check, settings.
  One-click unsubscribe (RFC 8058) on the person's tap. Snoozed email comes back by itself.
- `redde_mail` for the agent, offered once an account works: reading is data, never instructions;
  replies are drafts shown as an email review card, sent only unchanged (by hash) and after
  Hermes's approval; trashing and an agent's unsubscribe are approved too. While an account is set
  up, other ways of sending mail (himalaya, google_api.py gmail send/reply, the Nous Gmail
  connector's send, trash and delete) are blocked and pointed at `redde_mail`.
- Setting up from the app: `/redde-push keys ask <REDDE_MAIL_…> default <why>` opens a Keys Asked
  For request (only email's names, only the main profile), `mail setup <json>` writes the settings
  that aren't secret, and a key set counts at once, no restart. `mail brief` (also in `mail
  status`): the counts and who waits on a reply, for the morning briefing's email page.
- An `inbox` card for `redde_show`; asked about email, the agent is told how (that turn only);
  briefings get the inbox's counts and who waits on a reply.
- Run On: a scheduled job can run on a model of its own. Over the Hermes API, Redde marks the job's
  name ` [redde-model:<model>|<provider>]` (` [redde-model:|]` for the main model); every half minute,
  phone paired or not, the plugin gives the job that model and takes the mark off. New Dashboard
  command `/redde-push job-model <profile> <job> <model|-> <provider|->`. Job names read without the
  mark everywhere.
- Remember that… / Forget that…: a short note on those messages only, so the agent keeps one clean
  entry in its memory, or removes it, and says so in a line.
- Imported memories can go to long-term memory: your memory provider (through the agent), Basic
  Memory or the memory graph (written directly, no model call), or a notes file
  (`/redde-push memory stores|save`).
- Phone tools: Apple Home. With Apple Home on in Redde (Settings › Phone tools), your agent can list
  your HomeKit accessories and scenes, change them and run scenes: `phone_home_list`,
  `phone_home_set`, `phone_home_scene`, offered only while it is on. Locks, garage doors, doors,
  windows and the alarm are always put to you on the phone.
- Gmail shows Redde's sorting, per account and off until turned on: each sorted email gets
  `Redde/Important`, `Redde/Needs Reply`, `Redde/FYI` or `Redde/Newsletters` (moved between groups,
  it loses the old one). Only labels are added; nothing is archived, moved or deleted for this.
  Gmail only (the Gmail API, or IMAP to Gmail with X-GM-LABELS); other providers have folders, which
  would mean copies of each email, so they aren't offered.
- Tagging rules: `do: "label"` with conditions on from, domain, to, cc, subject, the email's first
  lines, group, receipt and attachment (any, PDF, image), all of them or any one, on mail newer
  than 30 days unless set; an account of their own; "also archive" only when set. Run on new mail
  with no model, logged in Agent Activity and undoable (the label off, back in the inbox). The
  ready-made "Receipts with attachments → Paperless" rule is offered first, off, for Paperless-ngx's
  mail rule.
- `mail labels list <account>` (the account's labels to pick from), `mail labels backfill
  <account>` (the last 30 days, at most 2,000 emails, 100 a half minute) and `mail labels remove
  <account> groups|all` (takes off only labels Redde added, by what it wrote down; a label the
  person put on stays). `mail settings {"labels": {account: {"groups": true}}}`.
- Suggested rules, per account and off until turned on: patterns found with no model in what Redde
  already keeps (the same sender archived, deleted or labelled 3 times this month, newsletters left
  unread over two weeks, receipts or PDFs from one sender, people replied to again and again), each
  a proposed rule with a line of why, at most daily and five open. Kept apart from the rules and
  never run: nothing is labelled, archived or told about until the person accepts one (as it is or
  changed). A dismissed pattern isn't suggested again. New suggestions can come as one Morning Ideas
  card a week. `mail suggest list|refresh|accept|dismiss <account> [id] [json]`.

## 1.16.0 (2026-11-05)

For Redde 2.4: goals, Coming Up and watch templates.

- Goals: `redde_goal` (set, update, status, end). A plan's steps become Kanban cards in triage
  (tenant `redde-goal-<id>`), waiting for the person's approval in Redde; a `[redde-goal:<id>]`
  job checks in (Mondays at 9:00, or every other day when the goal is under two weeks away). Each
  check-in is told its goal's steps and answers with a `PROGRESS: n/m | … | …` line, kept in
  `redde-push/goals.json` and sent as a briefing with the goal's id (`o`) and progress (`q`).
  A message that sounds like a goal gets a short note; no other turn does.
- Skipping one run of a repeating job: the app marks its name ` [redde-skip:<when>]`, and the
  plugin moves the job on to the run after (Hermes's `compute_next_run`) and takes the mark off,
  every half minute, with or without a paired phone. `/redde-push skip <profile> <job> <when>`
  does it at once over the Dashboard. The schedules' reader now runs with no phone paired too.
- A watch whose run answers `NO EMAIL ACCESS` (Redde's email watch templates on a Hermes with no
  email MCP) is a watch note with `w` "noemail", sent once: the watch is paused.
- `/redde-push goals list`: every agent's goals for the app, as JSON; `/redde-push goals end
  <profile> <goal>` ends one (its job deleted). A goal's check-in job is the truth: a goal whose
  job is gone counts as ended, and its schedule is the job's.
- Phone tools: Health. With Health turned on in Redde (Settings › Phone tools › Health), your agent
  can read the Apple Health data you chose, read only: steps, heart rate, sleep nights, workouts and
  21 more kinds, as totals or averages by day, week or month. New tool `phone_health_read`, offered
  only while Health is on.

## 1.15.1 (2026-11-04)

- A quiet scheduled run stays quiet on the phone (issue 55). Hermes's records of runs that said
  nothing ("**Status:** silent (wakeAgent=false)", "silent (empty output)", a monitor's
  "no_change", a script gate's "agent skipped") have no "## Response", so the whole record came
  back as the answer and a note with the job's header went out; and under Notify All a cron
  turn's [SILENT] or NOTHING NEW was pushed as a reply. Both are dropped now, as are Hermes's
  bare SILENT / NO_REPLY; a run that says something, or fails, still comes through.
- A job with nothing new stays quiet. Sol's Strata check said "No change" to the phone every four
  hours (2026-11-05): its own prompt asked for that, over Hermes's [SILENT]. An answer whose last
  paragraph only says nothing changed ("No change.", "Nothing new", "No updates since the last
  check") now sends nothing, and Sol is told, when it makes a job for the phone, to have the prompt
  answer [SILENT] when nothing is new and to keep nothing in files between runs (scheduled runs
  can't write them).
- A reminder card is a reminder set. Asked "remind me to call the dentist before closing", Sol drew
  a card and said "Reminder set for 5 PM", then "3:30 instead" another card: nothing was ever set,
  so nothing went off. Now the reminder note says how (a `cronjob_manage` job named
  "[redde-notify] <what>" at the person's time, repeat 1; an alarm or a timer is
  `phone_alarms_set`; changing is `update` of that job, cancelling `remove`; a time already past
  today is asked about), and `redde_show` refuses a 'reminder' card in a turn where no tool set,
  changed, cancelled or listed one. The job's id goes onto the card (`job`), for its Change and
  Cancel. "Change the reminder …" and "cancel the alarm" get the note too.
- A reminder goes off on time and says what it is. Its run (a [redde-notify] job whose prompt is
  "Tell the person in one line: <what>") never reaches the model: the plugin answers it
  ("Reminder: stretch."), with no tools, through Hermes's llm_execution middleware (0.22+), and the
  notification goes out as the run starts; the schedules' reader doesn't send it again. Before, the
  8:05 "stretch" run tried to set a phone alarm for 7:00 and said it couldn't, four minutes late.
  Older Hermes runs reminders on the model, as before.
- A setter call that failed (Hermes turning the job down, the phone not answering) no longer lets a
  'reminder' card through.

## 1.15.0 (2026-11-03)

- The calendar and reminders can answer with Redde closed. With Phone tools › Keep a copy
  turned on, the iPhone hands the agent a read-only copy of what its calendar and reminders
  tools could already show, while Redde is open, and a read of either answers from that copy
  on the person's own Hermes — saying when it was last synced. The phone stays the source of
  truth: adding, changing and completing always go through it, and so does a `live` read;
  turning an area or the setting off wipes the copy, and the app can wipe it by hand.
  Issue 50.
- A scheduled job's run no longer waits for the phone: it can't be reached there, so a phone
  tool answers at once — from the copy when there is one, however old, and otherwise by saying
  the phone can't be reached and to go on without it (Morning Ideas waited two minutes a call).

## 1.14.5 (2026-11-02)

- A share asked about by its ticker or its company gets the stock note: "How is nvda today",
  "AAPL price", "how is Tesla doing today", "price of Nvidia", and any ticker in capitals after
  "how is" ("How did PLTR do this week?"). Not the NAS, HA, the TV and the like, not "Apple",
  "Meta" or "Target" without "stock", and not "how is AMD doing with the new driver". Sol had
  answered "How is nvda today" with a table.
- The card tool now tells the agent in every turn: a share's price is a 'stock' card, never a table.

## 1.14.4 (2026-11-01)

- A price word is asking what to buy: "cheap options for a 5090", "affordable standing desks", "a
  budget keyboard", "refurbished iPads" get the purchase note. Not "cheaper to drive", the cheapest
  gas, flight, fares or time, and not cheap eats or restaurants. Asked of Sol a third time, it
  answered with a table.
- The card tool now tells the agent in every turn: when you suggest things to buy, a 'purchase'
  card, never a table. The agent goes by what was meant, not only the words the note listens for.

## 1.14.3 (2026-11-01)

- "Find me a battery for my Boosted Rev" is asking what to buy: "find me a …", "get me a …",
  "where can I get a …" and "a replacement … for my …" get the purchase note (not a time, a photo,
  a file, a restaurant or a recipe). Sol had searched the web for four minutes and answered with a table.

## 1.14.2 (2026-11-01)

- More ways of asking what to buy get a purchase card: "buying options", "where to buy", "the
  best deals on", "lowest price for", "low price options". Asked of Sol for "a few buying options
  for 5090 graphics cards", the turn got no purchase note, and the answer was a table.

## 1.14.1 (2026-11-01)

- A card asked for by name alone ("Home card", "show me the score card") is the whole answer: the
  agent is told to show it and write nothing else, before, between or after its tool calls. Asked
  for the home card, Home had listed every light and switch, then shown the card.

## 1.14.0 (2026-10-31)

Purchase cards made real and current, whatever the model wrote. Asked for smart plugs, Home (a
local model with no web search) drew a purchase card of made-up products: dead Amazon links, no
pictures, guessed prices. Now `redde_show` reads each product's page itself before the card shows
(`products.py`), a few at once, about 4 seconds a page and 5 for the card at most:
- A dead link (the site isn't found or refuses connections, a 400, 404 or 410, a page that says it
  isn't there, or a redirect to the store's home or search page) is taken off its product, which
  stays; the agent hears "links removed (dead): …".
- A page that loads gives what is true now, from its schema.org Product data (also in `@graph` or
  a list), its microdata, its Open Graph and product metas, and Amazon's own buy box: the price and
  currency (the page's win over the agent's; a "was" price at or below it is dropped), whether it
  is in stock (`availability`: `in_stock` or `out_of_stock`, new), the picture where the product
  had none, the rating, reviews and brand where the agent gave none. Such a product is marked
  `checked` (ISO time, new) and the card's note says "Prices checked Oct 31, 3:42 PM" (in the
  phone's time zone, else UTC).
- A store that won't show a program its page (401, 403, 429, 503, Amazon's Robot Check, a captcha)
  leaves the product as the agent wrote it; the agent hears it is not checked. So does a page too
  slow, broken or not a web page. With every link unreachable at once, this server is taken to be
  offline and nothing is removed.
- Only public web pages are read: http and https on ports 80 and 443, the name looked up and every
  address it gives checked (no loopback, private, link-local, CGNAT 100.64/10 such as a tailnet,
  multicast or reserved address, IPv4-mapped included), redirects followed by hand (three at most)
  and checked again, the visit made to the address that was checked. No cookies, no keys, nothing
  new to install. Findings are kept ten minutes by address. Other cards are untouched; the schema
  is unchanged.

## 1.13.3 (2026-10-31)

- More ways of asking what to buy give the purchase note: "looking to buy", "want to get",
  "shopping for", "recommendations … to buy", "what … to buy".

## 1.13.2 (2026-10-31)

- Asked what to buy, a 'review' card (the card for an order about to be placed) without a 'purchase'
  card is sent back with the purchase card's shape, so the retry is the right card. Asked "I'm
  looking to buy a smart plug … recommend a couple", Home drew a review twice, the purchase note
  notwithstanding. The turn is remembered by its session for 15 minutes; asked to place an order,
  a review is a review again.

## 1.13.1 (2026-10-31)

Scheduled answers as the person should read them (from a look at three days of them)
- An answer with `[SILENT]` anywhere in it says nothing: Hermes keeps quiet only for exactly
  `[SILENT]`, and models wrote a line of their own before it, so quiet evenings still came as
  "Nothing to report".
- `[CRON_FAILURE]` at the start of an answer is a failed run, with what follows as the reason.
- The model's account of what it was doing ahead of the answer ("Now let me compile the morning
  meeting brief." and a `---`, or "I have all the information needed. Here's the notification:") is
  left out; a paragraph with anything found in it stays.
- Every scheduled run, where a phone is paired, is told in one line that its answer reaches the
  phone as written, to answer exactly `[SILENT]` when there is nothing to tell, and to call deferred
  tools one at a time by name.
- A heads-up that can't find its event now says it couldn't confirm it, never that it isn't on the
  calendar (one said so of a meeting the morning's look had found).

## 1.13.0 (2026-10-31)

Six more cards for `redde_show`, drawn by Redde 2.3.1
- `recipe`: a recipe the agent looked up, with its source and page, picture, prep, cook and total
  times, the servings its amounts are for (Redde scales them on the phone), ingredients to tick
  off and numbered steps ("a recipe for banana bread", "what can I make for dinner with chicken").
- `delivery`: a package's tracking: what's in it, the carrier, the number, the carrier's words for
  where it stands, the day it should come, and the scans ("where's my package?").
- `flight`: a flight, or a trip's legs, each end with its airport code, city, terminal, gate and
  its time in that airport's own zone, the new time when it is late, the status and the seat ("is
  my flight on time?"). Not booking one, or fares.
- `show`: films and series, with year, format, seasons or runtime, genres, ratings as found, an
  overview, who made it, where it streams (the services' names), poster, trailer and page.
- `conversion`: an amount from one unit to another, which Redde works out again on the phone as
  the person changes it, or one currency to another at the rate the agent found, with when.
- `stock`: share prices with the change since the last close, the day's prices for a line, the
  day's range, market cap and when the price is from. Redde never buys or sells anything.

Each card's shape is in a line added to the turn only when the person's message asks for that kind
of thing (in English), ordered so the 1.12.0 cards keep their asks ("remind me when my package
arrives" stays a reminder), and in the tool's error when a card comes without it. Every new line
says to look the thing up first and never to make up a price, a time, a status, a rating or a link;
the delivery and flight lines carry the person's time. The schema gains only the six names: 5,907
characters (from 5,735), its description 1,615 (from 1,506).

## 1.12.0 (2026-10-30)

Five more cards for `redde_show`, drawn by Redde 2.3.1
- `purchase`: products to buy, the agent's pick first (each with its price, currency, old price,
  rating, reviews, store, page, picture, badge, why, pros, cons and a few specs) and a note such as
  when the prices were checked. Asked what to buy ("which headphones should I buy", "best laptop
  under $1000", "recommend a stand mixer", "gift ideas for Dad", "where can I buy…"), the agent is
  told to look it up first and never make up a price, a rating or a link. Not for an errand ("buy
  it", "add to cart": the review note's) or a place to eat (a places card).
- `home`: the smart-home devices the agent touched or was asked about, as Home Assistant reports
  them (lights with brightness, switches, thermostats, covers and garage doors, locks, sensors,
  fans, media), each with its entity id. Their controls in Redde send the agent a message ("Turn
  off Kitchen lights (light.kitchen)"), which it does with its own Home Assistant tools; Redde
  never talks to Home Assistant itself.
- `reminder`: a reminder, timer, alarm or scheduled message the agent set: what, when (ISO with its
  offset), how it repeats, where it lives and its id, so Change and Cancel in Redde name it back.
- `compare`: two to four things side by side, criterion by criterion, with the better one per row,
  a verdict and a pick ("which is better, A or B?"; things to buy are a purchase card).
- `score`: games, with both teams (name, short name, colour, score, record), final, live (period
  and clock) or upcoming (start, broadcast), league and venue. Redde's Refresh asks the agent again.

Their fields are not in the tool's schema, which rides on every prompt: each card's shape is in a
line added to the turn only when the person's message asks for that kind of thing (in English,
like the calendar's), and in the tool's error when a card comes without it. The schema is smaller
than before (5,735 characters, from 5,989; its description 1,506, from 1,666): a route's ends take a
name, an address and coordinates only. Cards off, or an agent whose actions Hermes already asks
about (`gated`), get none of these lines.

## 1.11.0 (2026-10-30)

Leave-By Alerts' traffic re-check
- Redde asks this Hermes, over the Dashboard (`/redde-push leave set <device> <wakes>`, `leave
  cancel <device>`), to wake the device about twenty minutes before each Leave-By Alert's leaving
  time. At that time the plugin sends that one device a sealed note of a new kind, `leave`; the
  device asks Apple Maps again, moves its alert if the traffic changed and says so in one quiet
  notification. Hermes is told an opaque id for each alert, the event's title and the time to wake,
  nothing else. Each device's list replaces what it said before (a moved alert, a deleted event),
  at most 30 a device; each wake is sent once, from the thread that reads the schedules, and one
  more than fifteen minutes late is let go. A device unpaired is forgotten with its wakes. Kept:
  `leave.json` in `$HERMES_HOME/redde-push/`.

## 1.10.0 (2026-10-30)

Goes with Redde 2.3.1. Everything here was on the main branch after 1.9.0 was declared, without a
new number, so a Hermes that installed 1.9.0 then was never offered it; this version is what
tells them apart.

Ideas and briefings
- Morning Ideas and Routine Suggestions reach the phone even when the model doesn't call
  `suggest_to_user` (Hermes 0.22 keeps plugin tools behind `tool_search`, and a model that doesn't
  look there writes its ideas out instead). Lines `IDEA: title | why now | the request` in the
  job's answer become idea cards; any other answer comes as a briefing, or why the run failed;
  NOTHING NEW stays silent.
- Briefings carry up to 1,800 characters instead of 500, so a Week Ahead arrives whole.
- A heads-up's notification carries the event's start and address, for the leave time Redde
  works out on the device and the Up Next widget.

Keys asked for
- New tool `request_secret` (toolset `redde_keys`), and `secret_status`: an agent that needs an
  API key asks for it by name, and the person pastes it in a card in Redde, never in the chat. The
  key is sealed to that one request (X25519, HKDF-SHA256, AES-GCM), handed over the Hermes
  Dashboard as a plugin command and written with Hermes's own `.env` writer; the agent only learns
  set or declined. Requests last a day, ten an hour per agent; names that change how programs run
  (`PATH`, `LD_…`, `PYTHON…`, `HERMES_HOME`) are refused. Kept: `keys.json` and `keys/` in
  `$HERMES_HOME/redde-push/`, never a value.

Cards
- Asked what's on the calendar, an agent is told to look the events up and show them as an
  `agenda` card (events by day, a free day shown as one), then answer in a line.
- `places`: each place can have a `price`, `hours` (open or closed, in words) and `pick` (the
  agent's pick).
- `review`: a `kind` (email, message, event, purchase, other) and a `subtitle`, so the app draws
  an email or a message as itself.
- `checklist`: a `subtitle`, a `verb` ("3 of 8 packed"), `groups` or `sections`, and a short
  `note` on an item.
- `weather`: each hour's wind gusts, and when it was read (`updated`); the tool's answer calls
  out the rain window ("storms likely 14:00–17:00, likeliest 80% at 15:00").
- All of these fields are optional, and older apps ignore them.

Approvals
- `/redde-push gated <profile> on|off`: an agent whose actions Hermes already asks about (a
  coding bot behind a `pre_tool_call` approval hook) gets no "show a review card first" note, so
  it is asked once, by Hermes, not twice. Kept in the main home's `redde-push/gated.json`.

Devices
- A device says at pairing whether it is an iPhone, an iPad or a Mac (Redde 2.3.1 and later);
  `hermes redde-push list` shows it, the words say "device", and `call_user` never rings a Mac.
  Devices paired before keep working, counted as iPhones.

## 1.9.0 (2026-10-28)

Goes with Redde 2.3.
- `suggest_to_user` (toolset `redde_ideas`): up to five ideas, each a heading, why now and the
  request, as cards in Redde and one notification; ten offers an hour per agent.
- Watches: jobs named `[redde-watch:<id>]` that tell the phone only what changed; an agent's own
  with `keep_an_eye_on`; a bot's, and ones that hand a change to another agent's Bot Chat.
- Follow-ups: `follow_up_later` brings a loose end back as an idea card.
- Heads-ups: `heads_up_before` makes a one-time job before an event.
- Briefings: the answer of any job named `[redde-notify] …` comes to the phone and stays in Redde's
  Briefings (Evening Wrap-up, Week Ahead).
- Cards answered with a tap in `redde_show`: review before acting, choice, checklist and form; a
  nudge to show a review card before an errand, worded by each agent's Before Acting level.
- `redde_show` is among the tools Hermes 0.22 shows live (GitHub #35).
