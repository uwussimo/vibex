"""Turns @untitledui/icons' React components into template SVG image sets for an asset catalog.

Usage: python3 -I scripts/convert-icons.py <package/dist> <icons.txt> <Icons.xcassets>
"""
import json
import pathlib
import re
import shutil
import sys

dist, listing, out = (pathlib.Path(arg) for arg in sys.argv[1:4])
element = re.compile(r'createElement\("(path|circle|rect|line|polyline|polygon)",\{([^{}]*)\}')
attribute = re.compile(r'(?:"([\w-]+)"|(\w+)):"([^"]*)"')


def kebab(name):
    return re.sub(r"([A-Z])", lambda m: "-" + m.group(1).lower(), name)


if out.exists():
    shutil.rmtree(out)
out.mkdir(parents=True)
(out / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}))

count = 0
for line in listing.read_text().splitlines():
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    name, source = line.split()
    code = (dist / f"{source}.mjs").read_text()
    shapes = []
    for tag, attrs in element.findall(code):
        pairs = " ".join(f'{kebab(q or p)}="{v}"' for q, p, v in attribute.findall(attrs))
        shapes.append(f"<{tag} {pairs}/>")
    if not shapes:
        sys.exit(f"no shapes found in {source}")
    svg = (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24" fill="none" '
        'stroke="#000000" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">'
        + "".join(shapes) + "</svg>\n"
    )
    folder = out / f"uui.{name}.imageset"
    folder.mkdir()
    (folder / f"{name}.svg").write_text(svg)
    (folder / "Contents.json").write_text(json.dumps({
        "images": [{"filename": f"{name}.svg", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {"preserves-vector-representation": True, "template-rendering-intent": "template"},
    }, indent=2))
    count += 1
print(f"{count} icons written to {out}")
