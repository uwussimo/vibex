#!/usr/bin/env python3
"""Screens that only exist for the site's story: the same designs with a bug in them, or one step on.
Writes them into the folder given, as a copy of the design ready to render."""
import json, shutil, sys
from pathlib import Path

here = Path(__file__).parent / 'vibex-design'
out = Path(sys.argv[1])
shutil.rmtree(out, ignore_errors=True)
shutil.copytree(here, out)

def walk(node, visit):
    visit(node)
    for child in node.get('children', []):
        walk(child, visit)

def variant(source, name, change):
    screen = json.load(open(here / 'screens' / source))
    walk(screen['root'], change)
    screen['name'] = name
    json.dump(screen, open(out / 'screens' / f'{name}.json', 'w'))

# The bug Claude finds: the pay button is wider than the screen.
def too_wide(node):
    kids = node.get('children', [])
    if any(k.get('text') == 'Pay $48' for k in kids):
        node['align'] = 'start'
        for child in kids:
            if child.get('text') == 'Pay $48':
                child['width'] = 470

variant('04-permit.json', '08-permit-bug', too_wide)

# One step on: Claude has switched the headlamp on.
def packed(node):
    kids = node.get('children', [])
    if node.get('type') == 'row' and any(k.get('text') == 'Headlamp' for k in kids):
        kids[-1]['isOn'] = True
    if node.get('text') == '3 of 5 packed':
        node['text'] = '4 of 5 packed'

variant('05-plan.json', '09-plan-packed', packed)
