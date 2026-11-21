"""Renders the app icon (1024×1024) into the asset catalog."""
from PIL import Image, ImageDraw, ImageFilter
S = 1024
img = Image.new("RGB", (S, S))
d = ImageDraw.Draw(img)
top, bottom = (34, 64, 140), (12, 22, 52)          # deep blue gradient
for y in range(S):
    t = y / (S - 1)
    d.line([(0, y), (S, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)))
# Two screens, like the Duo open.
def screen(x0):
    shadow = Image.new("L", (S, S), 0)
    ImageDraw.Draw(shadow).rounded_rectangle([x0 + 10, 270, x0 + 340, 770], 46, fill=110)
    img.paste((0, 0, 20), mask=shadow.filter(ImageFilter.GaussianBlur(24)))
    d.rounded_rectangle([x0, 250, x0 + 330, 750], 46, fill=(236, 242, 252))
    d.rounded_rectangle([x0 + 26, 276, x0 + 304, 724], 30, fill=(70, 140, 245))
screen(172); screen(522)
# A desktop: a window on the left screen spanning the hinge.
d.rounded_rectangle([250, 370, 760, 610], 22, fill=(250, 252, 255))
d.rounded_rectangle([250, 370, 760, 420], 22, fill=(205, 220, 245))
d.rectangle([250, 400, 760, 420], fill=(205, 220, 245))
for i, w in enumerate([380, 300, 340]):
    d.rounded_rectangle([285, 455 + i * 45, 285 + w, 477 + i * 45], 11, fill=(190, 205, 230))
# Pointer.
p = [(640, 520), (640, 760), (700, 705), (745, 800), (785, 782), (742, 690), (820, 690)]
d.polygon([(x + 8, y + 10) for x, y in p], fill=(0, 0, 30))
d.polygon(p, fill=(255, 255, 255))
d.line(p + [p[0]], fill=(20, 30, 60), width=10, joint="curve")
img.save("Oxide/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
