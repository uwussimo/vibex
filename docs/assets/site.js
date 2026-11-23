// Vibex site: the pinned phone's steps, the statement that fills in as you read, the copy buttons
// and the star count. No build step and no dependencies.

const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;
const narrow = matchMedia('(max-width: 880px)');

/* ---------- Trails screens: cloned from the template and scaled to each frame ---------- */

const screens = document.getElementById('ios-screens');
const fit = new ResizeObserver((entries) => {
  for (const entry of entries) entry.target.style.setProperty('--k', entry.contentRect.width / 393);
});
document.querySelectorAll('[data-ios]').forEach((host) => {
  const screen = screens?.content.querySelector(`[data-name="${host.dataset.ios}"]`);
  if (!screen) return;
  host.append(screen.cloneNode(true));
  fit.observe(host);
});

/* ---------- In action ---------- */

const action = document.querySelector('.action');
const stage = action?.querySelector('.stage');
const steps = 4;
let shown = -1;

function show(step) {
  if (!stage || step === shown) return;
  shown = step;
  stage.dataset.step = step;
  stage.querySelectorAll('.screen').forEach((el) => el.classList.toggle('is-on', +el.dataset.step === step));
  stage.querySelectorAll('.note, .wires path').forEach((el) => {
    const n = +el.dataset.step;
    el.classList.toggle('is-seen', n <= step);
    el.classList.toggle('is-now', n === step);
  });
}

function onScroll() {
  if (!action || narrow.matches) return;
  const box = action.getBoundingClientRect();
  const travel = box.height - innerHeight;
  const progress = Math.min(1, Math.max(0, -box.top / Math.max(travel, 1)));
  show(Math.min(steps - 1, Math.floor(progress * steps * 0.999)));
}

// On a phone there's no room to pin it, so the screens play on their own and every note shows.
let timer = 0;
function syncLayout() {
  clearInterval(timer);
  if (narrow.matches) {
    stage?.querySelectorAll('.note, .wires path').forEach((el) => el.classList.add('is-seen'));
    if (!reduceMotion) {
      let step = 0;
      timer = setInterval(() => {
        step = (step + 1) % steps;
        stage.dataset.step = step;
        stage.querySelectorAll('.screen').forEach((el) => el.classList.toggle('is-on', +el.dataset.step === step));
      }, 2600);
    }
  } else {
    shown = -1;
    onScroll();
  }
}
if (stage) {
  show(0);
  syncLayout();
  narrow.addEventListener('change', syncLayout);
}

/* ---------- Statement ---------- */

const statement = document.querySelector('[data-fill]');
let words = [];
if (statement) {
  const text = statement.textContent.trim();
  statement.textContent = '';
  words = text.split(/\s+/).map((word, i, all) => {
    const span = document.createElement('span');
    span.className = 'w';
    span.textContent = word + (i < all.length - 1 ? ' ' : '');
    statement.append(span);
    return span;
  });
  if (reduceMotion) words.forEach((w) => w.classList.add('on'));
}
function fill() {
  if (!words.length || reduceMotion) return;
  const box = statement.getBoundingClientRect();
  // Starts filling as it enters the lower part of the screen, done by the time it reaches the middle.
  const progress = Math.min(1, Math.max(0, (innerHeight * 0.85 - box.top) / (innerHeight * 0.5)));
  const lit = Math.round(progress * words.length);
  words.forEach((w, i) => w.classList.toggle('on', i < lit));
}

let frame = 0;
addEventListener('scroll', () => {
  if (frame) return;
  frame = requestAnimationFrame(() => { frame = 0; onScroll(); fill(); });
}, { passive: true });
addEventListener('resize', () => { onScroll(); fill(); });
fill();

/* ---------- Logos: two copies, so the strip loops without a seam ---------- */

const track = document.querySelector('.track');
if (track && !reduceMotion) {
  [...track.children].forEach((item) => {
    const copy = item.cloneNode(true);
    copy.setAttribute('aria-hidden', 'true');
    track.append(copy);
  });
}

/* ---------- Copy ---------- */

document.querySelectorAll('[data-copy]').forEach((button) => {
  const label = button.querySelector('.copied');
  button.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(button.dataset.copy);
      button.classList.add('done');
      label.textContent = 'Copied';
    } catch {
      label.textContent = 'Select and copy';
    }
    setTimeout(() => { button.classList.remove('done'); label.textContent = 'Copy'; }, 1800);
  });
});

/* ---------- Stars ---------- */

const stars = document.querySelector('[data-stars]');
if (stars) {
  const format = (n) => (n >= 1000 ? (n / 1000).toFixed(n >= 10000 ? 0 : 1).replace(/\.0$/, '') + 'k' : String(n));
  let cached = null;
  try { cached = JSON.parse(sessionStorage.getItem('vibex-stars') || 'null'); } catch {}
  if (cached) stars.textContent = format(cached);
  else fetch('https://api.github.com/repos/uwussimo/vibex')
    .then((r) => (r.ok ? r.json() : null))
    .then((repo) => {
      if (!repo || typeof repo.stargazers_count !== 'number') return;
      stars.textContent = format(repo.stargazers_count);
      try { sessionStorage.setItem('vibex-stars', JSON.stringify(repo.stargazers_count)); } catch {}
    })
    .catch(() => {});
}
