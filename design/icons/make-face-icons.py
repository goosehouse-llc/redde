#!/usr/bin/env python3
"""Redde's bot-face app icons: three shapes (the bubble, the star, the ghost) in eight colours, on
the Matte Mist tile (asked 2026-11-04). Each is drawn from the app's own geometry (BotAvatar.swift:
`Shape.bubble`, `.star`, `.ghost`; round eyes, glance 1, tilt -3) and colours (BotFace.palette and
laterPalette; blue is the standard theme's bubble, as Redde Face has always been).

    python3 design/icons/make-face-icons.py            # SVGs into design/icons/faces/
    python3 design/icons/make-face-icons.py --install  # and renders them into the asset catalog

Rendering is WebKit's (qlmanage, which draws the blurs), flattened by flatten-icon.swift, as the
other icons are. iOS can only switch between icons built into the app, so every shape and colour
is its own icon; Settings shows them as a shape row and a colour row (AppIconSettings.swift).
Kept names: AppIconFaceMist (blue bubble, the primary) and AppIconStarMist (blue star); the rest
are AppIcon<Shape><Colour>.
"""
import math
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(HERE, "faces")
ASSETS = os.path.join(ROOT, "Echo", "Resources", "Assets.xcassets")

# (light, deep) as in BotFace: the body is a radial gradient from between the two to the deep one.
# Blue keeps Redde Face's own two stops exactly.
COLOURS = {
    "Blue": ("#5EA8F9", "#2373E2"),
    "Green": ("#C7F5A8", "#57C266"),      # palette green
    "Purple": ("#D1BDFF", "#8A66F0"),     # palette violet
    "Orange": ("#FFC791", "#F08038"),     # palette orange
    "Pink": ("#FFB3D9", "#E8579E"),       # palette pink
    "Graphite": ("#8C93A1", "#3B404B"),   # Matte Graphite's tone
    "Yellow": ("#FFF594", "#FAD41A"),     # laterPalette yellow
    "Gold": ("#FCDB80", "#CC9629"),       # laterPalette gold
}
SHAPES = ["Bubble", "Star", "Ghost"]
KEPT = {("Bubble", "Blue"): "AppIconFaceMist", ("Star", "Blue"): "AppIconStarMist"}


def icon_name(shape, colour):
    return KEPT.get((shape, colour), f"AppIcon{shape}{colour}")


def hexrgb(h):
    h = h.lstrip("#")
    return [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]


def mix(a, b, t):
    ca, cb = hexrgb(a), hexrgb(b)
    return "#" + "".join(f"{round((x + (y - x) * t) * 255):02X}" for x, y in zip(ca, cb))


def f(v):
    return f"{v:.2f}".rstrip("0").rstrip(".")


def star_path():
    pts = []
    for i in range(10):
        r = 45 if i % 2 == 0 else 27
        a = math.radians(-90 + i * 36)
        pts.append((51 + r * math.cos(a), 52 + r * math.sin(a)))
    sharp = min((i for i in range(10) if i % 2 == 0), key=lambda i: math.hypot(pts[i][0], 100 - pts[i][1]))
    d = []
    for i, p in enumerate(pts):
        nx, pv = pts[(i + 1) % 10], pts[(i - 1) % 10]
        s = 0.12 if i == sharp else 0.3
        a = (p[0] + (pv[0] - p[0]) * s, p[1] + (pv[1] - p[1]) * s)
        b = (p[0] + (nx[0] - p[0]) * s, p[1] + (nx[1] - p[1]) * s)
        d.append(("M" if i == 0 else "L") + f"{f(a[0])},{f(a[1])}")
        d.append(f"Q{f(p[0])},{f(p[1])} {f(b[0])},{f(b[1])}")
    return " ".join(d) + " Z"


# Each shape: its body path, eye line and gap, the gloss (kept inside the body), and where its
# middle is, as the 100-point box draws it.
GEOMETRY = {
    "Bubble": dict(body="M38.1,13 H63.9 A26.1,26.1 0 0 1 90,39.1 V60.9 A26.1,26.1 0 0 1 63.9,87 H19.25 "
                        "A7.25,7.25 0 0 1 12,79.75 V39.1 A26.1,26.1 0 0 1 38.1,13 Z",
                   eye_y=45, gap=12, gloss=(34, 26, 9, 5, -28), middle=(51, 50)),
    "Star": dict(body=star_path(), eye_y=50, gap=9.5, gloss=(45, 25, 6.5, 3.8, -62), middle=(51, 52)),
    "Ghost": dict(body="M18,50 C18,28 32,11 51,11 C70,11 84,28 84,50 L84,82 Q78.5,91 73,82 Q67.5,74 62,82 "
                       "Q56.5,91 51,82 Q45.5,74 40,82 Q34.5,91 29,82 Q23,76 18,90 Z",
                  eye_y=43, gap=11, gloss=(34, 24, 8, 4.6, -28), middle=(51, 51)),
}


def svg(shape, colour):
    g = GEOMETRY[shape]
    light, deep = COLOURS[colour]
    top = light if colour == "Blue" else mix(deep, light, 0.6)
    gx, gy, grx, gry, grot = g["gloss"]
    mx, my = g["middle"]
    lx, rx, ey = 51 - g["gap"], 51 + g["gap"], g["eye_y"]
    px, py = 1.8 * 7.4 / 7, 0.6 * 7.4 / 7
    # On a light body (yellow) the gloss would vanish: it is a touch stronger there.
    gloss = 0.34 if colour in ("Yellow", "Gold") else 0.26
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="1024" height="1024">'
        f'<!-- Redde bot face, {shape.lower()}, {colour.lower()}, on Matte Mist (make-face-icons.py). -->'
        '<defs><linearGradient id="tx" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#C8D5EA"/>'
        '<stop offset="1" stop-color="#9FB3D4"/></linearGradient>'
        f'<radialGradient id="bx" cx="32%" cy="26%" r="85%"><stop offset="0" stop-color="{top}"/>'
        f'<stop offset="1" stop-color="{deep}"/></radialGradient>'
        '<filter id="dx" filterUnits="userSpaceOnUse" x="-30" y="-30" width="160" height="160">'
        '<feGaussianBlur stdDeviation="3.7"/></filter>'
        f'<path id="body" d="{g["body"]}"/><clipPath id="cx"><use href="#body"/></clipPath></defs>'
        '<rect width="64" height="64" fill="url(#tx)"/>'
        f'<g transform="translate(32 32.4) scale(0.6) translate(-{mx} -{my})"><g transform="rotate(-3 {mx} {my})">'
        '<use href="#body" transform="translate(0 3.7)" fill="#05080F" opacity="0.4" filter="url(#dx)"/>'
        '<use href="#body" fill="url(#bx)"/>'
        f'<g clip-path="url(#cx)"><ellipse cx="{gx}" cy="{gy}" rx="{grx}" ry="{gry}" transform="rotate({grot} {gx} {gy})" '
        f'fill="#FFFFFF" opacity="{gloss}"/></g>'
        f'<ellipse cx="{f(lx)}" cy="{ey}" rx="7.4" ry="7.84" fill="#FFFFFF"/>'
        f'<ellipse cx="{f(rx)}" cy="{ey}" rx="7.4" ry="7.84" fill="#FFFFFF"/>'
        f'<circle cx="{f(lx + px)}" cy="{f(ey + py)}" r="3.8" fill="#17171F"/>'
        f'<circle cx="{f(rx + px)}" cy="{f(ey + py)}" r="3.8" fill="#17171F"/>'
        '</g></g></svg>'
    )


def main():
    os.makedirs(OUT, exist_ok=True)
    made = []
    for shape in SHAPES:
        for colour in COLOURS:
            path = os.path.join(OUT, f"{icon_name(shape, colour)}.svg")
            with open(path, "w") as out:
                out.write(svg(shape, colour))
            made.append((shape, colour, path))
    print(f"wrote {len(made)} SVGs to {OUT}")
    if "--install" not in sys.argv:
        return
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["qlmanage", "-t", "-s", "1024", "-o", tmp] + [p for _, _, p in made],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for shape, colour, path in made:
            name = icon_name(shape, colour)
            rendered = os.path.join(tmp, os.path.basename(path) + ".png")
            iconset = os.path.join(ASSETS, f"{name}.appiconset")
            os.makedirs(iconset, exist_ok=True)
            big = os.path.join(iconset, "AppIcon-1024.png")
            subprocess.run(["swift", os.path.join(HERE, "flatten-icon.swift"), rendered, big], check=True, stdout=subprocess.DEVNULL)
            with open(os.path.join(iconset, "Contents.json"), "w") as out:
                out.write('{\n  "images" : [\n    {\n      "filename" : "AppIcon-1024.png",\n      "idiom" : "universal",\n'
                          '      "platform" : "ios",\n      "size" : "1024x1024"\n    }\n  ],\n'
                          '  "info" : { "author" : "xcode", "version" : 1 }\n}\n')
            preview = os.path.join(ASSETS, "IconPreviews", f"{name}.imageset")
            os.makedirs(preview, exist_ok=True)
            subprocess.run(["sips", "-Z", "240", big, "--out", os.path.join(preview, f"{name}.png")], check=True, stdout=subprocess.DEVNULL)
            with open(os.path.join(preview, "Contents.json"), "w") as out:
                out.write('{\n  "images" : [ { "filename" : "%s.png", "idiom" : "universal" } ],\n'
                          '  "info" : { "author" : "xcode", "version" : 1 }\n}\n' % name)
            print("installed", name)
    names = [icon_name(s, c) for s in SHAPES for c in COLOURS if icon_name(s, c) != "AppIconFaceMist"]
    print("alternates:", " ".join(names))


if __name__ == "__main__":
    main()
