// Motion helpers for the site scripts: one frame loop for scroll-linked and
// smoothed values, reveal on scroll, pointer tilt, and a few timing utilities.

/** Reduced motion: everything lands in its finished state with nothing in flight. */
export const still = matchMedia('(prefers-reduced-motion: reduce)').matches;

export const EXPO = 'cubic-bezier(.16,1,.3,1)';

/** The first match under `root`. The markup is static, so a miss is a bug. */
export function q<T extends Element = HTMLElement>(sel: string, root: ParentNode = document): T {
  const el = root.querySelector<T>(sel);
  if (!el) throw new Error(`Missing element: ${sel}`);
  return el;
}
export function all<T extends Element = HTMLElement>(sel: string, root: ParentNode = document): T[] {
  return [...root.querySelectorAll<T>(sel)];
}

export const clamp = (v: number) => (v < 0 ? 0 : v > 1 ? 1 : v);
export const lerp = (a: number, b: number, t: number) => a + (b - a) * t;
/** Map p from [a, b] to 0..1, clamped. */
export const span = (p: number, a: number, b: number) => clamp((p - a) / (b - a));
export const wait = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

// ---------------------------------------------------------------- frame loop
// One rAF loop serves every scrub and smoothed value; it sleeps when settled.
interface Item {
  fn: (value: number) => void;
  cur: number | null;
  k: number;
  target: (vh: number) => number;
}
const items: Item[] = [];
let raf = 0;

function frame() {
  raf = 0;
  let busy = false;
  const vh = window.innerHeight;
  for (const it of items) {
    const t = it.target(vh);
    if (it.cur === null || Math.abs(t - it.cur) < 0.0004) {
      if (it.cur === t) continue;
      it.cur = t;
    } else {
      it.cur += (t - it.cur) * (still ? 1 : it.k);
      busy = true;
    }
    it.fn(it.cur);
  }
  if (busy) kick();
}
export function kick() {
  if (!raf) raf = requestAnimationFrame(frame);
}
window.addEventListener('scroll', kick, { passive: true });
window.addEventListener('resize', kick);

/**
 * Scroll progress of `el`, smoothed: `fn(p)` with p in 0..1.
 *
 * - `pin` (default) is for a tall section with a sticky child: 0 when the
 *   section's top reaches the viewport top, 1 when its bottom reaches the
 *   viewport bottom.
 * - `view` runs from the element's top entering at the viewport bottom to its
 *   bottom leaving at the top.
 */
export function scrub(el: Element, fn: (p: number) => void, mode: 'pin' | 'view' = 'pin') {
  items.push({
    fn,
    cur: null,
    k: 0.16,
    target(vh) {
      const r = el.getBoundingClientRect();
      if (mode === 'view') return clamp((vh - r.top) / (vh + r.height));
      const run = r.height - vh;
      return run <= 0 ? (r.top <= 0 ? 1 : 0) : clamp(-r.top / run);
    },
  });
  kick();
}

/** A smoothed value driven by `set`. */
export function smooth(fn: (value: number) => void, k = 0.12) {
  let goal = 0;
  items.push({ fn, cur: 0, k, target: () => goal });
  return {
    set(x: number) {
      goal = x;
      kick();
    },
  };
}

// ---------------------------------------------------------------- reveal and visibility
/** Add `.is-in` to each `[data-rv]` element as it scrolls into view. */
export function reveal(root: ParentNode = document) {
  const els = all('[data-rv]:not(.is-in)', root);
  for (const el of els) {
    const delay = el.getAttribute('data-rv-delay');
    if (delay) el.style.setProperty('--rv-delay', `${delay}ms`);
  }
  if (still || !('IntersectionObserver' in window)) {
    for (const el of els) el.classList.add('is-in');
    return;
  }
  const io = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        entry.target.classList.add('is-in');
        io.unobserve(entry.target);
      }
    },
    { rootMargin: '0px 0px -12% 0px', threshold: 0.01 },
  );
  for (const el of els) io.observe(el);
}

/** Run a demo only while it is on screen: the callbacks fire on each crossing. */
export function visible(el: Element, onEnter: () => void, onLeave?: () => void, margin = '-15% 0px -15% 0px') {
  if (!('IntersectionObserver' in window)) {
    onEnter();
    return;
  }
  new IntersectionObserver(
    (entries) => {
      for (const entry of entries) (entry.isIntersecting ? onEnter : onLeave)?.();
    },
    { rootMargin: margin },
  ).observe(el);
}

// ---------------------------------------------------------------- pointer
/** Smoothed pointer position over `el`: `fn(x, y)` with both in -1..1, back to 0 on leave. */
function pointer(el: HTMLElement, fn: (x: number, y: number) => void, k = 0.1) {
  if (still || !matchMedia('(hover: hover)').matches) return;
  let x = 0;
  let y = 0;
  const sx = smooth((v) => fn((x = v), y), k);
  const sy = smooth((v) => fn(x, (y = v)), k);
  el.addEventListener('pointermove', (e) => {
    const r = el.getBoundingClientRect();
    sx.set(((e.clientX - r.left) / r.width) * 2 - 1);
    sy.set(((e.clientY - r.top) / r.height) * 2 - 1);
  });
  el.addEventListener('pointerleave', () => {
    sx.set(0);
    sy.set(0);
  });
}
/** 3D tilt toward the pointer: sets --rx and --ry (deg) on `target`. */
export function tilt(el: HTMLElement, max: number, target: HTMLElement) {
  pointer(el, (x, y) => {
    target.style.setProperty('--ry', `${(x * max).toFixed(2)}deg`);
    target.style.setProperty('--rx', `${(-y * max).toFixed(2)}deg`);
  });
}
/** Magnetic pull: sets --mx and --my (px) on `el`. */
export function magnet(el: HTMLElement, pull: number) {
  pointer(
    el,
    (x, y) => {
      el.style.setProperty('--mx', `${(x * pull).toFixed(1)}px`);
      el.style.setProperty('--my', `${(y * pull).toFixed(1)}px`);
    },
    0.18,
  );
}

// ---------------------------------------------------------------- small helpers
/** Type `text` into `el`. Resolves when done, or early once `alive()` turns false. */
export function type(el: Element, text: string, cps: number, alive: () => boolean) {
  return new Promise<void>((resolve) => {
    if (still) {
      el.textContent = text;
      resolve();
      return;
    }
    let i = 0;
    (function step() {
      if (!alive()) return resolve();
      el.textContent = text.slice(0, ++i);
      if (i >= text.length) resolve();
      else setTimeout(step, 1000 / cps + (/[,.?!]/.test(text[i - 1] ?? '') ? 120 : 0));
    })();
  });
}

/** Count `el`'s text up to `to` over `ms`. */
export function count(el: Element, to: number, ms: number, fmt: (v: number) => string) {
  if (still) {
    el.textContent = fmt(to);
    return;
  }
  const t0 = performance.now();
  (function step(now: number) {
    const t = Math.min(1, (now - t0) / ms);
    el.textContent = fmt(to * (1 - Math.pow(1 - t, 4)));
    if (t < 1) requestAnimationFrame(step);
  })(t0);
}

/** Web Animations with the page's `linear()` springs, falling back where a browser rejects them. */
export function animate(el: Element, frames: Keyframe[], opts: KeyframeAnimationOptions): Animation | null {
  if (still) return null;
  try {
    return el.animate(frames, opts);
  } catch {
    return el.animate(frames, { ...opts, easing: EXPO });
  }
}

/** A beat list on a loop: numbers wait in real time, functions fire. Ends once `alive()` turns false. */
export function beats(alive: () => boolean, list: (number | (() => void))[]) {
  let i = 0;
  (function next() {
    if (!alive()) return;
    const beat = list[i++ % list.length];
    if (typeof beat === 'number') void wait(beat).then(next);
    else {
      beat?.();
      next();
    }
  })();
}

/** Smooth in-page scrolling to a document offset. */
export function scrollToY(y: number) {
  window.scrollTo({ top: Math.max(0, y), behavior: still ? 'auto' : 'smooth' });
}

export const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;');
