#!/usr/bin/env python3
"""Generates the landscapes Ridge, the site's demo app, uses. All original, drawn here.
Run from this folder, then: Chrome --headless --screenshot each SVG at 1200x1500, and save as JPEG."""
import random
W, H = 1200, 1500
scenes = {
    'dusk': dict(sky=['#1b1140', '#5a2a7a', '#d9567a', '#ffb36b'], sun=(.68, .40, 90, '#fff1c9'), front='#0d0a1f', far='#b4688f', seed=4, stars=True),
    'dawn': dict(sky=['#22406b', '#6f8fb5', '#f3b7a6', '#ffe3bd'], sun=(.3, .42, 70, '#fff6dc'), front='#10222e', far='#a8b6c9', seed=9, stars=False),
    'alpine': dict(sky=['#0b3a5e', '#1f7a9c', '#7fd0cf', '#e4f6e2'], sun=(.74, .2, 54, '#ffffff'), front='#06231f', far='#8cc7c9', seed=15, stars=False),
    'desert': dict(sky=['#3a1538', '#a23a4a', '#ee7a3f', '#ffd27a'], sun=(.5, .46, 110, '#ffe9a8'), front='#1e0c14', far='#d9805c', seed=21, stars=False),
    'forest': dict(sky=['#0a2a2a', '#1d5c4d', '#7fb27a', '#f0e2a8'], sun=(.22, .36, 64, '#fff7cf'), front='#04140f', far='#7ba98a', seed=33, stars=False),
    'night': dict(sky=['#04061a', '#0d1b4a', '#28407f', '#6a79b5'], sun=(.72, .2, 44, '#eef1ff'), front='#03040f', far='#4a5a94', seed=41, stars=True),
}

def rgb(c): return tuple(int(c[i:i + 2], 16) for i in (1, 3, 5))
def mix(a, b, t):
    a, b = rgb(a), rgb(b)
    return '#%02x%02x%02x' % tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))

def ridge(rng, base, amp, rough):
    n = 9
    pts = [0] * (2 ** n + 1)
    pts[0], pts[-1] = rng.uniform(-.5, .5), rng.uniform(-.5, .5)
    step, a = 2 ** n, 1.0
    while step > 1:
        for i in range(step // 2, len(pts), step):
            pts[i] = (pts[i - step // 2] + pts[i + step // 2]) / 2 + rng.uniform(-a, a)
        step //= 2
        a *= rough
    return [(W * i / (len(pts) - 1), base - amp * p) for i, p in enumerate(pts)]

for name, s in scenes.items():
    rng = random.Random(s['seed'])
    sx, sy, sr, sc = s['sun']
    o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}"><defs>']
    o.append('<linearGradient id="sky" x1="0" y1="0" x2="0" y2="1">' + ''.join(f'<stop offset="{p}" stop-color="{c}"/>' for p, c in zip((0, .34, .6, .82), s['sky'])) + '</linearGradient>')
    o.append(f'<radialGradient id="glow" cx="{sx}" cy="{sy}" r=".7"><stop offset="0" stop-color="{sc}" stop-opacity=".85"/><stop offset=".25" stop-color="{sc}" stop-opacity=".28"/><stop offset="1" stop-color="{sc}" stop-opacity="0"/></radialGradient>')
    o.append('<linearGradient id="mist" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity="0"/><stop offset="1" stop-color="#fff" stop-opacity=".22"/></linearGradient>')
    o.append('<filter id="grain"><feTurbulence type="fractalNoise" baseFrequency=".9" numOctaves="2" stitchTiles="stitch"/><feColorMatrix values="0 0 0 0 1  0 0 0 0 1  0 0 0 0 1  0 0 0 .07 0"/></filter></defs>')
    o.append(f'<rect width="{W}" height="{H}" fill="url(#sky)"/>')
    if s['stars']:
        for _ in range(240):
            x, y = rng.uniform(0, W), rng.uniform(0, H * .5)
            r, op = rng.choice([.8, 1, 1.2, 1.8]), rng.uniform(.25, .95) * (1 - y / (H * .55))
            o.append(f'<circle cx="{x:.0f}" cy="{y:.0f}" r="{r}" fill="#fff" opacity="{op:.2f}"/>')
    o.append(f'<rect width="{W}" height="{H}" fill="url(#glow)"/><circle cx="{sx * W}" cy="{sy * H}" r="{sr}" fill="{sc}"/>')
    layers = 7
    for i in range(layers):
        t = i / (layers - 1)
        pts = ridge(rng, H * (.5 + .42 * t), (150 + 90 * (1 - t)) * (.8 + t * .5), .54 + .06 * t)
        d = f'M0 {H} ' + ' '.join(f'L{x:.1f} {y:.1f}' for x, y in pts) + f' L{W} {H} Z'
        o.append(f'<path d="{d}" fill="{mix(s["far"], s["front"], t ** .8)}"/>')
        if i < layers - 1:
            o.append(f'<path d="{d}" fill="url(#mist)" opacity="{.9 * (1 - t):.2f}"/>')
    ridge(rng, H * .93, 100, .5)
    trees = []
    for x in range(-20, W + 20, 18):
        h, b = rng.uniform(40, 120), H * .93 - rng.uniform(-30, 60)
        trees.append(f'M{x - h * .2:.0f} {b:.0f} L{x:.0f} {b - h:.0f} L{x + h * .2:.0f} {b:.0f} Z')
    o.append(f'<path d="{" ".join(trees)}" fill="{s["front"]}"/><rect y="{H * .93:.0f}" width="{W}" height="{H * .07 + 2:.0f}" fill="{s["front"]}"/>')
    o.append(f'<rect width="{W}" height="{H}" filter="url(#grain)"/></svg>')
    open(f'{name}.svg', 'w').write(''.join(o))
