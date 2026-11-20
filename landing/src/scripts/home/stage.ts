// The pinned hero and story. One scrub drives everything: the run is 5.6
// viewports, 0.8 for the hero handing the phone over, five steps of 0.9, and
// 0.3 of hold before release. All state is derived from progress, so nothing
// can be skipped or fall out of sync.
import { EXPO, all, animate, beats, clamp, count, lerp, q, scrollToY, scrub, span, still, tilt, visible, wait } from '../motion';

type Glow = 'n' | 'r' | 'y' | 'g';
/** Called each time a step becomes current; loops until `alive()` turns false. */
type Player = (dev: HTMLElement, alive: () => boolean, glow: (c: Glow) => void) => void;

const spring = (el: Element) => getComputedStyle(el).getPropertyValue('--spring').trim() || EXPO;

// Reset a fragment, then switch it on after a breath so the entrance always replays.
function arm(dev: HTMLElement, sel: string, cls: string, alive: () => boolean, ms: number, then?: () => void) {
  const set = (on: boolean) => all(sel, dev).forEach((el) => el.classList.toggle(cls, on));
  if (still) {
    set(true);
    then?.();
    return;
  }
  set(false);
  void wait(ms).then(() => {
    if (!alive()) return;
    set(true);
    then?.();
  });
}

const players: Player[] = [
  // Console: Payments API goes Blocked and jumps the queue. FLIP on offsetTop.
  (dev, alive, glow) => {
    const list = q('.rw', dev);
    const pay = q('[data-k=pay]', list);
    const auth = q('[data-k=auth]', list);
    const label = q('em', pay);
    function sort(blocked: boolean, quiet?: boolean) {
      const kids = all(':scope > li', list);
      const tops = kids.map((k) => k.offsetTop);
      pay.setAttribute('data-s', blocked ? 'b' : 'w');
      label.textContent = blocked ? 'Blocked' : 'Working';
      list.insertBefore(pay, blocked ? list.firstChild : auth.nextSibling);
      glow(blocked ? 'r' : 'n');
      if (quiet) return;
      kids.forEach((k, i) => {
        const d = (tops[i] ?? 0) - k.offsetTop;
        if (d) animate(k, [{ transform: `translateY(${d}px)` }, { transform: 'none' }], k === pay ? { duration: 900, easing: spring(dev) } : { duration: 650, easing: EXPO });
      });
      animate(q('.rg i', pay), [{ transform: 'scale(1)', opacity: 0.8 }, { transform: 'scale(2.6)', opacity: 0 }], { duration: 900, easing: EXPO });
    }
    if (still) return sort(true, true);
    sort(false, true);
    beats(alive, [1100, () => sort(true), 3800, () => sort(false), 1500]);
  },
  // Chat: a tap lands on Allow and Blocked flips to Working.
  (dev, alive, glow) => {
    const card = q('.f1', dev);
    function state(s: 'b' | 'w') {
      card.setAttribute('data-st', s);
      card.classList.remove('is-aim', 'is-tap');
      glow(s === 'b' ? 'r' : 'y');
    }
    if (still) return state('w');
    state('b');
    beats(alive, [1300, () => card.classList.add('is-aim'), 620, () => card.classList.add('is-tap'), 180, () => state('w'), 4400, () => state('b')]);
  },
  // Terminal: the switch slides over, the key row pops in.
  (dev, alive) => arm(dev, '.f2,.f2k', 'is-t', alive, 600),
  // Away: the Dynamic Island opens, the banner drops.
  (dev, alive, glow) => arm(dev, '.f3i,.f3', 'is-go', alive, 500, () => glow('r')),
  // Usage: bars fill while the numbers count.
  (dev, alive) => {
    const numbers = all('.f4 em', dev);
    if (!still) numbers.forEach((n) => (n.textContent = '0%'));
    arm(dev, '.f4', 'is-go', alive, 450, () => {
      numbers.forEach((n) => count(n, Number(n.getAttribute('data-n')), 1400, (v) => `${Math.round(v)}%`));
    });
  },
];

export function wireStage() {
  const stage = q('.stage');
  const hero = q('.hero', stage);
  const heroNote = q('.hero-n', stage);
  const scrim = q('.scr', stage);
  const copy = q('.sc', stage);
  const wheel = q('.wh', stage);
  const rail = q('.rl', stage);
  const dev = q('.dev', stage);
  const pose = q('.dv-pose', dev);
  const tiltEl = q('.dv-tilt', dev);
  const steps = all('.st', stage);
  const ticks = all('button', rail);
  const frags = all('.fg', dev);
  const screens = all<HTMLImageElement>('.lp-phone-screen img', dev);
  // The stacked stage, as in stage.css.
  const narrow = matchMedia('(max-width: 559px), (max-width: 899px) and (orientation: portrait)');
  const REST = [-7, 6, -6, 5, -5]; // the phone turns a few degrees at every step
  const GLOW: Glow[] = ['n', 'r', 'g', 'n', 'n']; // resting glow per step; players flip it on their beat
  const H = 0.8;
  const S = 0.9;
  const RUN = 5.6;
  const Z = 0.2; // half-width of the scrubbed transition around a boundary
  const LAST = steps.length - 1;
  let cur = -2;
  let token = 0;
  let seen = true;
  let lastH = -1;
  let lastX = -1;
  let lastP = 0;
  let heroY = 0;

  const glow = (c: Glow) => dev.setAttribute('data-glow', c);
  // Narrow: the hero phone (drawn at 1.16) starts 36px under the hero copy, wherever that wraps to.
  // The first toast straddles the phone's top edge and takes about half of that gap.
  function measure() {
    const ph = dev.offsetHeight;
    heroY = narrow.matches ? Math.max(0, heroNote.offsetTop + heroNote.offsetHeight + 36 - (dev.offsetTop - ph / 2) + ph * 0.08) : 0;
  }

  function play() {
    const my = ++token;
    if (seen) players[cur]?.(dev, () => my === token, glow);
  }
  function setStep(i: number) {
    const s = Math.max(0, i);
    cur = i;
    stage.setAttribute('data-step', String(i));
    // Earlier screens sit above and behind (a), later ones wait below (b).
    screens.forEach((im, j) => {
      im.classList.toggle('is-on', j === s);
      if (j === s) im.loading = 'eager';
      im.setAttribute('data-p', j < s ? 'a' : j > s ? 'b' : '');
    });
    frags.forEach((f) => f.classList.toggle('is-on', Number(f.getAttribute('data-f')) === i));
    ticks.forEach((t, j) => {
      t.classList.toggle('is-cur', j === i);
      if (j === i) t.setAttribute('aria-current', 'step');
      else t.removeAttribute('aria-current');
    });
    glow(i < 0 ? 'n' : (GLOW[i] ?? 'n'));
    play();
  }

  tilt(q('.pin', stage), 7, tiltEl);
  function draw(p: number) {
    lastP = p;
    const y = p * RUN;
    const h = clamp(y / H);
    const x = clamp((y - H) / (steps.length * S)) * steps.length;
    // X is the eased step coordinate: flat while a step dwells, scrubbed across each boundary.
    const n = Math.round(x);
    let X: number;
    if (n < 1 || n > LAST) X = Math.min(LAST, Math.floor(x));
    else {
      const u = clamp((x - n) / (2 * Z) + 0.5);
      X = n - 1 + u * u * (3 - 2 * u);
    }
    const idx = h < 0.8 ? -1 : Math.min(LAST, Math.floor(x));
    if (idx !== cur) setStep(idx);

    const m = narrow.matches;
    const e = h * h * (3 - 2 * h);
    const k = 1 - e;
    const f = Math.floor(X);
    const t = X - f;
    const sw = Math.sin(Math.PI * t);
    const from = REST[f] ?? 0;
    const to = REST[Math.min(LAST, f + 1)] ?? from;
    pose.style.transform =
      `translate3d(calc(clamp(0px,22vw - 229px,var(--pw) * .24) * ${k.toFixed(4)}),calc(${m ? `${heroY.toFixed(1)}px` : '1.5svh'} * ${k.toFixed(4)} - ${(sw * 1.2).toFixed(2)}svh),0)` +
      ` rotateX(${((m ? 8 : 9) * k).toFixed(2)}deg)` +
      ` rotateY(${lerp(lerp(from, to, t) * (m ? 0.6 : 1), m ? -16 : -25, k).toFixed(2)}deg)` +
      ` rotateZ(${((m ? 2 : 3.5) * k).toFixed(2)}deg)` +
      ` scale(${(1 + (m ? 0.16 : 0.05) * k - sw * 0.045).toFixed(4)})`;

    if (h !== lastH) {
      hero.style.transform = `translate3d(0,${(-h * 62).toFixed(2)}vh,0)`;
      hero.style.opacity = clamp(1 - h * 1.8).toFixed(3);
      hero.classList.toggle('is-off', h > 0.6);
      copy.style.opacity = rail.style.opacity = scrim.style.opacity = span(h, 0.5, 1).toFixed(3);
      dev.style.setProperty('--h', h.toFixed(3));
      tiltEl.style.setProperty('--tk', lerp(1, 0.45, e).toFixed(2));
    }
    if (h !== lastH || X !== lastX) {
      wheel.style.transform = `translate3d(0,calc(var(--slot) * ${(-X).toFixed(4)} + ${(k * 56).toFixed(1)}px),0)`;
      steps.forEach((step, i) => step.style.setProperty('--d', Math.min(1, Math.abs(i - X)).toFixed(3)));
    }
    lastH = h;
    lastX = X;
  }
  // The hero copy wraps again when a webfont lands late, and on rotation. Measure whenever
  // one of its pieces changes size; redraw only if the answer moved.
  function redraw() {
    measure();
    lastH = lastX = -1;
    draw(lastP);
  }
  function remeasure() {
    const was = heroY;
    measure();
    if (heroY !== was) redraw();
  }
  measure();
  scrub(stage, draw);
  window.addEventListener('resize', redraw);
  window.addEventListener('load', remeasure);
  void document.fonts?.ready.then(remeasure);
  if ('ResizeObserver' in window) {
    const ro = new ResizeObserver(remeasure);
    [q('.d1', hero), q('.hero-p', hero), q('.bdg', hero), heroNote, dev].forEach((el) => ro.observe(el));
  }

  // Players loop only while the stage is on screen.
  visible(
    stage,
    () => {
      seen = true;
      if (cur > -2) play();
    },
    () => {
      seen = false;
      token++;
    },
    '0px',
  );
  rail.addEventListener('click', (e) => {
    const button = (e.target as Element).closest('button');
    if (!button) return;
    const r = stage.getBoundingClientRect();
    scrollToY(r.top + window.scrollY + (r.height - window.innerHeight) * ((H + S * (Number(button.getAttribute('data-i')) + 0.5)) / RUN));
  });
  // The later screens are lazy; fetch them once the hero has settled.
  setTimeout(() => screens.forEach((im) => (im.loading = 'eager')), 1400);
}
