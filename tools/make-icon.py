#!/usr/bin/env python3
"""Regenerates Resources/AppIcon.icns (needs Pillow). Only for changing the icon; builds don't run this."""
import io, struct, sys
from PIL import Image, ImageDraw

S = 4096  # draw big, shrink for smooth edges
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# Rounded-square body with a vertical blue gradient.
margin, radius = int(S * 0.098), int(S * 0.19)
grad = Image.new("RGBA", (S, S))
gd = ImageDraw.Draw(grad)
top, bot = (38, 99, 235), (20, 33, 92)
for y in range(S):
    t = y / (S - 1)
    gd.line([(0, y), (S, y)], fill=tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3)) + (255,))
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([margin, margin, S - margin, S - margin], radius, fill=255)
img.paste(grad, (0, 0), mask)

# Broadcast motif: a hub with signal arcs left and right.
d = ImageDraw.Draw(img)
cx = cy = S // 2
white = (255, 255, 255, 255)
r = int(S * 0.075)
d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=white)
w = int(S * 0.036)
for k, rad in enumerate([0.17, 0.26, 0.35]):
    R = int(S * rad)
    box = [cx - R, cy - R, cx + R, cy + R]
    for a0, a1 in ((-42, 42), (138, 222)):
        d.arc(box, a0, a1, fill=white, width=w)
        for a in (a0, a1):  # round caps
            import math
            x = cx + (R - w / 2) * math.cos(math.radians(a)); y = cy + (R - w / 2) * math.sin(math.radians(a))
            d.ellipse([x - w / 2, y - w / 2, x + w / 2, y + w / 2], fill=white)

# Write .icns by hand (PNG payloads), so this works off-Mac.
sizes = {b"ic07": 128, b"ic08": 256, b"ic09": 512, b"ic10": 1024}
chunks = b""
for tag, px in sizes.items():
    buf = io.BytesIO()
    img.resize((px, px), Image.LANCZOS).save(buf, "PNG")
    chunks += tag + struct.pack(">I", len(buf.getvalue()) + 8) + buf.getvalue()
open("Resources/AppIcon.icns", "wb").write(b"icns" + struct.pack(">I", len(chunks) + 8) + chunks)
img.resize((512, 512), Image.LANCZOS).save("Resources/AppIcon-preview.png")
