import sys, math
from PIL import Image, ImageDraw, ImageFont, ImageFilter
SHOTS, OUT = sys.argv[1], sys.argv[2]
FONT = '/System/Library/Fonts/SFNS.ttf'
def font(size, bold=True):
    f = ImageFont.truetype(FONT, size)
    try: f.set_variation_by_name('Bold' if bold else 'Regular')
    except Exception: pass
    return f

def pano(left_src, right_src, W, H, out_a, out_b, headline, sub, pad=False):
    CW = W * 2
    canvas = Image.new('RGBA', (CW, H), (41, 73, 127, 255))
    # gradient: brand navy → deeper navy left→right, subtle
    grad = Image.new('RGBA', (CW, H))
    gd = ImageDraw.Draw(grad)
    for x in range(0, CW, 4):
        t = x / CW
        c = (int(41 + (30 - 41) * t), int(73 + (56 - 73) * t), int(127 + (104 - 127) * t), 255)
        gd.rectangle((x, 0, x + 4, H), fill=c)
    canvas = grad
    # the icon's orbit, huge and faint, centred on the seam so it spans both slots
    ring = Image.new('RGBA', (CW, H), (0, 0, 0, 0)); rd = ImageDraw.Draw(ring)
    r = int(H * 0.62); cx, cy = CW // 2, int(H * 0.72); w = int(H * 0.045)
    rd.arc((cx - r, cy - r, cx + r, cy + r), start=-90, end=217.5, fill=(255, 255, 255, 46), width=w)
    dot = int(H * 0.05); rd.ellipse((cx - dot, cy - dot, cx + dot, cy + dot), fill=(255, 255, 255, 46))
    canvas = Image.alpha_composite(canvas, ring)
    d = ImageDraw.Draw(canvas)
    margin = int(W * 0.07)
    # headline centred on the seam so the words themselves bridge the two screenshots
    hf = font(int(W * (0.115 if not pad else 0.08))); sf = font(int(W * (0.04 if not pad else 0.03)), bold=False)
    # Each line is given as "left half|right half"; the halves hang off the seam so the store's
    # gap between screenshots falls in a space, never inside a word.
    y = int(H * 0.06); gap = int(W * 0.035)
    for text, f, col in ((headline, hf, (255, 255, 255)), (sub, sf, (200, 214, 240))):
        l, r = text.split('|')
        d.text((CW // 2 - gap, y), l, font=f, fill=col, anchor='ra')
        d.text((CW // 2 + gap, y), r, font=f, fill=col, anchor='la')
        y += int(f.size * (1.15 if f is hf else 1.4))
    top = y + int(H * 0.04)
    # two devices, one per half, each bleeding off the bottom
    scale = 0.84 if not pad else 0.86
    for i, src in enumerate((left_src, right_src)):
        shot = Image.open(src).convert('RGBA')
        dw, dh = int(W * scale), int(H * scale)
        dev = shot.resize((dw, dh), Image.LANCZOS)
        rad = int(W * (0.09 if not pad else 0.03))
        mask = Image.new('L', (dw, dh), 0); ImageDraw.Draw(mask).rounded_rectangle((0, 0, dw, dh), rad, fill=255)
        x = i * W + (W - dw) // 2
        shadow = Image.new('RGBA', (CW, H), (0, 0, 0, 0))
        ImageDraw.Draw(shadow).rounded_rectangle((x, top + 24, x + dw, top + dh + 24), rad, fill=(0, 0, 0, 120))
        canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(40)))
        canvas.paste(dev, (x, top), mask)
    canvas.convert('RGB').crop((0, 0, W, H)).save(out_a, 'PNG', optimize=True)
    canvas.convert('RGB').crop((W, 0, CW, H)).save(out_b, 'PNG', optimize=True)
    print(out_a, out_b)

pano(f'{SHOTS}/ph-chat-hermes.png', f'{SHOTS}/ph-voice.png', 1320, 2868,
     f'{OUT}/iphone-6.9/pano-01a.png', f'{OUT}/iphone-6.9/pano-01b.png',
     'Type it.|Or just say it.', 'One agent, two ways in.|The answer comes back either way.')
pano(f'{SHOTS}/pad-hermes.png', f'{SHOTS}/pad-voice.png', 2064, 2752,
     f'{OUT}/ipad-13/pano-01a.png', f'{OUT}/ipad-13/pano-01b.png',
     'Type it.|Or just say it.', 'One agent, two ways in.|The answer comes back either way.', pad=True)
