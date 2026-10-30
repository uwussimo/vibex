// Vibex site components. Plain custom elements with no build step, so any new page gets the same
// nav, footer, install command and scroll scenes by loading this one file.
// Content stays in the light DOM: search engines, readers and no-JS visitors get all of it.

const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)');
const INSTALL = 'curl -fsSL https://vibex.cc/install.sh | sh';
const REPO = 'https://github.com/uwussimo/vibex';

const clamp = (value, low = 0, high = 1) => Math.min(high, Math.max(low, value));
const ease = (t) => t * t * (3 - 2 * t);
const window01 = (p, [a, b]) => (b === a ? (p >= a ? 1 : 0) : ease(clamp((p - a) / (b - a))));
const range = (text) => text.split('-').map(Number);

/* ---------- Scroll engine ---------- */

// Critically damped follow of the scroll position. Each frame moves from the current value, so
// reversing direction mid-scene never jumps, and a mouse wheel's steps read as continuous motion.
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

/**
 * <vx-scene length="300"> pins its `.pin` child for `length`vh of scrolling and plays a timeline:
 *   data-at="0.2-0.4"   sets --t from 0 to 1 over that part of the scene
 *   data-out="0.8-0.9"  sets --x from 0 to 1, for leaving
 *   data-type           reveals the element's text letter by letter with --t
 *   data-count="1284"   counts up to the number with --t (data-prefix, data-suffix)
 *   data-beat="0-0.33"  a caption that shows during that part
 * Elements read --t and --x in CSS, so every animation stays a transform or opacity.
 */
class VxScene extends HTMLElement {
  connectedCallback() {
    this.current = 0;
    this.targets = [...this.querySelectorAll('[data-at],[data-out]')].map((el) => ({
      el,
      at: el.dataset.at ? range(el.dataset.at) : null,
      out: el.dataset.out ? range(el.dataset.out) : null,
      text: 'type' in el.dataset ? el.textContent : null,
      count: el.dataset.count ? Number(el.dataset.count) : null,
      t: -1,
      x: -1,
    }));
    this.beats = [...this.querySelectorAll('[data-beat]')].map((el) => ({ el, at: range(el.dataset.beat), o: -1 }));
    this.bar = this.querySelector('.scene-progress i');
    this.apply = () => this.configure();
    reduceMotion.addEventListener('change', this.apply);
    this.configure();
    scenes.add(this);
    schedule();
  }

  disconnectedCallback() {
    scenes.delete(this);
    reduceMotion.removeEventListener('change', this.apply);
  }

  configure() {
    this.toggleAttribute('static', reduceMotion.matches);
    this.style.height = reduceMotion.matches ? '' : `${this.getAttribute('length') || 300}vh`;
    // Motion off means the finished state, not a blank one.
    if (reduceMotion.matches) this.render(1);
    else this.render(this.target());
    this.current = reduceMotion.matches ? 1 : this.target();
    this.measure();
  }

  measure() { this.span = Math.max(this.offsetHeight - innerHeight, 1); }

  target() { return clamp(-this.getBoundingClientRect().top / (this.span || Math.max(this.offsetHeight - innerHeight, 1))); }

  step(dt) {
    if (reduceMotion.matches) return false;
    const box = this.getBoundingClientRect();
    if (box.bottom < -innerHeight || box.top > innerHeight * 2) return false;
    const target = clamp(-box.top / this.span);
    const gap = target - this.current;
    this.current = Math.abs(gap) < 0.0004 ? target : this.current + gap * (1 - Math.exp(-dt / 0.085));
    this.render(this.current);
    return this.current !== target;
  }

  render(p) {
    for (const item of this.targets) {
      const t = item.at ? Math.round(window01(p, item.at) * 1000) / 1000 : 1;
      const x = item.out ? Math.round(window01(p, item.out) * 1000) / 1000 : 0;
      if (t !== item.t) {
        item.el.style.setProperty('--t', t);
        item.t = t;
        if (item.text !== null) item.el.textContent = item.text.slice(0, Math.round(item.text.length * t));
        if (item.count !== null) {
          const { prefix = '', suffix = '' } = item.el.dataset;
          item.el.textContent = `${prefix}${Math.round(item.count * t).toLocaleString('en-US')}${suffix}`;
        }
      }
      if (x !== item.x) { item.el.style.setProperty('--x', x); item.x = x; }
    }
    this.beats.forEach((beat, index) => {
      const fade = 0.05;
      const [a, b] = beat.at;
      const enter = index === 0 ? 1 : clamp((p - a) / fade);
      const leave = index === this.beats.length - 1 ? 1 : clamp((b - p) / fade);
      const o = Math.round(Math.min(enter, leave) * 100) / 100;
      if (o !== beat.o) {
        beat.el.style.setProperty('--o', o);
        beat.el.style.setProperty('--dy', `${Math.round((1 - enter) * 16 - (1 - leave) * 16)}px`);
        beat.el.toggleAttribute('inert', o === 0);
        beat.o = o;
      }
    });
    if (this.bar) this.bar.style.transform = `scaleX(${p})`;
  }
}

/**
 * <vx-art w="820" h="560"> scales a fixed-size drawing to whatever room it has, like a picture.
 * small-w and small-h give it a different shape on phones.
 */
class VxArt extends HTMLElement {
  connectedCallback() {
    this.canvas = this.querySelector(':scope > .art') || this.firstElementChild;
    this.observer = new ResizeObserver(() => this.fit());
    this.observer.observe(this);
    this.fit();
  }
  disconnectedCallback() { this.observer?.disconnect(); }
  fit() {
    const small = innerWidth <= 900 && this.hasAttribute('small-w');
    this.w = Number(this.getAttribute(small ? 'small-w' : 'w') || 820);
    this.h = Number(this.getAttribute(small ? 'small-h' : 'h') || 560);
    this.style.setProperty('--ratio', `${this.w} / ${this.h}`);
    this.canvas.style.width = `${this.w}px`;
    this.canvas.style.height = `${this.h}px`;
    const scale = Math.min(this.clientWidth / this.w, (this.clientHeight || Infinity) / this.h);
    if (scale > 0 && scale !== Infinity) this.canvas.style.transform = `translate(-50%, -50%) scale(${scale})`;
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

/** An iPhone: bezel, status bar and home indicator around a screen. */
class VxPhone extends HTMLElement {
  connectedCallback() {
    if (this.querySelector(':scope > .ph-screen')) return;
    const screen = document.createElement('div');
    screen.className = 'ph-screen';
    const bar = document.createElement('div');
    bar.className = 'ph-status';
    bar.innerHTML = '<b>9:41</b><i></i><span class="ph-icons"></span>';
    const home = document.createElement('div');
    home.className = 'ph-home';
    const content = document.createElement('div');
    content.className = 'ph-content';
    content.append(...this.childNodes);
    screen.append(bar, content, home);
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

const GITHUB_ICON = '<svg width="15" height="15" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M8 .2a8 8 0 0 0-2.53 15.59c.4.07.55-.17.55-.38v-1.33c-2.23.48-2.7-1.07-2.7-1.07-.36-.93-.89-1.17-.89-1.17-.73-.5.05-.49.05-.49.8.06 1.23.83 1.23.83.72 1.22 1.87.87 2.33.66.07-.52.28-.87.5-1.07-1.77-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.11 0 0 .67-.22 2.2.82a7.6 7.6 0 0 1 4 0c1.53-1.04 2.2-.82 2.2-.82.44 1.09.16 1.91.08 2.11.51.56.82 1.28.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48v2.2c0 .21.15.46.55.38A8 8 0 0 0 8 .2Z"/></svg>';

/** The site's navigation. Add a page by adding it here. */
class VxNav extends HTMLElement {
  connectedCallback() {
    const links = [['Design', '/#design'], ['Agents', '/#agents'], ['Features', '/#features'], ['Open source', '/#open-source'], ['FAQ', '/#faq']];
    this.innerHTML = `<header class="nav"><div class="wrap nav-row">
      <a class="brand" href="/"><img src="/icon.png" alt="" width="24" height="24">vibex</a>
      <nav aria-label="Sections">${links.map(([label, href]) => `<a href="${href}">${label}</a>`).join('')}</nav>
      <div class="nav-cta">
        <a class="btn btn-quiet btn-sm" href="${REPO}">${GITHUB_ICON}<span>Star</span><span class="stars" hidden></span></a>
        <a class="btn btn-primary btn-sm" href="/#install">Get Vibex</a>
      </div></div></header>`;
    // A real count or nothing: the page never shows a number it didn't just read.
    fetch('https://api.github.com/repos/uwussimo/vibex').then((reply) => (reply.ok ? reply.json() : null)).then((repo) => {
      if (!repo?.stargazers_count) return;
      const stars = this.querySelector('.stars');
      stars.textContent = repo.stargazers_count.toLocaleString('en-US');
      stars.hidden = false;
    }).catch(() => {});
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

/** A film that only loads when asked: the page stays light. */
class VxFilm extends HTMLElement {
  connectedCallback() {
    this.querySelector('button')?.addEventListener('click', () => {
      const video = document.createElement('video');
      video.src = this.getAttribute('src');
      video.poster = this.getAttribute('poster');
      video.controls = true;
      video.autoplay = true;
      video.playsInline = true;
      this.replaceChildren(video);
    });
  }
}

const define = (name, type) => { if (!customElements.get(name)) customElements.define(name, type); };
define('vx-art', VxArt);
define('vx-window', VxWindow);
define('vx-phone', VxPhone);
define('vx-install', VxInstall);
define('vx-nav', VxNav);
define('vx-footer', VxFooter);
define('vx-reveal', VxReveal);
define('vx-film', VxFilm);
define('vx-scene', VxScene); // Last: it reads what the others built.
