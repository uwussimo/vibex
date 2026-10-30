#!/usr/bin/env python3
"""Turns raw captures of the real app into the site's images. usage: process.py RAW_DIR"""
import sys
from pathlib import Path
from PIL import Image

raw = Path(sys.argv[1])
root = Path(__file__).resolve().parents[2] / 'docs/assets'
(root / 'ridge').mkdir(exist_ok=True, parents=True)
(root / 'shots').mkdir(exist_ok=True, parents=True)

# Phone renders include the renderer's bezel, 10 points (14 on iPad); the site draws its own.
for file in raw.glob('phone-*.png'):
    im = Image.open(file).convert('RGB')
    edge = 28 if 'ipad' in file.name else 20
    w, h = im.size
    im.crop((edge, edge, w - edge, h - edge)).save(root / 'ridge' / (file.stem[6:] + '.jpg'), quality=86, optimize=True)

# The main window: 56 pt activity bar, 600 pt chat, then the editor. Screens are 2x.
BAR, CHAT = 56 * 2, 600 * 2
def frame(name, out, blank_simulator=True):
    im = Image.open(raw / f'{name}.png').convert('RGB')
    if blank_simulator:
        # The phone sits here on the page; the empty simulator's prompt mustn't show behind it.
        colour = im.getpixel((im.size[0] - 40, im.size[1] - 40))
        im.paste(colour, (BAR + CHAT + 2, 84 * 2, im.size[0], im.size[1]))
    im.save(root / 'shots' / f'{out}.jpg', quality=84, optimize=True)
def column(name, out):
    im = Image.open(raw / f'{name}.png').convert('RGB')
    im.crop((BAR, 0, BAR + CHAT, im.size[1])).save(root / 'shots' / f'{out}.jpg', quality=84, optimize=True)

frame('h4', 'window')
for name in ['m-empty', 'h1', 'h2', 'h3', 'h4', 's0', 's1', 'ap0', 'ap1', 'ap2']:
    column(name, f'col-{name}')
frame('s0', 'window-sim')
frame('ap0', 'window-approve')
for name in ['c-0', 'c-menu', 'c-plan', 'c-auto', 'design-tab']:
    Image.open(raw / f'{name}.png').convert('RGB').save(root / 'shots' / f'{name}.jpg', quality=84, optimize=True)
# Just the editor's diff, down to where the code ends.
diff = Image.open(raw / 'diff.png').convert('RGB')
diff.crop((BAR + CHAT + 2, 38 * 2, diff.size[0], 400 * 2)).save(root / 'shots' / 'diff.jpg', quality=88, optimize=True)
