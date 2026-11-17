// Behaviours of the sections below the stage. Each demo runs only while it is
// on screen; under reduced motion each one shows its finished state instead.
import { EXPO, all, animate, beats, clamp, esc, q, scrub, span, still, type, visible, wait } from '../motion';

const spring = (el: Element) => getComputedStyle(el).getPropertyValue('--spring').trim() || EXPO;

// ---- backends: a pulse runs down the SSH line to each backend in turn
function backends() {
  const net = q('.bk-net');
  const bus = q('.bk-bus', net);
  const runner = q('.bk-run', net);
  const tiles = all('.bk-t', net);
  const live = all('.bk-t:not(.is-soon)', net).length;
  const marquee = q('.mq');
  const narrow = matchMedia('(max-width: 899px)');
  let cur = -1;
  let hover = false;
  let token = 0;
  let shot = 0;
  // Distance along the SSH line from the phone mark to a tile's branch.
  const mid = (t: HTMLElement) => (narrow.matches ? t.offsetTop + t.offsetHeight / 2 - bus.offsetTop : t.offsetLeft + t.offsetWidth / 2 - bus.offsetLeft);
  function show(i: number, now?: boolean) {
    const tile = tiles[i];
    if (!tile) return;
    const vertical = narrow.matches;
    const d = Math.max(0, mid(tile) - 96);
    const ms = 380 + d * 0.55;
    const my = ++shot;
    const along = vertical ? 'translateY(' : 'translateX(';
    const across = vertical ? 'translateX(' : 'translateY(';
    const light = () => {
      if (my === shot) tiles.forEach((o) => o.classList.toggle('is-hi', o === tile));
    };
    cur = i;
    if (now || still) light();
    else void wait(ms * 0.8 + 220).then(light);
    animate(runner, [{ transform: `${along}0)`, opacity: 0 }, { opacity: 1, offset: 0.2 }, { opacity: 1, offset: 0.85 }, { transform: `${along}${d}px)`, opacity: 0 }], { duration: ms, easing: 'cubic-bezier(.5,0,.2,1)' });
    animate(q('.bk-dw b', tile), [{ transform: `${across}-101%)` }, { transform: `${across}101%)` }], { duration: 560, delay: ms * 0.78, easing: EXPO });
  }
  // The line is solid up to the last backend you can use today and dashed on to Rex.
  if ('ResizeObserver' in window) {
    new ResizeObserver(() => {
      const last = tiles[tiles.length - 1];
      const lastLive = tiles[live - 1];
      if (last) bus.style.setProperty('--len', `${mid(last)}px`);
      if (lastLive) bus.style.setProperty('--sol', `${mid(lastLive)}px`);
    }).observe(net);
  }
  tiles.forEach((tile, i) => {
    tile.addEventListener('pointerenter', () => {
      hover = true;
      if (i !== cur || !tile.classList.contains('is-hi')) show(i, true);
    });
    tile.addEventListener('pointerleave', () => (hover = false));
  });
  visible(
    net,
    () => {
      const my = ++token;
      if (still) return show(0, true);
      (function tick() {
        if (my !== token) return;
        if (!hover) show(cur + 1 < live ? cur + 1 : 0);
        void wait(3600).then(tick);
      })();
    },
    () => token++,
  );
  visible(marquee, () => marquee.classList.add('is-on'), () => marquee.classList.remove('is-on'), '0px');
}

// ---- voice: a sentence is dictated, then sent
function voice() {
  const el = q('.vo');
  const text = q('.vo-t span', el);
  const send = q('.vo-s', el);
  const SAY = 'Run the tests again, and if they pass, open the PR.';
  let token = 0;
  if (still) {
    text.textContent = SAY;
    return;
  }
  visible(
    el,
    () => {
      const my = ++token;
      const alive = () => my === token;
      beats(alive, [
        () => {
          text.textContent = '';
          el.classList.remove('is-sent');
          el.classList.add('is-live');
        },
        500,
        () => void type(text, SAY, 19, alive).then(() => alive() && el.classList.remove('is-live')),
        4700,
        () => {
          animate(send, [{ transform: 'scale(1)' }, { transform: 'scale(.84)', offset: 0.25 }, { transform: 'scale(1)' }], { duration: 560, easing: spring(el) });
          el.classList.add('is-sent');
        },
        1600,
      ]);
    },
    () => {
      token++;
      el.classList.remove('is-live');
    },
  );
}

// ---- reach: three routes race, and the first to show the trusted key wins
function reach() {
  const el = q('.re');
  const race = q('.race', el);
  const places = all('h3 span', el);
  const rows = all(':scope > li', race);
  let token = 0;
  function mark(place: number, winner: number) {
    places.forEach((p, i) => p.classList.toggle('is-c', i === place));
    rows.forEach((li, i) => li.classList.toggle('is-win', i === winner));
    race.classList.toggle('is-done', winner >= 0);
  }
  if (still) {
    mark(0, 0);
    const first = rows[0];
    if (first) q('b', first).style.transform = 'none';
    return;
  }
  visible(
    el,
    () => {
      const my = ++token;
      let r = 0;
      (function round() {
        if (my !== token) return;
        mark(r, -1);
        race.classList.remove('is-rs');
        const runs = rows.map((li, i) =>
          animate(q('b', li), [{ transform: 'translateX(-101%)' }, { transform: 'none' }], {
            duration: i === r ? 950 : 1900 + 450 * ((i + r) % 3),
            easing: 'cubic-bezier(.45,0,.2,1)',
            fill: 'forwards',
          }),
        );
        const clear = () => runs.forEach((run) => run?.cancel());
        runs[r]?.finished.then(
          () => {
            if (my !== token) return clear();
            runs.forEach((run, i) => i !== r && run?.pause());
            mark(r, r);
            return wait(2300)
              .then(() => {
                race.classList.add('is-rs');
                return wait(340);
              })
              .then(() => {
                clear();
                r = (r + 1) % rows.length;
                round();
              });
          },
          () => {},
        );
      })();
    },
    () => token++,
  );
}

// ---- private: the direct line pulses, and the statements wipe in line by line with the scroll
function priv() {
  const fig = q('.pv-d');
  visible(fig, () => fig.classList.add('is-run'), () => fig.classList.remove('is-run'), '0px');
  const list = q('.pv-l');
  const entries = all(':scope > li', list);
  let lines: HTMLElement[] = [];
  let tops: number[] = [];
  let height = 0;
  let width = 0;
  let last = 0;
  function paint(p: number) {
    last = p;
    // Each line wipes in as it climbs from 96% to 76% of the viewport height.
    const vh = window.innerHeight;
    const y = p * (vh + height) - vh * 0.04;
    lines.forEach((line, i) => line.style.setProperty('--r', clamp((y - (tops[i] ?? 0)) / (vh * 0.2)).toFixed(3)));
  }
  // Split each statement into the lines it wraps to, so every visual line can wipe on its own.
  function split() {
    if (list.offsetWidth === width) return;
    width = list.offsetWidth;
    for (const li of entries) {
      const text = li.getAttribute('data-t') ?? li.textContent ?? '';
      const rows: string[][] = [];
      let top: number | null = null;
      li.setAttribute('data-t', text);
      li.innerHTML = text
        .split(' ')
        .map((word) => `<span>${esc(word)}</span>`)
        .join(' ');
      for (const word of all('span', li)) {
        if (word.offsetTop !== top) {
          top = word.offsetTop;
          rows.push([]);
        }
        rows[rows.length - 1]?.push(word.textContent ?? '');
      }
      li.innerHTML = rows
        .map((row) => {
          const t = esc(row.join(' '));
          return `<span class="ln" data-t="${t}">${t}</span>`;
        })
        .join(' ');
    }
    lines = all('.ln', list);
    tops = lines.map((line) => line.offsetTop - list.offsetTop);
    height = list.offsetHeight;
    paint(last);
  }
  scrub(
    list,
    (p) => {
      if (!lines.length) split();
      paint(p);
    },
    'view',
  );
  if ('ResizeObserver' in window) new ResizeObserver(split).observe(list);
  // Webfonts change the breaks; a late font must split again.
  document.fonts?.addEventListener('loadingdone', () => {
    width = 0;
    split();
  });
}

// ---- also in the box: each card's drawing replays on hover, and once in turn when the grid scrolls in
function box() {
  const grid = q('.bx-g');
  const cards = all(':scope > li', grid);
  let token = 0;
  if (still) return;
  function play(card: HTMLElement) {
    card.classList.remove('is-p');
    void card.offsetWidth;
    card.classList.add('is-p');
  }
  cards.forEach((card) => card.addEventListener('pointerenter', () => play(card)));
  visible(
    grid,
    () => {
      const my = ++token;
      let i = 0;
      cards.forEach((card, k) => void wait(250 + k * 140).then(() => my === token && play(card)));
      // No hover on touch: keep one drawing moving at a time.
      if (matchMedia('(hover: hover)').matches) return;
      void wait(4600).then(function tick() {
        if (my !== token) return;
        const card = cards[i++ % cards.length];
        if (card) play(card);
        void wait(2800).then(tick);
      });
    },
    () => token++,
  );
}

// ---- setup: two ways to add the machine, and copy
function setup() {
  const root = q('.su');
  const tablist = q('.su-sw', root);
  const tabs = all<HTMLButtonElement>('button', tablist);
  const panes = all('.su-p', root);
  const cell = q('.su-ps', root);
  const picked = () => Number(tablist.getAttribute('data-i'));
  // The panes share one grid cell. The cell follows the open pane's height, so a short pane leaves no blank under it.
  const fit = () => (cell.style.height = `${panes[picked()]?.offsetHeight ?? 0}px`);
  const observed = 'ResizeObserver' in window;
  if (observed) {
    if (!still) cell.style.transition = `height .6s ${EXPO}`;
    const ro = new ResizeObserver(fit);
    panes.forEach((pane) => ro.observe(pane));
  }
  function pick(i: number, focus?: boolean) {
    tablist.setAttribute('data-i', String(i));
    tabs.forEach((tab, k) => {
      tab.setAttribute('aria-selected', String(k === i));
      tab.tabIndex = k === i ? 0 : -1;
    });
    panes.forEach((pane, k) => pane.classList.toggle('is-on', k === i));
    if (observed) fit();
    if (focus) tabs[i]?.focus();
  }
  tabs.forEach((tab, i) => tab.addEventListener('click', () => pick(i)));
  tablist.addEventListener('keydown', (e) => {
    const d = e.key === 'ArrowRight' ? 1 : e.key === 'ArrowLeft' ? -1 : 0;
    if (!d) return;
    e.preventDefault();
    pick((picked() + d + tabs.length) % tabs.length, true);
  });

  const button = q<HTMLButtonElement>('.cp', root);
  const sweep = q('.code-sw', root);
  let timer = 0;
  button.addEventListener('click', () => {
    // Each line starts with a "$ " prompt that is not part of the command.
    const text = all('.code pre span', root)
      .map((line) => (line.textContent ?? '').slice(2))
      .join('\n');
    function done() {
      button.classList.add('is-ok');
      button.setAttribute('aria-label', 'Copied');
      animate(sweep, [{ transform: 'translateX(-100%)' }, { transform: 'translateX(100%)' }], { duration: 950, easing: EXPO });
      clearTimeout(timer);
      timer = window.setTimeout(() => {
        button.classList.remove('is-ok');
        button.setAttribute('aria-label', 'Copy both commands');
      }, 1800);
    }
    function legacy() {
      const area = document.createElement('textarea');
      area.value = text;
      area.setAttribute('readonly', '');
      area.style.cssText = 'position:fixed;top:0;opacity:0';
      document.body.appendChild(area);
      area.select();
      try {
        document.execCommand('copy');
      } catch {
        // Nothing else to try.
      }
      area.remove();
      done();
    }
    if (navigator.clipboard?.writeText) navigator.clipboard.writeText(text).then(done, legacy);
    else legacy();
  });
}

// ---- faq: one answer open at a time, sliding open and shut
function faq() {
  const items = all<HTMLDetailsElement>('.fq-i');
  function set(item: HTMLDetailsElement, on: boolean) {
    if (on) {
      item.open = true;
      void item.offsetHeight;
      item.classList.add('is-open');
      return;
    }
    item.classList.remove('is-open');
    // With nothing to wait for, the answer leaves the page at once.
    if (still) item.open = false;
  }
  for (const item of items) {
    // The answer stays in the page until it has slid shut. Its children's
    // transitions bubble through here too, so only its own counts.
    const answer = q('.fq-a', item);
    answer.addEventListener('transitionend', (e) => {
      if (e.target === answer && !item.classList.contains('is-open')) item.open = false;
    });
    q('.fq-q', item).addEventListener('click', (e) => {
      e.preventDefault();
      const open = !item.classList.contains('is-open');
      items.forEach((other) => set(other, other === item && open));
    });
    // Find in page opens an answer without a click.
    item.addEventListener('toggle', () => {
      if (item.open) item.classList.add('is-open');
    });
  }
}

// ---- closing: iPad and iPhone rise at different rates
function closing() {
  const scene = q('.cl-s');
  const pad = q('.cl-pad', scene);
  const phone = q('.cl-ph', scene);
  scrub(
    scene,
    (p) => {
      const e = 1 - span(p, 0, 0.42);
      pad.style.transform = `translate3d(0,${(e * 16).toFixed(2)}%,0)`;
      phone.style.transform = `translate3d(0,${(e * 38).toFixed(2)}%,0) rotate(${(e * 6).toFixed(2)}deg)`;
    },
    'view',
  );
}

export function wireSections() {
  backends();
  voice();
  reach();
  priv();
  box();
  setup();
  faq();
  closing();
}
