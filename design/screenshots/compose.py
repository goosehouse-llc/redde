import os, sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter
import zoom   # zoom.py, beside this file

SHOTS = sys.argv[1]; OUT = sys.argv[2]
# A third argument names the slots to draw (`09-tools,08-ipad-tools`); the others are left as they are.
ONLY = set(sys.argv[3].split(',')) if len(sys.argv) > 3 else None
FONT = '/System/Library/Fonts/SFNS.ttf'

def font(size, bold=True):
    f = ImageFont.truetype(FONT, size)
    try: f.set_variation_by_name('Bold' if bold else 'Regular')
    except Exception:
        try: f.set_variation_by_axes([700 if bold else 400])
        except Exception: pass
    return f

def wrap(draw, text, f, maxw):
    words, lines, cur = text.split(), [], ''
    for w in words:
        t = (cur + ' ' + w).strip()
        if draw.textlength(t, font=f) <= maxw: cur = t
        else: lines.append(cur); cur = w
    if cur: lines.append(cur)
    return lines

def compose(src, dst, headline, sub, bg, fg, subfg, pad, panel=None):
    shot = Image.open(src).convert('RGBA')
    W, H = shot.size
    canvas = Image.new('RGBA', (W, H), bg)
    d = ImageDraw.Draw(canvas)
    margin = int(W * 0.07)
    hf = font(int(W * (0.075 if not pad else 0.055)))
    sf = font(int(W * (0.034 if not pad else 0.026)), bold=False)
    y = int(H * 0.055)
    for line in wrap(d, headline, hf, W - 2 * margin):
        d.text((margin, y), line, font=hf, fill=fg); y += int(hf.size * 1.12)
    y += int(sf.size * 0.5)
    for line in wrap(d, sub, sf, W - 2 * margin):
        d.text((margin, y), line, font=sf, fill=subfg); y += int(sf.size * 1.3)
    top = y + int(H * 0.035)
    # device image: scaled to width, rounded, shadowed, bleeding off the bottom
    scale = 0.86 if not pad else 0.88
    dw = int(W * scale); dh = int(H * scale)
    # `panel`: what fills the frame instead of the whole screen scaled down (zoom.py), given the
    # frame's size and how much of it shows above the picture's foot.
    dev = panel(shot, dw, dh, H - top) if panel else shot.resize((dw, dh), Image.LANCZOS)
    r = int(W * (0.09 if not pad else 0.03))
    mask = Image.new('L', (dw, dh), 0); ImageDraw.Draw(mask).rounded_rectangle((0, 0, dw, dh), r, fill=255)
    x = (W - dw) // 2
    shadow = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((x, top + 24, x + dw, top + dh + 24), r, fill=(0, 0, 0, 110))
    shadow = shadow.filter(ImageFilter.GaussianBlur(40))
    canvas = Image.alpha_composite(canvas, shadow)
    canvas.paste(dev, (x, top), mask)
    canvas.convert('RGB').save(dst, 'PNG', optimize=True)
    print(os.path.basename(dst), canvas.size)

def inset(path, box, radius, width, turn=0, outline=None):
    """A piece of another screen (the Lock Screen's countdown, the Home Screen's widget), cut out
    along its own rounded edge, scaled to `width`, turned `turn` degrees, with its shadow, and
    with `outline` (a colour) a hairline round it, for a dark card set over a dark screen."""
    im = Image.open(path).convert('RGBA').crop(box)
    mask = Image.new('L', im.size, 0); ImageDraw.Draw(mask).rounded_rectangle((0, 0, im.width - 1, im.height - 1), radius, fill=255)
    im.putalpha(mask)
    if outline:
        line = Image.new('RGBA', im.size, (0, 0, 0, 0))
        ImageDraw.Draw(line).rounded_rectangle((1, 1, im.width - 2, im.height - 2), radius, outline=outline, width=4)
        im = Image.alpha_composite(im, line)
    im = im.resize((width, round(im.height * width / im.width)), Image.LANCZOS)
    pad = 90
    out = Image.new('RGBA', (im.width + 2 * pad, im.height + 2 * pad), (0, 0, 0, 0))
    shadow = Image.new('RGBA', out.size, (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 150), (pad, pad + 26), im.getchannel('A'))
    out = Image.alpha_composite(out, shadow.filter(ImageFilter.GaussianBlur(34)))
    out.alpha_composite(im, (pad, pad))
    return out.rotate(turn, Image.BICUBIC, expand=True) if turn else out

# Where the insets are in the pictures testToolsShotInsets takes (1320×2868, an iPhone 17 Pro Max).
PILL = ('lock-timer.png', (47, 2269, 1273, 2456), 94)
WIDGET = ('home-widget.png', (97, 286, 1223, 807), 100)

def compose_tools(src, dst, headline, sub, bg, fg, subfg, pad):
    """The Phone tools slot: the conversation, and what it did beyond the app. On iPhone the
    timer counting down on the Lock Screen and the widget, set above the phone and over its
    top; on iPad the widget, over the empty end of the conversation."""
    shot = Image.open(src).convert('RGBA')
    W, H = shot.size
    canvas = Image.new('RGBA', (W, H), bg)
    d = ImageDraw.Draw(canvas)
    margin = int(W * 0.07)
    hf = font(int(W * (0.075 if not pad else 0.055))); sf = font(int(W * (0.034 if not pad else 0.026)), bold=False)
    y = int(H * 0.055)
    for line in wrap(d, headline, hf, W - 2 * margin):
        d.text((margin, y), line, font=hf, fill=fg); y += int(hf.size * 1.12)
    y += int(sf.size * 0.5)
    for line in wrap(d, sub, sf, W - 2 * margin):
        d.text((margin, y), line, font=sf, fill=subfg); y += int(sf.size * 1.3)
    scale = 0.86 if not pad else 0.88
    dw = int(W * scale); dh = int(H * scale)
    r = int(W * (0.09 if not pad else 0.03))
    x = (W - dw) // 2
    if pad:
        top = y + int(H * 0.035)
        cards = [(inset(SHOTS + '/' + WIDGET[0], *WIDGET[1:], width=int(W * 0.42), turn=-2.5), W - margin - int(W * 0.42) + 40, top + int(dh * 0.6))]
    else:
        pill = inset(SHOTS + '/' + PILL[0], *PILL[1:], width=int(W * 0.84), turn=1.5)
        widget = inset(SHOTS + '/' + WIDGET[0], *WIDGET[1:], width=int(W * 0.74), turn=-2.5)
        first = y - 40
        cards = [(pill, (W - pill.width) // 2, first), (widget, (W - widget.width) // 2 + 30, first + pill.height - 150)]
        top = first + pill.height - 150 + widget.height - 230
    dev = shot.resize((dw, dh), Image.LANCZOS)
    mask = Image.new('L', (dw, dh), 0); ImageDraw.Draw(mask).rounded_rectangle((0, 0, dw, dh), r, fill=255)
    shadow = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((x, top + 24, x + dw, top + dh + 24), r, fill=(0, 0, 0, 110))
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(40)))
    canvas.paste(dev, (x, top), mask)
    for card, cx, cy in cards: canvas.alpha_composite(card, (cx, cy))
    canvas.convert('RGB').save(dst, 'PNG', optimize=True)
    print(os.path.basename(dst), canvas.size)

# Cards cut from other raw shots (phone-sized, 1320 wide), for the 2.3 slots: (file, box, corner radius).
PLACES = ('ph-places.png', (48, 901, 1273, 2401), 56)      # the places card: map, three numbered places
REVIEW = ('ph-review.png', (48, 849, 1273, 2066), 56)      # the email to check before it sends
APPROVAL = ('ph-approve.png', (48, 1551, 1273, 2529), 56)  # the approval in plain words
FLIGHT = ('ph-flight.png', (48, 732, 1273, 1500), 56)      # the flight card's first leg (2.3.1)
HOME = ('ph-home.png', (48, 470, 1273, 1340), 56)         # the home card's lights and the reading lamp (2.3.1)
# 2.4 (2026-11-06): pieces of its new screens, each a sheet on the phone, cut from the sheet's top
# edge (row 189 on a 1320×2868 iPhone 18 Pro Max): set over the phone's screens, and on iPad over
# the chat list's empty pane, since the iPad shows them as small sheets in the middle.
READER = ('ph-reader.png', (0, 189, 1320, 1690), 96)      # an email in the reader, its one-line summary on top
COMINGUP = ('ph-comingup.png', (0, 189, 1320, 1600), 96)  # Agent Activity's Coming Up, today's part
INBOX = ('ph-inbox.png', (0, 189, 1320, 1230), 96)        # the Inbox: the piles and two emails
GOAL = ('ph-goal.png', (0, 189, 1320, 2868), 96)          # a goal's page: progress, last check-in, plan
MEMORY = ('ph-memory.png', (0, 189, 1320, 2600), 96)      # What Your Agent Remembers, in Paper White
# 2.7 (2026-11-23): Plan For It and Follow-Through, from the video's demo scenes. The iPad's two
# `-clear` raws are pad-plan and pad-follow with the conversation pane under the cards painted black.
PLAN = ('ph-plan.png', (48, 905, 1272, 2311), 60)  # the plan card, four of five ticked
BILL = ('ph-follow.png', (48, 1615, 1087, 2182), 66)      # the deck's first card
PASSPORT = ('ph-deck-1.png', (48, 1615, 1087, 2182), 66)  # and the next three
LISBON = ('ph-deck-2.png', (48, 1615, 1087, 2182), 66)
MEETING = ('ph-deck-3.png', (48, 1615, 1087, 2182), 66)
# 2.7, every slot proactive (2026-11-24): a Leave-By Alert's banner, a deal's card with Watch price,
# and a to-do list sorted by when (StoreProactiveShotsUITests, raws in tmp/shots-2.7p-raw).
LEAVE = ('ph-leave27.png', (24, 176, 1296, 405), 56)        # Time to leave for Dentist
DEAL = ('ph-purchase.png', (48, 411, 1272, 2061), 54)       # the agent's pick, the deal meter, Watch price
BYWHEN = ('ph-bywhen-before.png', (60, 870, 1260, 2215), 60)  # House To-Dos: Overdue, Today, This week

def compose_cards(src, dst, headline, sub, bg, fg, subfg, pad, cards, blank_below=None):
    """A screen with cards from other screens set over its empty lower part, each turned a little
    and shadowed (the 2.3 answer and approval slots). `cards`: (card, width as a share of the
    picture, its centre as shares of the screen's width and height, turn in degrees).
    `blank_below`: a row of the screen from which down it is the page's black, for a screen whose
    lower part the cards cover (2.3.1's purchase card, scrolled to its top, has the chat's "Jump to
    latest" and the reply's chips under it, which would show between the cards)."""
    shot = Image.open(src).convert('RGBA')
    if blank_below:
        ImageDraw.Draw(shot).rectangle((0, blank_below, shot.width, shot.height), fill=(0, 0, 0, 255))
    W, H = shot.size
    canvas = Image.new('RGBA', (W, H), bg)
    d = ImageDraw.Draw(canvas)
    margin = int(W * 0.07)
    hf = font(int(W * (0.075 if not pad else 0.055))); sf = font(int(W * (0.034 if not pad else 0.026)), bold=False)
    y = int(H * 0.055)
    for line in wrap(d, headline, hf, W - 2 * margin):
        d.text((margin, y), line, font=hf, fill=fg); y += int(hf.size * 1.12)
    y += int(sf.size * 0.5)
    for line in wrap(d, sub, sf, W - 2 * margin):
        d.text((margin, y), line, font=sf, fill=subfg); y += int(sf.size * 1.3)
    top = y + int(H * 0.035)
    scale = 0.86 if not pad else 0.88
    dw = int(W * scale); dh = int(H * scale)
    r = int(W * (0.09 if not pad else 0.03))
    x = (W - dw) // 2
    dev = shot.resize((dw, dh), Image.LANCZOS)
    mask = Image.new('L', (dw, dh), 0); ImageDraw.Draw(mask).rounded_rectangle((0, 0, dw, dh), r, fill=255)
    shadow = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((x, top + 24, x + dw, top + dh + 24), r, fill=(0, 0, 0, 110))
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(40)))
    canvas.paste(dev, (x, top), mask)
    for (path, box, radius), width, (cx, cy), turn in cards:
        card = inset(SHOTS + '/' + path, box, radius, width=int(W * width), turn=turn, outline=(255, 255, 255, 70))
        canvas.alpha_composite(card, (int(x + dw * cx - card.width / 2), int(top + dh * cy - card.height / 2)))
    canvas.convert('RGB').save(dst, 'PNG', optimize=True)
    print(os.path.basename(dst), canvas.size)

def compose_car(shots, dst, headline, sub, bg, fg, subfg):
    """The CarPlay slot: the car's screens stacked under the words, each in a dark bezel. The
    shots are landscape (a dashboard display), drawn by scripts/carplay-preview.sh."""
    W, H = 1320, 2868
    canvas = Image.new('RGBA', (W, H), bg)
    d = ImageDraw.Draw(canvas)
    margin = int(W * 0.07)
    hf = font(int(W * 0.075)); sf = font(int(W * 0.034), bold=False)
    y = int(H * 0.055)
    for line in wrap(d, headline, hf, W - 2 * margin):
        d.text((margin, y), line, font=hf, fill=fg); y += int(hf.size * 1.12)
    y += int(sf.size * 0.5)
    for line in wrap(d, sub, sf, W - 2 * margin):
        d.text((margin, y), line, font=sf, fill=subfg); y += int(sf.size * 1.3)
    screens = [Image.open(p).convert('RGBA') for p in shots]
    sw = int(W * 0.86); frame = 16; gap = int(H * 0.028)
    sizes = [(sw, int(sw * im.height / im.width)) for im in screens]
    stack = sum(h + 2 * frame for _, h in sizes) + gap * (len(sizes) - 1)
    top = y + max(int(H * 0.035), (H - y - stack) // 2)
    x = (W - sw) // 2
    for im, (w, h) in zip(screens, sizes):
        box = (x - frame, top, x + w + frame, top + h + 2 * frame)
        shadow = Image.new('RGBA', (W, H), (0, 0, 0, 0))
        ImageDraw.Draw(shadow).rounded_rectangle((box[0], box[1] + 18, box[2], box[3] + 18), 46, fill=(0, 0, 0, 120))
        canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(30)))
        ImageDraw.Draw(canvas).rounded_rectangle(box, 46, fill=(6, 8, 12))
        mask = Image.new('L', (w, h), 0); ImageDraw.Draw(mask).rounded_rectangle((0, 0, w, h), 32, fill=255)
        canvas.paste(im.resize((w, h), Image.LANCZOS), (x, top + frame), mask)
        top += h + 2 * frame + gap
    canvas.convert('RGB').save(dst, 'PNG', optimize=True)
    print(os.path.basename(dst), canvas.size)

BLUE = (30, 111, 217); NAVY = (16, 24, 56); PAPER = (239, 235, 226); INK = (27, 29, 58); CHAR = (29, 28, 27); BONE = (237, 232, 208)
WHITE = (255, 255, 255); MIST = (200, 214, 240); SAND = (100, 96, 88); ASH = (170, 165, 158)
PLUM = (44, 30, 78); LILAC = (206, 192, 246)
os.makedirs(f'{OUT}/iphone-6.9', exist_ok=True); os.makedirs(f'{OUT}/ipad-13', exist_ok=True)
CORAL = (206, 92, 58); PEACH = (255, 222, 204); TEAL = (12, 84, 92); MINT = (178, 228, 226)
# 2.4 (2026-11-06): the panorama, then what 2.4 brings (goals, the inbox, Today with Coming Up,
# memory in Paper White), then 2.3's answers, bots and approvals, and privacy. Out: ahead of your
# day and the day's timeline (Today and Coming Up take their place), the crew, the car (iPhone) and
# the backend (iPad). Renumbered: answers 05 → 07, bots 06 → 08, approvals 08 → 09.
# A slot with a list of cards is drawn by compose_cards.
phone = [
  # 2.7's set (2026-11-24, his "make sure the screenshots all depict good proactive use cases"):
  # after the panorama (the plan typed, Lisbon said), 03 follow-through, 04 leave on time,
  # 05 goals, 06 lists, 07 watches, 08 the inbox, 09 approvals. Agents, Today, answers, bots
  # and privacy are out.
  ('ph-follow',   '03-follow',   'It follows through.',          'Bills, renewals, trips, promises and meetings come back before they slip.', TEAL, WHITE, MINT,
   [(BILL, 0.64, (0.47, 0.378), -1.2), (PASSPORT, 0.64, (0.53, 0.531), 1.2), (LISBON, 0.64, (0.47, 0.684), -1.2), (MEETING, 0.64, (0.53, 0.837), 1.2)], 770),
  ('ph-day27',    '04-leave',    'Leave on time.',               'Your agent knows your day, and tells you when to go, traffic and all.', BLUE, WHITE, MIST,
   [(LEAVE, 0.90, (0.5, 0.085), -1.0)]),
  ('ph-goal',     '05-goals',    'Goals, step by step.',         'Tick off your steps as you go. Your agent works on its own and checks in on yours.', CORAL, WHITE, PEACH),
  ('ph-clean-before', '06-lists', 'Lists that keep up.',         'Films with their posters, to-dos sorted by when, and a reminder on the day.', PLUM, WHITE, LILAC,
   [(BYWHEN, 0.66, (0.5, 0.83), 1.2)], 1900),
  ('ph-shipped27-calm', '07-watch', 'It keeps watch.',          '“Tell me when it ships.” Prices, parcels and replies: your agent checks, and speaks up when it changes.', (24, 32, 46), WHITE, MIST,
   [(DEAL, 0.46, (0.5, 0.775), -1.2)], 1800),
  ('ph-inbox',    '08-inbox',    'Your inbox, sorted.',          'Seven piles and your own, sorted on your server. Nothing sends until you approve it.', BLUE, WHITE, MIST,
   [(READER, 0.80, (0.50, 0.66), -1.5)]),
  ('ph-plan',     '03-plan',     'Say what you’re up to.',       'Your agent offers a plan. Tick what you want and it does it, now or at the right time.', BLUE, WHITE, MIST),
  ('ph-follow',   '04-follow',   'It follows through.',          'Bills, renewals, trips, promises and meetings come back before they slip.', TEAL, WHITE, MINT,
   [(BILL, 0.64, (0.47, 0.378), -1.2), (PASSPORT, 0.64, (0.53, 0.531), 1.2), (LISBON, 0.64, (0.47, 0.684), -1.2), (MEETING, 0.64, (0.53, 0.837), 1.2)], 770),
  ('ph-chat-dark', '01-hero',    'Your agent, in your pocket.',  'Voice or text, on your own server. Nothing in between.', BLUE, WHITE, MIST),
  ('ph-voice',    '02-voice',    'Just talk.',                   'An orb that moves with your voice. On-device speech, hands-free if you like.', (24, 32, 46), WHITE, MIST),
  # 2.6: other agents through the Redde bridge, shown with the demo agent built into Redde (StoreShotsUITests.testAgentAtWork).
  ('ph-agent',    '03-agents',   'Claude Code, Codex and more.', 'Coding agents on your computer, through the free Redde bridge. See every change and approve it from your phone.', PAPER, INK, SAND),
  ('ph-inbox',    '04-inbox',    'Your inbox, sorted.',          'Seven piles and your own, sorted on your server. Nothing sends until you approve it.', BLUE, WHITE, MIST,
   [(READER, 0.80, (0.50, 0.66), -1.5)]),
  ('ph-today',    '05-today',    'What needs you, first.',       'Approvals, what’s working, your team and your day, at the top of your chats.', (24, 32, 46), WHITE, MIST),
  ('ph-goal',     '06-goals',    'Goals, step by step.',         'Tick off your steps as you go. Your agent works on its own and checks in on yours.', CORAL, WHITE, PEACH),
  # 2.3.1: things to buy (the agent's pick, prices, stock), with a flight and the home's controls over it.
  ('ph-purchase', '07-answers',  'Answers you can use.',         'Things to buy with your agent’s pick, flights, your home’s lights. Cards, not walls of text.', TEAL, WHITE, MINT,
   [(FLIGHT, 0.45, (0.245, 0.865), -1.5), (HOME, 0.43, (0.765, 0.855), 1.5)], 2380),
  # 2.0: the bots. Raw shots from PromoVideoUITests.testBotsShots (see README).
  ('ph-crew',     '08-bots',     'Meet the crew.',               'Each bot has a face, a voice and a chat of its own. Start one from a template.', PLUM, WHITE, LILAC),
  ('ph-approve',  '09-approve',  'Nothing happens without you.', 'Check an email before it sends. Approvals say in plain words what will change.', CHAR, BONE, ASH,
   [(REVIEW, 0.76, (0.50, 0.32), -1.5)]),
]
pad = [
  # 2.7's set, as the iPhone's (2026-11-24).
  ('pad-follow-clear', '03-ipad-follow', 'It follows through.',      'Bills, renewals, trips, promises and meetings come back before they slip.', TEAL, WHITE, MINT,
   [(BILL, 0.44, (0.64, 0.20), -1.2), (PASSPORT, 0.44, (0.69, 0.37), 1.2), (LISBON, 0.44, (0.64, 0.54), -1.2), (MEETING, 0.44, (0.69, 0.71), 1.2)]),
  ('pad-leave27',      '04-ipad-leave',  'Leave on time.',           'Your agent knows your day, and tells you when to go, traffic and all.', BLUE, WHITE, MIST),
  ('pad-today',        '05-ipad-goals',  'Goals, step by step.',     'Tick off your steps as you go. Your agent works on its own and checks in on yours.', CORAL, WHITE, PEACH,
   [(GOAL, 0.40, (0.64, 0.58), -1.0)]),
  ('pad-clean-before', '06-ipad-lists',  'Lists that keep up.',      'Films with their posters, to-dos sorted by when, and a reminder on the day.', PLUM, WHITE, LILAC,
   [(BYWHEN, 0.36, (0.80, 0.72), 1.5)]),
  ('pad-shipped27',    '07-ipad-watch',  'It keeps watch.',          '“Tell me when it ships.” Prices, parcels and replies: your agent checks, and speaks up when it changes.', (24, 32, 46), WHITE, MIST,
   [(DEAL, 0.30, (0.80, 0.70), 1.2)]),
  ('pad-today',        '08-ipad-inbox',  'Your inbox, sorted.',      'Seven piles and your own, sorted on your server. Nothing sends until you approve it.', BLUE, WHITE, MIST,
   [(INBOX, 0.40, (0.60, 0.28), -1.5), (READER, 0.36, (0.70, 0.66), 1.5)]),
  ('pad-plan-clear',   '03-ipad-plan',   'Say what you’re up to.',   'Your agent offers a plan. Tick what you want and it does it, now or at the right time.', BLUE, WHITE, MIST,
   [(PLAN, 0.58, (0.663, 0.474), 0)]),
  ('pad-follow-clear', '04-ipad-follow', 'It follows through.',      'Bills, renewals, trips, promises and meetings come back before they slip.', TEAL, WHITE, MINT,
   [(BILL, 0.44, (0.64, 0.20), -1.2), (PASSPORT, 0.44, (0.69, 0.37), 1.2), (LISBON, 0.44, (0.64, 0.54), -1.2), (MEETING, 0.44, (0.69, 0.71), 1.2)]),
  ('pad-default-dark', '01-ipad',      'Built for iPad.',              'Sessions, scheduled jobs and the Kanban board beside the conversation.', BLUE, WHITE, MIST),
  ('pad-voice',        '02-ipad-voice','Just talk.',                   'An orb that moves with your voice. On-device speech, spoken replies, hands-free if you like.', (24, 32, 46), WHITE, MIST),
  ('pad-agent',        '03-ipad-agents', 'Claude Code, Codex and more.', 'Coding agents on your computer, through the free Redde bridge. See every change and approve it from your phone.', PAPER, INK, SAND),
  ('pad-today',        '04-ipad-inbox', 'Your inbox, sorted.',         'Seven piles and your own, sorted on your server. Nothing sends until you approve it.', BLUE, WHITE, MIST,
   [(INBOX, 0.40, (0.60, 0.28), -1.5), (READER, 0.36, (0.70, 0.66), 1.5)]),
  ('pad-today',        '05-ipad-today', 'What needs you, first.',      'Approvals, what’s working, your team and your day, at the top of your chats. Coming Up shows what’s next.', (24, 32, 46), WHITE, MIST,
   [(COMINGUP, 0.44, (0.64, 0.42), 1.0)]),
  ('pad-today',        '06-ipad-goals',  'Goals, step by step.',        'Tick off your steps as you go. Your agent works on its own and checks in on yours.', CORAL, WHITE, PEACH,
   [(GOAL, 0.40, (0.64, 0.58), -1.0)]),
  ('pad-purchase',     '07-ipad-answers', 'Answers you can use.',      'Things to buy with your agent’s pick, flights, your home’s lights. Cards, not walls of text.', TEAL, WHITE, MINT,
   [(FLIGHT, 0.28, (0.19, 0.60), -1.5), (HOME, 0.24, (0.19, 0.80), 2.0)]),
  ('pad-crew',         '08-ipad-bots', 'Meet the crew.',               'Each bot has a face, a voice and a chat of its own. Start one from a template.', PLUM, WHITE, LILAC),
  ('pad-approve',      '09-ipad-approve', 'Nothing happens without you.', 'Check an email before it sends. Approvals say in plain words what will change.', CHAR, BONE, ASH,
   [(REVIEW, 0.38, (0.64, 0.73), -1.5)]),
]
# iPad slots whose capture leaves most of the 13-inch screen empty, drawn larger in the frame (zoom.py):
# the day's question and card, and the crew's screen, restacked larger.
ZOOMED = {'08-ipad-bots': zoom.crew}   # 2.6: the crew is back (2.3's day slot, zoom.day, stays out)
for kind, slots in (('iphone-6.9', phone), ('ipad-13', pad)):
    for src, name, h, s, bg, fg, sfg, *cards in slots:
        if ONLY and name not in ONLY: continue
        if name in ZOOMED:
            compose(f'{SHOTS}/{src}.png', f'{OUT}/{kind}/{name}.png', h, s, bg, fg, sfg, True, panel=ZOOMED[name])
        elif cards:
            compose_cards(f'{SHOTS}/{src}.png', f'{OUT}/{kind}/{name}.png', h, s, bg, fg, sfg, kind == 'ipad-13', *cards)
        else:
            draw = compose_tools if name.endswith('-tools') else compose
            draw(f'{SHOTS}/{src}.png', f'{OUT}/{kind}/{name}.png', h, s, bg, fg, sfg, kind == 'ipad-13')
# iPhone only: CarPlay runs from the phone. Not in the 2.4 set; drawn when asked for by name.
if ONLY and '09-car' in ONLY:
  compose_car([f'{SHOTS}/car-ask.png', f'{SHOTS}/car-voice.png', f'{SHOTS}/car-speaking.png'], f'{OUT}/iphone-6.9/09-car.png',
              'In the car, by voice.', 'CarPlay: tap Ask or Talk, take a note, or pause a reply. Answers are spoken, so your eyes stay on the road.',
              (24, 32, 46), WHITE, MIST)
