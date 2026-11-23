# make_27.py ipad: the iPad's cut points, in cfr-ipad-c1-coders.mov (exec'd by make_27.py). The same
# test on the 13" iPad simulator (21E37828, 2026-11-22), each cut moved to the same moment by the
# test's marks and checked on the frames. The stack is in the sidebar beside Quill's chat there, and
# opens at 177.4; the app is gone at 182.2.
TI = 'ipad-c1-coders'
SHOTS = [
    (TI, 30.6, 40.0, ALL, PURPLE, 2),
    (TI, 77.8, 88.3, CLAUDE, ORANGE, 2),
    (TI, 88.3, 97.3, ALLOW, ORANGE, 2),
    (TI, 174.5, 181.0, NEEDS, CORAL, 2),
]
TITLE_TAKE = (TI, 27.4, 30.6)   # the chat list, before the server menu opens
END_TAKE = (TI, 181.0)          # the stack, opened, held
