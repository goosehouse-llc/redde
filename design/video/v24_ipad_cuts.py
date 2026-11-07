# make_24.py ipad: the iPad's shots, from the ipad-v24-* takes (exec'd by make_24.py). The goal sheet
# is a card there and doesn't scroll to the plan, and the email doesn't open in the inbox card, so
# the email shot is left out and the inbox gets two bars.
SHOTS = [
    ('ipad-v24-today', 24.6, 28.4, TODAY, PURPLE, 1),
    ('ipad-v24-goal', 26.3, 30.5, ('Goals', 'Check-ins, and how far along you are.'), CORAL, 1),
    ('ipad-v24-inbox', 23.0, 29.4, INBOX, BLUE, 2),
    ('ipad-v24-memory', 24.8, 31.4, MEMORY, GREEN, 2),
]
TITLE_TAKE = ('ipad-v24-today', 19.6, 22.6)
END_TAKE = ('ipad-v24-today', 30.0)
