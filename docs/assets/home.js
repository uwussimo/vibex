// The home page's choreography. Each scene has its own idea, written in scroll progress (0 to 1).
import { defineTimeline } from '/assets/components.js';

/** Moves the camera so a point in the 1600 x 1000 world sits in the middle of the stage. */
function focus(x, y, scale) {
  return { x: (800 - x) * scale, y: (500 - y) * scale, scale };
}

defineTimeline('hero', (t) => {
  t.to('.hero-copy', [0.0, 0.09], { y: [0, -120], opacity: [1, 0] }, 'linear');
  t.to('.glow', [0, 0.25], { '--glow': [0.6, 1] }, 'linear');
  t.to('.h-win', [0, 0.28], { y: [720, 0], rx: [34, 0], scale: [0.82, 1] }, 'inOut');

  t.to('.h1', [0.27, 0.31], { y: [24, 0], opacity: [0, 1] });
  t.to('.cam', [0.29, 0.41], focus(464, 680, 1.5), 'inOut');
  t.to('.h2', [0.33, 0.37], { y: [24, 0], opacity: [0, 1] });
  t.to('.h3', [0.4, 0.44], { y: [24, 0], opacity: [0, 1] });
  t.to('.cam', [0.48, 0.6], focus(1092, 640, 1.45), 'inOut');
  t.to('.h-tap', [0.6, 0.63], { scale: [1.8, 1], opacity: [0, 1] });
  t.to('.h-btn', [0.62, 0.64], { scale: [1, 0.95] });
  t.to('.h-btn', [0.64, 0.66], { scale: 1 });
  t.to('.h-tap', [0.64, 0.67], { scale: 2.4, opacity: 0 });
  t.to('.h4', [0.63, 0.66], { y: [24, 0], opacity: [0, 1] });
  t.to('.h-first', [0.65, 0.73], { x: [0, -120], opacity: [1, 0] }, 'out');
  t.to('.h-next', [0.65, 0.73], { x: [420, 0] }, 'out');
  t.to('.cam', [0.77, 0.9], { x: 0, y: 0, scale: 1 }, 'inOut');
  t.to('.h5', [0.81, 0.87], { y: [24, 0], opacity: [0, 1] });
});

defineTimeline('old', (t) => {
  t.fill('.line', [0.0, 0.13]);
  t.to('.statement', [0.15, 0.22], { y: [0, -60], scale: [1, 0.9], opacity: [1, 0] }, 'in');

  // Each window lands at its own depth, so the pile has real space in it.
  const windows = [['.m1', -240, -6], ['.m2', -360, 5], ['.m3', -60, -2], ['.m4', -160, 4], ['.m5', -300, -5]];
  windows.forEach(([name, z, rotate], index) => {
    t.to(name, [0.16 + index * 0.012, 0.28 + index * 0.012], { y: [320, 0], z: [z - 300, z], rotate: [rotate * 2.4, rotate], opacity: [0, 1] }, 'out');
  });
  t.to('.switcher', [0.3, 0.35], { scale: [0.86, 1], opacity: [0, 1] }, 'out');
  const order = [['.m1', 0], ['.m2', 108], ['.m3', 216], ['.m4', 324], ['.m5', 432]];
  order.forEach(([name, x], index) => {
    const start = 0.34 + index * 0.058;
    t.to('.sw-ring', [start, start + 0.024], { x }, 'inOut');
    t.to(name, [start, start + 0.024], { z: 240, rotate: 0, '--lift': 1 }, 'out');
    if (index < 4) t.to(name, [start + 0.05, start + 0.074], { z: windows[index][1] }, 'inOut');
  });
  t.to('.switcher', [0.63, 0.67], { y: 80, opacity: 0 }, 'in');

  // Everything falls into one point, and the window that replaces it all arrives on the light.
  windows.forEach(([name], index) => {
    t.to(name, [0.65 + index * 0.004, 0.75], { x: [0, [-520, 340, -30, -400, 240][index]], y: [0, [240, 280, 120, 20, 20][index]], z: -900, rotate: 0, opacity: 0 }, 'in');
  });
  t.to('.flash', [0.72, 0.75], { scale: [0.2, 1.3], opacity: [0, 1] }, 'in');
  t.to('.flash', [0.75, 0.82], { scale: 2, opacity: 0 }, 'out');
  t.to('.one-win', [0.73, 0.84], { scale: [0.72, 1], opacity: [0, 1] }, 'out');
});

defineTimeline('loop', (t) => {
  t.fill('.line', [0.0, 0.1]);
  t.to('.statement', [0.12, 0.2], { y: [0, -60], scale: [1, 0.9], opacity: [1, 0] }, 'in');
  t.to('.l-phone', [0.12, 0.3], { y: [900, 0], ry: [-42, 0], rotate: [7, 0] }, 'out');
  t.to('.comet', [0.26, 0.31], { opacity: [0, 1] });
  t.to('.comet rect', [0.26, 0.92], { dash: [1, -3.4] }, 'linear');
  t.to('.comet', [0.9, 0.96], { opacity: 0 });

  // Verbs light up one at a time; only the live one is at full strength.
  const beats = [[0.24, 0.42], [0.36, 0.48], [0.46, 0.68], [0.68, 1.1]];
  ['.v1', '.v2', '.v3', '.v4'].forEach((name, index) => {
    t.to(name, [beats[index][0], beats[index][0] + 0.03], { opacity: [0.14, 1], x: [-14, 0] });
    if (index < 3) t.to(name, [beats[index][1], beats[index][1] + 0.03], { opacity: 0.26, x: 0 });
  });
  t.to('.l1', [0.3, 0.33], { opacity: [0, 1], x: [18, 0] });
  t.to('.over', [0.31, 0.32], { opacity: [0, 1] });
  t.to('.l2', [0.42, 0.45], { opacity: [0, 1], x: [18, 0] });

  // Dive onto the bug, hold, fix it, pull out.
  t.to('.cam', [0.46, 0.57], focus(880, 840, 2.05), 'inOut');
  t.to('.reticle', [0.54, 0.58], { opacity: [0, 1], scale: [1.5, 1] }, 'snap');
  t.to('.l3', [0.54, 0.57], { opacity: [0, 1], x: [18, 0] });
  t.to('.l4', [0.63, 0.66], { opacity: [0, 1], x: [18, 0] });
  t.to('.reticle', [0.64, 0.67], { opacity: 0 });
  t.to('.over', [0.65, 0.67], { opacity: 0 });
  t.to('.fixed', [0.65, 0.72], { opacity: [0, 1], scale: [0.9, 1] }, 'snap');
  t.to('.good', [0.7, 0.75], { opacity: [0, 1], scale: [0.2, 1] }, 'snap');
  t.to('.cam', [0.76, 0.88], { x: 0, y: 0, scale: 1 }, 'inOut');
  t.to('.l5', [0.78, 0.81], { opacity: [0, 1], x: [18, 0] });
});

defineTimeline('design', (t) => {
  // Real rendered screens, cut into bands that land one after another.
  t.root.querySelectorAll('[data-slices]').forEach((phone) => {
    const index = phone.dataset.slices;
    const content = phone.querySelector('.ph-content');
    const bands = [[0, 196], [196, 330], [330, 480], [480, 640], [640, 760], [760, 852]];
    content.innerHTML = bands.map(([top, end]) => `<div class="slice" style="top:${top}px;height:${end - top + 1}px"><img src="/assets/design/screen-${index}.jpg" alt="" style="top:${-10 - top}px"></div>`).join('');
  });

  t.fill('.line', [0, 0.09]);
  t.to('.statement', [0.11, 0.18], { y: [0, -60], scale: [1, 0.9], opacity: [1, 0] }, 'in');

  // Starts inside the code, big enough to read every character.
  t.to('.cam', [0, 0.001], focus(275, 500, 2.0), 'linear');
  t.to('.code', [0.13, 0.19], { opacity: [0, 1] });
  for (let i = 1; i <= 12; i += 1) {
    const start = 0.17 + (i - 1) * 0.013;
    t.to(`.c${i}`, [start, start + 0.013], { opacity: [0, 1], x: [-14, 0] }, 'out');
  }
  // Pull back: the code was only ever one part of the canvas.
  t.to('.cam', [0.34, 0.5], focus(800, 500, 1.0), 'inOut');

  [0, 1, 2].forEach((screen) => {
    const start = [0.43, 0.56, 0.66][screen];
    t.to(`.n${screen}`, [start - 0.01, start + 0.02], { opacity: [0, 1] });
    t.to(`.f${screen} vx-phone`, [start - 0.02, start + 0.03], { opacity: [0, 1], y: [40, 0] }, 'out');
    t.to(`.f${screen} .slice`, [start, start + 0.05], { y: [70, 0], opacity: [0, 1], scale: [0.96, 1] }, 'out', { stagger: 0.012 });
  });
  t.to('.build', [0.82, 0.86], { y: [20, 0], opacity: [0, 1] }, 'snap');
  t.to('.build', [0.92, 0.935], { scale: [1, 0.94] });
  t.to('.build', [0.935, 0.96], { scale: 1 }, 'snap');
});

defineTimeline('chat', (t) => {
  t.fill('.line', [0, 0.1]);
  t.to('.statement', [0.12, 0.18], { y: [0, -60], scale: [1, 0.9], opacity: [1, 0] }, 'in');
  // The whole story starts in the composer, close enough to read.
  t.to('.cam', [0, 0.001], focus(800, 800, 1.45), 'linear');
  t.to('.c-win', [0.12, 0.2], { y: [120, 0], opacity: [0, 1] }, 'out');
  t.to('.c-typed', [0.18, 0.22], { type: [0, 1] }, 'linear');
  t.to('.menu', [0.2, 0.26], { y: [40, 0], scale: [0.92, 1], opacity: [0, 1] }, 'out');
  t.to('.menu > div', [0.21, 0.26], { x: [22, 0], opacity: [0, 1] }, 'out', { stagger: 0.008 });
  // The highlight walks down the list as you scroll, then back to the one you want.
  t.to('.menu-hi', [0.28, 0.31], { y: 50 }, 'inOut');
  t.to('.menu-hi', [0.32, 0.35], { y: 100 }, 'inOut');
  t.to('.menu-hi', [0.36, 0.39], { y: 0 }, 'inOut');
  t.to('.menu', [0.41, 0.44], { y: 30, scale: 0.96, opacity: 0 }, 'in');
  t.to('.c-typed', [0.41, 0.43], { opacity: [1, 0] }, 'linear');

  // Plan: the light itself changes colour with the mode.
  t.to('.m-ask', [0.44, 0.47], { opacity: [1, 0], scale: 0.8 }, 'out');
  t.to('.m-plan', [0.44, 0.49], { opacity: [0, 1], scale: [1.3, 1] }, 'snap');
  t.to('.g2', [0.44, 0.5], { opacity: [0, 1] }, 'linear');
  t.to('.cam', [0.46, 0.57], { x: 0, y: 0, scale: 1 }, 'inOut');
  t.to('.c-a', [0.5, 0.53], { y: [20, 0], opacity: [0, 1] });
  t.to('.c-b', [0.54, 0.58], { y: [20, 0], opacity: [0, 1] });

  // Auto: green, and the work simply starts running.
  t.to('.m-plan', [0.64, 0.67], { opacity: 0, scale: 0.8 }, 'out');
  t.to('.m-auto', [0.64, 0.69], { opacity: [0, 1], scale: [1.3, 1] }, 'snap');
  t.to('.g2', [0.64, 0.7], { opacity: 0 }, 'linear');
  t.to('.g3', [0.64, 0.7], { opacity: [0, 1] }, 'linear');
  t.to('.c-c', [0.68, 0.71], { y: [20, 0], opacity: [0, 1] }, 'snap');
  t.to('.c-d', [0.72, 0.75], { y: [20, 0], opacity: [0, 1] }, 'snap');
  t.to('.c-e', [0.76, 0.79], { y: [20, 0], opacity: [0, 1] }, 'snap');
  t.to('.c-f', [0.82, 0.85], { y: [20, 0], opacity: [0, 1] });
});

defineTimeline('agents', (t) => {
  t.fill('.line', [0, 0.09]);
  t.to('.statement', [0.1, 0.16], { y: [0, -60], scale: [1, 0.9], opacity: [1, 0] }, 'in');
  // Start close on the keys, with the line waiting behind them.
  t.to('.cam', [0, 0.001], focus(330, 440, 1.5), 'linear');
  t.to('.keys', [0.12, 0.17], { opacity: [0, 1], y: [40, 0] }, 'out');
  t.to('.main-label', [0.14, 0.18], { opacity: [0, 1] });
  t.to('.p0', [0, 0.001], { dash: [1, 1] }, 'linear');
  t.to('.k1', [0.2, 0.215], { y: [0, 8] }, 'out');
  t.to('.k2', [0.205, 0.22], { y: [0, 8] }, 'out');
  t.to('.k1', [0.225, 0.25], { y: 0 }, 'snap');
  t.to('.k2', [0.225, 0.25], { y: 0 }, 'snap');
  // Pressing it sends light down the line, and the camera runs out with it.
  t.to('.p0', [0.22, 0.3], { dash: 0 }, 'inOut');
  t.to('.cam', [0.22, 0.36], focus(800, 500, 1), 'inOut');
  t.to('.keys', [0.26, 0.32], { opacity: 0, x: -60 }, 'in');
  t.to('.p1', [0.27, 0.38], { dash: [1, 0] }, 'inOut');
  t.to('.p2', [0.285, 0.39], { dash: [1, 0] }, 'inOut');
  t.to('.p3', [0.3, 0.4], { dash: [1, 0] }, 'inOut');
  t.to('.ag1', [0.36, 0.41], { opacity: [0, 1], x: [60, 0] }, 'out');
  t.to('.ag2', [0.37, 0.42], { opacity: [0, 1], x: [60, 0] }, 'out');
  t.to('.ag3', [0.38, 0.43], { opacity: [0, 1], x: [60, 0] }, 'out');
  // All three work at once: real counters, real progress.
  const counters = [['.x1', 212, 0.42], ['.x2', 38, 0.42], ['.x3', 146, 0.44], ['.x4', 91, 0.44], ['.x5', 87, 0.46], ['.x6', 12, 0.46]];
  counters.forEach(([name, value, start]) => t.to(name, [start, 0.68], { count: [0, value] }, 'linear'));
    [['.b1', 0.92], ['.b2', 1], ['.b3', 0.7]].forEach(([name, end], i) => {
    t.to(name, [0.42 + i * 0.01, 0.68], { x: [-460, -460 * (1 - end)] }, 'out');
  });
  // The losers fall back into the dark. The winner goes home, and it's the only light left.
  t.to(['.ag1', '.ag3'].flatMap((q) => t.all(q)), [0.71, 0.8], { opacity: 0.0, z: -400 }, 'in');
  t.to('.p1', [0.7, 0.8], { dash: 1 }, 'inOut');
  t.to('.p3', [0.7, 0.8], { dash: 1 }, 'inOut');
  t.to('.ag2', [0.74, 0.82], { scale: 1.06 }, 'inOut');
  t.to('.p4', [0.8, 0.88], { dash: [1, 0] }, 'inOut');
  t.to('.merged', [0.84, 0.9], { y: [30, 0], opacity: [0, 1], scale: [0.9, 1] }, 'snap');
});

defineTimeline('sim', (t) => {
  t.fill('.line', [0, 0.09]);
  t.to('.statement', [0.1, 0.17], { y: [0, -60], scale: [1, 0.9], opacity: [1, 0] }, 'in');
  // A phone turns into place at the centre; the window then forms around where it lands.
  t.to('.s-phone', [0.12, 0.28], { x: [-200, -200], y: [960, 0], ry: [-58, 0], rotate: [8, 0] }, 'out');
  t.to('.cam', [0, 0.001], focus(1048, 500, 1), 'linear');
  t.to('.s-frame', [0.28, 0.38], { opacity: [0, 1], scale: [1.08, 1] }, 'out');
  t.to('.s-phone', [0.3, 0.4], { scale: [1, 0.92], x: -200 }, 'inOut');
  t.to('.cam', [0.42, 0.5], focus(848, 500, 1.15), 'inOut');
  // What Claude actually sees: every element, by name.
  t.to('.ax:not(.hit)', [0.44, 0.48], { opacity: [0, 1], scale: [1.08, 1] }, 'out', { stagger: 0.012 });
  t.to('.a4', [0.5, 0.54], { opacity: [0, 1], scale: [1.12, 1] }, 'snap');
  t.to('.s-tap', [0.56, 0.585], { opacity: [0, 1], scale: [1.8, 1] });
  t.to('.s-tap', [0.585, 0.62], { opacity: 0, scale: 2.5 });
  t.to('.sx', [0.58, 0.61], { opacity: [0, 1], y: [20, 0] }, 'snap');
  t.to('.s-new', [0.6, 0.64], { opacity: [0, 1], x: [30, 0] }, 'snap');
  t.to('.ax', [0.64, 0.67], { opacity: 0 });

  // Pull out, drop the window, and the one device becomes three.
  t.to('.s-frame', [0.68, 0.74], { opacity: 0, scale: 0.96 }, 'in');
  t.to('.s-phone', [0.7, 0.82], { x: -240, scale: 0.92 }, 'inOut');
  t.to('.cam', [0.7, 0.82], focus(800, 500, 1), 'inOut');
  t.to('.s-small', [0.72, 0.86], { x: [260, -130], z: [-500, -240], ry: [0, 22], opacity: [0, 1] }, 'out');
  t.to('.s-pad', [0.74, 0.88], { x: [-420, -20], z: [-600, -260], ry: [0, -24], opacity: [0, 1] }, 'out');
});

defineTimeline('browser', (t) => {
  t.fill('.line', [0, 0.09]);
  t.to('.statement', [0.1, 0.16], { y: [0, -60], scale: [1, 0.9], opacity: [1, 0] }, 'in');
  // The address bar is the whole stage, so the route is impossible to miss.
  t.to('.cam', [0, 0.001], focus(620, 160, 1.9), 'linear');
  t.to('.b-win', [0.12, 0.18], { opacity: [0, 1] });
  t.to('.route', [0.17, 0.32], { type: [0, 1] }, 'linear');
  t.to('.cam', [0.34, 0.46], { x: 0, y: 0, scale: 1 }, 'inOut');
  t.to('.b1x', [0.38, 0.42], { opacity: [0, 1], y: [18, 0] });
  t.to(['.b2x', '.b3x', '.b4x'].flatMap((q) => t.all(q)), [0.4, 0.44], { opacity: [0, 1], y: [18, 0] }, 'out', { stagger: 0.012 });
  // A crosshair works its way down the page, hesitating over each row.
  t.to('.cross', [0.46, 0.49], { opacity: [0, 1], x: [1260, 1260], y: [280, 280] }, 'out');
  t.to('.cross', [0.5, 0.55], { x: 780, y: 375 }, 'inOut');
  t.to('.cross', [0.56, 0.61], { x: 800, y: 590 }, 'inOut');
  t.to('.cross', [0.61, 0.63], { scale: [1, 0.65] }, 'out');
  t.to('.b4x', [0.61, 0.63], { scale: [1, 0.98] }, 'out');
  t.to('.cross', [0.63, 0.65], { scale: 1 }, 'snap');
  t.to('.b4x', [0.63, 0.65], { scale: 1 }, 'snap');
  t.to('.cross', [0.65, 0.69], { opacity: 0 });
  t.to('.console', [0.66, 0.72], { y: [150, 0], opacity: [0, 1] }, 'out');
  t.to('.k1x', [0.68, 0.7], { opacity: [0, 1] });
  t.to('.k2x', [0.71, 0.73], { opacity: [0, 1] });
  t.to('.k3x', [0.74, 0.76], { opacity: [0, 1] });
  t.to('.zero', [0.78, 0.84], { opacity: [0, 1], scale: [0.5, 1], rotate: [-5, -2] }, 'snap');
});

defineTimeline('approve', (t) => {
  t.fill('.line', [0, 0.09]);
  t.to('.statement', [0.1, 0.17], { y: [0, -60], scale: [1, 0.9], opacity: [1, 0] }, 'in');
  // You've walked away: the work carries on, small and quiet, in the distance.
  t.to('.r-win', [0.14, 0.26], { opacity: [0, 0.55], z: [-1200, -700] }, 'out');
  t.to('.r-card', [0, 0.001], { opacity: [0, 0] }, 'linear');
  t.to('.waiting', [0, 0.001], { opacity: [0, 0], scale: [0, 0] }, 'linear');
  t.to('.r-run', [0, 0.001], { opacity: [0, 0] }, 'linear');
  t.to('.r-say', [0, 0.001], { opacity: [0, 0] }, 'linear');
  // The tap on the shoulder: everything else holds still.
  t.to('.banner', [0.4, 0.45], { y: [-240, 0], opacity: [0, 1] }, 'snap');
  t.to('.waiting', [0.42, 0.45], { opacity: 1, scale: 1 }, 'snap');
  t.to('.cam', [0.45, 0.52], focus(1230, 90, 1.6), 'inOut');
  // Click it, and the camera crosses the room to the question.
  t.to('.banner', [0.56, 0.575], { scale: [1, 0.96] });
  t.to('.banner', [0.58, 0.62], { opacity: 0, x: 200 }, 'in');
  t.to('.r-win', [0.57, 0.68], { opacity: 1, z: 0 }, 'inOut');
  t.to('.cam', [0.57, 0.68], focus(800, 560, 1.32), 'inOut');
  t.to('.r-card', [0.62, 0.67], { opacity: 1, scale: [0.94, 1] }, 'snap');
  t.to('.r-yes', [0.72, 0.735], { scale: [1, 0.92] });
  t.to('.r-yes', [0.735, 0.76], { scale: 1 }, 'snap');
  t.to('.r-card', [0.75, 0.78], { opacity: 0, scale: 0.97 }, 'in');
  t.to('.waiting', [0.75, 0.77], { opacity: 0, scale: 0 });
  t.to('.r-run', [0.78, 0.81], { opacity: 1, y: [20, 0] }, 'snap');
  t.to('.r-say', [0.82, 0.85], { opacity: 1, y: [20, 0] });
  t.to('.r-count', [0.82, 0.92], { count: [0, 48] }, 'out');
  t.to('.cam', [0.82, 0.94], { x: 0, y: 0, scale: 1 }, 'inOut');
});

defineTimeline('review', (t) => {
  t.fill('.line', [0, 0.09]);
  t.to('.statement', [0.1, 0.17], { y: [0, -60], scale: [1, 0.9], opacity: [1, 0] }, 'in');
  t.to('.cam', [0, 0.001], focus(460, 500, 1.55), 'linear');
  t.to('.diff', [0.13, 0.19], { opacity: [0, 1], y: [50, 0] }, 'out');
  t.to('.diff .l', [0.18, 0.23], { opacity: [0.0, 1] }, 'linear', { stagger: 0.012 });
  ['.w1', '.w2', '.w3', '.w4', '.w5'].forEach((name, index) => {
    const start = 0.24 + index * 0.028;
    t.to(name, [start, start + 0.03], { wipe: [100, 0] }, 'inOut');
  });
  t.to('.cam', [0.4, 0.5], { x: 0, y: 0, scale: 1 }, 'inOut');
  t.to('.cmp', [0.42, 0.52], { x: [240, 0], ry: [-34, 0], opacity: [0, 1] }, 'out');
  t.to('.cam', [0.53, 0.6], focus(1218, 500, 1.04), 'inOut');
  t.to(['.divider', '.t-after', '.t-before'].flatMap((q) => t.all(q)), [0.54, 0.57], { opacity: [0, 1] });
  // The divider is the star: the scroll drags it, and the fix follows it across the screen.
  t.to('.divider', [0.56, 0.68], { x: [393, 62] }, 'inOut');
  t.to('.after', [0.56, 0.68], { wipe: [100, 84] }, 'inOut');
  t.to('.divider', [0.69, 0.82], { x: 372 }, 'inOut');
  t.to('.after', [0.69, 0.82], { wipe: 5.4 }, 'inOut');
  t.to('.cam', [0.84, 0.94], { x: 0, y: 0, scale: 1 }, 'inOut');
});

defineTimeline('skills', (t) => {
  t.fill('.line', [0, 0.09]);
  t.to('.statement', [0.1, 0.17], { y: [0, -60], scale: [1, 0.9], opacity: [1, 0] }, 'in');
  // Scattered through real depth, drifting; nearer ones move further, so the space reads as space.
  const scatter = [[-420, -240, -1600, -18], [-120, -480, -700, 12], [240, -420, -1200, -8], [560, -280, -500, 16], [-640, 40, -900, 10], [-220, 170, -1800, -14], [260, 110, -600, 9], [640, 120, -1400, -12], [-420, 360, -500, -9], [-60, 460, -1100, 14], [300, 420, -800, -16], [560, 380, -1700, 11]];
  scatter.forEach(([x, y, z, rotate], index) => {
    t.to(`.t${index}`, [0.12 + index * 0.006, 0.26 + index * 0.006], { opacity: [0, 0.85], x: [x * 1.3, x], y: [y * 1.3, y], z: [z - 700, z], rotate: [rotate * 1.6, rotate], ry: [rotate * 2, rotate] }, 'out');
    // Then each flies forward and locks on, in order, with a small settle.
    const start = 0.34 + index * 0.014;
    t.to(`.t${index}`, [start, start + 0.11], { opacity: 1, x: 0, y: 0, z: 0, rotate: 0, ry: 0 }, 'snap');
  });
  t.to('.m-search', [0.42, 0.5], { opacity: [0, 1], y: [-40, 0] }, 'out');
  t.to('.s-type', [0.46, 0.6], { type: [0, 1] }, 'linear');
  [['.i3', 0.62], ['.i1', 0.66], ['.i4', 0.7], ['.i2', 0.74]].forEach(([name, start]) => {
    t.to(name, [start, start + 0.04], { opacity: [0, 1], scale: [0.2, 1] }, 'snap');
  });
});

defineTimeline('usage', (t) => {
  // Bars for the skyline, the same shape on every visit.
  const skyline = t.root.querySelector('.skyline');
  skyline.innerHTML = Array.from({ length: 42 }, (_, i) => `<i style="--h:${Math.round(18 + 76 * Math.abs(Math.sin(i * 1.7) * Math.cos(i * 0.37)))}%"></i>`).join('');

  t.fill('.line', [0, 0.09]);
  t.to('.statement', [0.1, 0.17], { y: [0, -60], scale: [1, 0.9], opacity: [1, 0] }, 'in');
  t.to('.skyline i', [0.16, 0.38], { y: [760, 0] }, 'out', { stagger: 0.003 });
  t.to('.gauge', [0.15, 0.24], { opacity: [0, 1], scale: [0.86, 1] }, 'out');
  t.to('.fill', [0.2, 0.62], { dash: [1, 0.2] }, 'inOut');
  t.to('.g-num', [0.2, 0.62], { count: [0, 82] }, 'inOut');
  // Past about two thirds, it starts to run warm.
  t.to('.hot', [0, 0.001], { opacity: [0, 0] }, 'linear');
  t.to('.hot', [0.5, 0.62], { opacity: 1 }, 'linear');
  t.to('.hot', [0.2, 0.62], { dash: [1, 0.2] }, 'inOut');
  t.to('.gauge', [0.58, 0.7], { y: -80, scale: 0.86 }, 'inOut');
  t.to('.nudge', [0.64, 0.7], { y: [90, 0], opacity: [0, 1] }, 'snap');
  t.to('.cam', [0.7, 0.98], { scale: [1, 1.06] }, 'linear');
});
