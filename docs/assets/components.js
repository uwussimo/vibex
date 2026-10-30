// Vibex site components. Plain custom elements with no build step, so any new page gets the same
// nav, footer, install command and scroll scenes by loading this one file.
// Content stays in the light DOM: search engines, readers and no-JS visitors get all of it.

const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)');
const INSTALL = 'curl -fsSL https://vibex.cc/install.sh | sh';
const REPO = 'https://github.com/uwussimo/vibex';

const clamp = (value, low = 0, high = 1) => Math.min(high, Math.max(low, value));
const range = (text) => text.split('-').map(Number);

/* ---------- Scroll engine ---------- */

// The scroll position is followed by a critically damped spring. Every frame moves from the current
// value, so reversing mid-scene never jumps and a mouse wheel's steps read as continuous motion.
const NAV_HEIGHT = 56;
const CAPTION_ROOM = 118;
const scenes = new Set();
let frame = 0;
let last = 0;

function tick(now) {
  frame = 0;
  const dt = Math.min((now - last) / 1000, 0.05);
  last = now;
  let moving = false;
  for (const scene of scenes) if (scene.step(dt)) moving = true;
  if (moving) schedule();
}
function schedule() {
  if (!frame) {
    if (!last || performance.now() - last > 100) last = performance.now() - 16;
    frame = requestAnimationFrame(tick);
  }
}
addEventListener('scroll', schedule, { passive: true });
addEventListener('resize', () => { for (const scene of scenes) scene.measure(); schedule(); });

export const easings = {
  linear: (t) => t,
  // Most motion: leaves fast, arrives gently, like something with weight coming to rest.
  out: (t) => 1 - (1 - t) ** 3.2,
  in: (t) => t ** 2.6,
  inOut: (t) => (t < 0.5 ? 4 * t ** 3 : 1 - (-2 * t + 2) ** 3 / 2),
  // A small overshoot, kept for things that snap into place.
  snap: (t) => { const c = 1.45; return 1 + (c + 1) * (t - 1) ** 3 + c * (t - 1) ** 2; },
};

const DEFAULTS = { x: 0, y: 0, z: 0, scale: 1, rotate: 0, rx: 0, ry: 0, opacity: 1, blur: 0 };
const TRANSFORM = new Set(['x', 'y', 'z', 'scale', 'rotate', 'rx', 'ry']);

/**
 * A scene's choreography. Each call adds segments to an element's properties; a property holds its
 * last value between segments, and before its first segment it holds that segment's start.
 *   t.to('.card', [0.2, 0.4], { y: [40, 0], opacity: [0, 1] }, 'out')
 *   t.to('.row', [0.2, 0.4], { x: [20, 0] }, 'out', { stagger: 0.02 })
 * Values: x y z (px), scale, rotate rx ry (deg), opacity, blur (px), dash (for pathLength="1"),
 * wipe (percent hidden from the right), wipeDown (percent hidden from the bottom), type (fraction of the text), count (number), and any --var.
 */
class Timeline {
  constructor(root) {
    this.root = root;
    this.tracks = new Map();
    this.words = [];
  }

  all(target) {
    if (typeof target !== 'string') return Array.isArray(target) ? target : [target];
    const found = [...this.root.querySelectorAll(target)];
    if (!found.length) console.warn('No element for', target);
    return found;
  }

  to(target, [a, b], props, ease = 'out', { stagger = 0 } = {}) {
    this.all(target).forEach((el, index) => {
      const track = this.tracks.get(el) || this.create(el);
      const start = a + stagger * index;
      const end = b + stagger * index;
      for (const [prop, value] of Object.entries(props)) {
        const list = track.props[prop] ||= [];
        const previous = list.length ? list[list.length - 1].to : (DEFAULTS[prop] ?? 0);
        const [from, to] = Array.isArray(value) ? value : [previous, value];
        list.push({ a: start, b: end, from, to, ease: easings[ease] });
      }
    });
    return this;
  }

  create(el) {
    const track = { el, props: {}, text: el.textContent, cache: {} };
    this.tracks.set(el, track);
    return track;
  }

  /** Fills a line of text in word by word as the scene plays. */
  fill(target, [a, b]) {
    for (const el of this.all(target)) {
      const words = el.textContent.trim().split(/\s+/);
      const keep = el.innerHTML;
      el.setAttribute('aria-label', el.textContent.trim());
      el.innerHTML = words.map((word) => `<span class="word" aria-hidden="true">${word}</span>`).join(' ');
      el.dataset.source = keep;
      [...el.children].forEach((word, index) => {
        const start = a + ((b - a) * index) / words.length;
        const end = start + ((b - a) / words.length) * 2.6;
        this.to(word, [start, Math.min(end, b + 0.02)], { opacity: [0.14, 1] }, 'linear');
      });
    }
    return this;
  }

  static value(list, p) {
    let current = list[0].from;
    for (const seg of list) {
      if (p < seg.a) break;
      current = p >= seg.b ? seg.to : seg.from + (seg.to - seg.from) * seg.ease((p - seg.a) / (seg.b - seg.a));
    }
    return current;
  }

  render(p) {
    for (const track of this.tracks.values()) {
      const { el, props, cache } = track;
      const read = (name) => (props[name] ? Timeline.value(props[name], p) : DEFAULTS[name]);
      if (Object.keys(props).some((name) => TRANSFORM.has(name))) {
        const transform = `translate3d(${read('x').toFixed(2)}px,${read('y').toFixed(2)}px,${read('z').toFixed(1)}px) rotate(${read('rotate').toFixed(2)}deg) rotateX(${read('rx').toFixed(2)}deg) rotateY(${read('ry').toFixed(2)}deg) scale(${read('scale').toFixed(4)})`;
        if (cache.transform !== transform) { el.style.transform = transform; cache.transform = transform; }
      }
      for (const [name, list] of Object.entries(props)) {
        if (TRANSFORM.has(name)) continue;
        const value = Timeline.value(list, p);
        if (cache[name] === value) continue;
        cache[name] = value;
        if (name === 'opacity') {
          el.style.opacity = value.toFixed(3);
          el.style.visibility = value <= 0.001 ? 'hidden' : '';
        } else if (name === 'blur') el.style.filter = value > 0.05 ? `blur(${value.toFixed(1)}px)` : '';
        else if (name === 'dash') el.style.strokeDashoffset = value.toFixed(4);
        else if (name === 'wipe') el.style.clipPath = `inset(0 ${value.toFixed(2)}% 0 0)`;
        else if (name === 'wipeDown') el.style.clipPath = `inset(0 0 ${value.toFixed(2)}% 0)`;
        else if (name === 'type') el.textContent = track.text.slice(0, Math.round(track.text.length * value));
        else if (name === 'count') {
          const { prefix = '', suffix = '' } = el.dataset;
          el.textContent = `${prefix}${Math.round(value).toLocaleString('en-US')}${suffix}`;
        } else el.style.setProperty(name, value.toFixed(3));
      }
    }
  }
}

const timelines = new Map();

/** Attaches choreography to <vx-scene timeline="name">. */
export function defineTimeline(name, build) {
  timelines.set(name, build);
  for (const scene of scenes) if (scene.getAttribute('timeline') === name) scene.useTimeline(build);
}

/**
 * <vx-scene length="400" timeline="hero" rest="0.9"> pins its `.stage` for `length`vh and plays a
 * timeline with the scroll. `rest` is the moment shown when motion is off: a finished picture.
 * Captions are <li data-beat="0.2-0.5">.
 */
class VxScene extends HTMLElement {
  connectedCallback() {
    this.current = 0;
    this.beats = [...this.querySelectorAll('[data-beat]')].map((el) => ({ el, at: range(el.dataset.beat), o: -1 }));
    this.world = this.querySelector('.world');
    this.stage = this.querySelector('.stage');
    this.apply = () => this.configure();
    reduceMotion.addEventListener('change', this.apply);
    scenes.add(this);
    const build = timelines.get(this.getAttribute('timeline'));
    if (build) this.useTimeline(build);
    this.configure();
    schedule();
  }

  disconnectedCallback() {
    scenes.delete(this);
    reduceMotion.removeEventListener('change', this.apply);
  }

  useTimeline(build) {
    if (this.timeline) return;
    this.timeline = new Timeline(this);
    build(this.timeline);
    this.configure();
  }

  configure() {
    const still = reduceMotion.matches;
    this.toggleAttribute('static', still);
    this.style.height = still ? '' : `${this.getAttribute('length') || 400}vh`;
    this.measure();
    this.current = still ? Number(this.getAttribute('rest') || 1) : clamp(-this.getBoundingClientRect().top / this.span);
    this.render(this.current);
  }

  measure() {
    this.span = Math.max(this.offsetHeight - innerHeight, 1);
    if (!this.world) return;
    const stage = this.querySelector('.stage');
    const width = stage.clientWidth;
    const narrow = width < 900;
    // Compositions keep what matters in the middle 900 points, so a phone crops the sides, not the idea.
    // The product gets what's left between the nav and the captions, so it can never run into either.
    const room = stage.clientHeight - NAV_HEIGHT - CAPTION_ROOM;
    const fit = this.hasAttribute('static')
      ? Math.min(width / 1600, 1)
      : Math.min(width / (narrow ? 900 : 1600), room / 1000);
    this.centerY = NAV_HEIGHT + room / 2;
    if (!this.hasAttribute('static')) this.world.style.top = `${Math.round(this.centerY)}px`;
    else this.world.style.top = '';
    this.world.style.setProperty('--fit', fit.toFixed(4));
    this.fit = fit;
    this.dispatchEvent(new CustomEvent('vx-measure'));
    if (this.hasAttribute('static')) this.world.parentElement.style.height = `${1000 * fit}px`;
  }

  step(dt) {
    if (reduceMotion.matches) return false;
    const box = this.getBoundingClientRect();
    if (box.bottom < -innerHeight || box.top > innerHeight * 2) return false;
    const target = clamp(-box.top / this.span);
    const gap = target - this.current;
    this.current = Math.abs(gap) < 0.0003 ? target : this.current + gap * (1 - Math.exp(-dt / 0.09));
    this.render(this.current);
    return this.current !== target;
  }

  render(p) {
    this.timeline?.render(p);
    let caption = 0;
    this.beats.forEach((beat) => {
      const fade = 0.035;
      const [a, b] = beat.at;
      const enter = clamp((p - a) / fade);
      const leave = b >= 1 ? 1 : clamp((b - p) / fade);
      const o = Math.round(Math.min(enter, leave) * 100) / 100;
      caption = Math.max(caption, o);
      if (o !== beat.o) {
        beat.el.style.opacity = o;
        beat.el.style.transform = `translateY(${Math.round((1 - easings.out(enter)) * 18 - (1 - leave) * 12)}px)`;
        beat.el.style.visibility = o === 0 ? 'hidden' : 'visible';
        beat.o = o;
      }
    });
    // The shade behind captions only exists while there's a caption: it must never dim the product.
    if (caption !== this.caption) {
      this.stage?.style.setProperty('--scrim', caption);
      this.caption = caption;
    }
  }
}

/* ---------- Shared pieces ---------- */

/** A Mac window: traffic lights and a title around whatever's inside. */
class VxWindow extends HTMLElement {
  connectedCallback() {
    if (this.querySelector(':scope > .win-bar')) return;
    const bar = document.createElement('div');
    bar.className = 'win-bar';
    bar.innerHTML = '<span class="lights"><i></i><i></i><i></i></span><span class="win-title"></span>';
    bar.querySelector('.win-title').textContent = this.getAttribute('title') || '';
    this.removeAttribute('title');
    const body = document.createElement('div');
    body.className = 'win-body';
    body.append(...this.childNodes);
    this.append(bar, body);
  }
}

/** An iPhone, at its real size in points: titanium edge, buttons, island and status bar. */
class VxPhone extends HTMLElement {
  connectedCallback() {
    if (this.querySelector(':scope > .ph-screen')) return;
    const content = document.createElement('div');
    content.className = 'ph-content';
    content.append(...this.childNodes);
    const screen = document.createElement('div');
    screen.className = 'ph-screen';
    screen.innerHTML = `<div class="ph-status"><b>9:41</b><span class="ph-icons"><svg width="18" height="12" viewBox="0 0 18 12" fill="currentColor"><rect y="8" width="3" height="4" rx=".8"/><rect x="5" y="5.5" width="3" height="6.5" rx=".8"/><rect x="10" y="3" width="3" height="9" rx=".8"/><rect x="15" width="3" height="12" rx=".8"/></svg><svg width="27" height="13" viewBox="0 0 27 13" fill="none"><rect x=".5" y=".5" width="23" height="12" rx="3.6" stroke="currentColor" opacity=".4"/><rect x="2" y="2" width="20" height="9" rx="2.2" fill="currentColor"/><rect x="25" y="4.2" width="1.6" height="4.6" rx=".8" fill="currentColor" opacity=".5"/></svg></span></div><i class="ph-island"></i>`;
    screen.append(content);
    const home = document.createElement('div');
    home.className = 'ph-home';
    screen.append(home);
    if (this.hasAttribute('src') || this.classList.contains('real')) {
      this.classList.add('real');
      const src = this.getAttribute('src');
      if (src) content.insertAdjacentHTML('afterbegin', `<img class="shot" src="${src}" alt="" loading="lazy">`);
    }
    this.innerHTML = '<i class="ph-btn a"></i><i class="ph-btn b"></i><i class="ph-btn c"></i><i class="ph-btn d"></i>';
    this.append(screen);
  }
}

/** The install command, one click to copy. */
class VxInstall extends HTMLElement {
  connectedCallback() {
    if (this.firstElementChild) return;
    this.innerHTML = `<button type="button" class="cmd" title="Copy the install command">
      <span class="cmd-p" aria-hidden="true">❯</span><code>${INSTALL}</code><span class="cmd-state">Copy</span></button>`;
    const state = this.querySelector('.cmd-state');
    this.querySelector('button').addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(INSTALL);
        state.textContent = 'Copied';
      } catch {
        state.textContent = 'Select it';
      }
      this.classList.add('done');
      setTimeout(() => { state.textContent = 'Copy'; this.classList.remove('done'); }, 1800);
    });
  }
}

const STAR_ICON = '<svg class="star-ic" width="16" height="16" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M12 2.6l2.9 5.9 6.5.95-4.7 4.6 1.1 6.5L12 17.5l-5.8 3.05 1.1-6.5-4.7-4.6 6.5-.95z"/></svg>';

/** A star count, shown once it's a number that helps: a small one would only argue against us. */
function loadStars(apply) {
  fetch('https://api.github.com/repos/uwussimo/vibex').then((reply) => (reply.ok ? reply.json() : null)).then((repo) => {
    if (repo?.stargazers_count >= 100) apply(repo.stargazers_count.toLocaleString('en-US'));
  }).catch(() => {});
}

/** The way to star the repo. <vx-star big> for the main call. */
class VxStar extends HTMLElement {
  connectedCallback() {
    const big = this.hasAttribute('big');
    const label = this.getAttribute('label') || 'Star on GitHub';
    this.innerHTML = `<a class="btn star-btn ${big ? '' : 'btn-sm'}" href="${REPO}">${STAR_ICON}<span>${label}</span><span class="stars" hidden></span></a>`;
    loadStars((count) => {
      const stars = this.querySelector('.stars');
      stars.textContent = count;
      stars.hidden = false;
    });
  }
}

/** A quiet reminder that follows the story, gone during the hero and at the end, which has its own. */
class VxStarFloat extends HTMLElement {
  connectedCallback() {
    this.innerHTML = `<a class="star-float" href="${REPO}">${STAR_ICON}<span>Star Vibex</span></a>`;
    const update = () => {
      const end = document.querySelector('#install')?.getBoundingClientRect().top ?? Infinity;
      this.classList.toggle('on', scrollY > innerHeight * 3 && end > innerHeight * 0.7);
    };
    addEventListener('scroll', update, { passive: true });
    update();
  }
}

/** The site's navigation. Add a page by adding it here. */
class VxNav extends HTMLElement {
  connectedCallback() {
    const links = [['Design', '/#design'], ['Agents', '/#agents'], ['Features', '/#features'], ['Open source', '/#open-source'], ['FAQ', '/#faq']];
    this.innerHTML = `<header class="nav"><div class="wrap nav-row">
      <a class="brand" href="/"><img src="/icon.png" alt="" width="24" height="24">vibex</a>
      <nav aria-label="Sections">${links.map(([label, href]) => `<a href="${href}">${label}</a>`).join('')}</nav>
      <div class="nav-cta">
        <vx-star label="Star"></vx-star>
        <a class="btn btn-primary btn-sm" href="/#install">Get Vibex</a>
      </div></div></header>`;
  }
}

/** The site's footer. */
class VxFooter extends HTMLElement {
  connectedCallback() {
    this.innerHTML = `<footer class="foot"><div class="wrap foot-row">
      <div><a class="brand" href="/"><img src="/icon.png" alt="" width="24" height="24">vibex</a>
      <p>The Mac workstation where your coding agent sees what it builds. Free and MIT licensed.<br>Made by <a href="https://github.com/uwussimo">Yusuf Abdurakhimov</a>.</p></div>
      <nav aria-label="Links"><a href="${REPO}">GitHub</a><a href="${REPO}/releases">Releases</a><a href="${REPO}/issues">Issues</a><a href="/install.sh">install.sh</a></nav>
      <p class="foot-legal">© 2026 Vibex contributors · MIT License · Not affiliated with Apple or Anthropic.</p>
      </div></footer>`;
  }
}

/** Shows content as it scrolls in, once, for sections that aren't pinned. */
class VxReveal extends HTMLElement {
  connectedCallback() {
    if (reduceMotion.matches) { this.classList.add('in'); return; }
    this.classList.add('armed');
    this.observer = new IntersectionObserver((entries) => {
      if (entries.some((entry) => entry.isIntersecting)) {
        this.classList.add('in');
        this.observer.disconnect();
      }
    }, { rootMargin: '0px 0px -10% 0px' });
    this.observer.observe(this);
  }
  disconnectedCallback() { this.observer?.disconnect(); }
}

const define = (name, type) => { if (!customElements.get(name)) customElements.define(name, type); };
define('vx-window', VxWindow);
define('vx-phone', VxPhone);
define('vx-install', VxInstall);
define('vx-nav', VxNav);
define('vx-footer', VxFooter);
define('vx-reveal', VxReveal);
define('vx-star', VxStar);
define('vx-star-float', VxStarFloat);
define('vx-scene', VxScene);
