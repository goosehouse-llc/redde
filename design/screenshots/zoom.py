"""iPad screens drawn larger inside the device frame, for slots whose capture leaves most of a
13-inch screen empty (2.3, at the owner's word: "tighten" the iPad's voice, day and crew slots).

The frame keeps the size and place compose.py and pano.py give it; only what is inside changes:
- `crop`: a part of the screen, scaled up to fill the frame (the day's timeline in its column).
- `restack`: the screen's own pieces, each cut along the empty background around it and set
  larger, top to bottom, in the order and alignment the screen has them, with the empty middle
  taken out (voice mode, a group chat's voice screen). The status bar stays at the frame's own
  scale, so it matches the device beside it.
Every piece is a part of the real capture; the backgrounds of these screens are one flat colour,
so the joins don't show. The boxes are for a 2064 x 2752 capture (iPad Pro 13-inch).
"""
from PIL import Image

STATUS = 66   # the status bar's height in the capture


def crop(shot, dw, dh, x0, y0, z):
    """The capture from (x0, y0), `z` times its own size, filling a dw x dh frame."""
    return shot.crop((x0, y0, round(x0 + dw / z), round(y0 + dh / z))).resize((dw, dh), Image.LANCZOS)


def restack(shot, dw, dh, bg, rows, status=True):
    """`rows`: (box, zoom, align, y): a piece of the capture, `zoom` times its size, set at `y` in
    the frame (pixels; negative counts up from the frame's bottom) and aligned 'left', 'right'
    (each keeping its own margin from the capture's edge, scaled) or 'centre'. Later rows are laid
    over earlier ones, so a small piece beside a wide one comes after it."""
    W = shot.width
    frame = Image.new('RGBA', (dw, dh), bg + (255,))
    s = dw / W
    if status:   # left out where the sidebar's colour would show in it alone (the day)
        frame.paste(shot.crop((0, 0, W, STATUS)).resize((dw, round(STATUS * s)), Image.LANCZOS), (0, 0))
    for box, z, align, y in rows:
        piece = shot.crop(box)
        piece = piece.resize((round(piece.width * z), round(piece.height * z)), Image.LANCZOS)
        if align == 'left':
            x = round(box[0] * z)
        elif align == 'right':
            x = dw - round((W - box[2]) * z) - piece.width
        else:
            x = (dw - piece.width) // 2
        frame.paste(piece, (x, y if y >= 0 else dh + y - piece.height))
    return frame


def voice(shot, dw, dh, visible):
    """Voice mode mid-listen (pad-voice): Hands-free and the chat's name, the orb, the words, and
    the buttons at the foot of what shows of the frame (`visible` pixels of it)."""
    bg = shot.convert('RGB').getpixel((20, 1500))
    z, zo = 1.12, 1.7
    top = round(STATUS * dw / shot.width) + 24
    orb_y = top + round(90 * z)
    words_y = orb_y + round((769 - 111) * zo) + 30
    return restack(shot, dw, dh, bg, [
        ((560, 96, 1504, 772), zo, 'centre', orb_y - round(15 * zo)),   # the orb, Listening
        ((16, 66, 340, 176), z, 'left', top - 4),          # Hands-free
        ((1690, 94, 2048, 140), z, 'right', top + 24),     # the chat it is in
        ((270, 772, 1794, 826), z, 'centre', words_y),     # what was heard
        ((760, 2550, 1304, 2706), z, 'centre', visible - 120 - round(156 * z)),   # the buttons
    ])


def crew(shot, dw, dh, visible):
    """A group chat's voice screen (pad-crew): the room's name, the speaking bot's face, the
    question and the three answers, and the hint and buttons at the foot of what shows."""
    bg = shot.convert('RGB').getpixel((20, 1500))
    z, zf = 1.32, 1.45
    top = round(STATUS * dw / shot.width) + 20
    face_y = top + round(30 * z)
    bubble_y = face_y + round((722 - 100) * zf) + round(26 * z)
    answers_y = bubble_y + round((830 - 736) * z) + round(26 * z)
    controls_y = visible - 110 - round(156 * z)
    return restack(shot, dw, dh, bg, [
        ((620, 100, 1444, 722), zf, 'centre', face_y),      # Quill's face, Quill is speaking
        ((16, 70, 340, 134), z, 'left', top),               # the room: Weekend hike
        ((1160, 736, 2040, 830), z, 'right', bubble_y),     # the question
        ((30, 848, 1340, 1206), z, 'left', answers_y),      # Redde, Scout and Quill answering
        ((720, 2508, 1342, 2548), z, 'centre', controls_y - round(46 * z)),   # the hint
        ((760, 2550, 1304, 2706), z, 'centre', controls_y),                    # the buttons
    ])


def day(shot, dw, dh, visible):
    """Tomorrow as a timeline (pad-day): the question, and the card under it, as wide as the frame
    allows; the reply's line between them is left out."""
    z = 1.42
    top = 64
    return restack(shot, dw, dh, (0, 0, 0), [
        ((1446, 198, 2040, 290), z, 'right', top),          # What's on my calendar tomorrow?
        ((704, 535, 1760, 1958), z, 'centre', top + round(92 * z) + 40),   # the day's card
    ], status=False)
