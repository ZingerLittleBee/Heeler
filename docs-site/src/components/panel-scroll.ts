import { useEffect, useLayoutEffect, useRef } from 'react';

type NavigationType = 'push' | 'replace' | 'traverse';

/** Keys in `history.state`: the entry's id, and its panel position for reloads. */
const idKey = 'panelEntry';
const positionKey = 'panelScrollTop';

/**
 * Latest panel position of every history entry this document has shown, by
 * entry id. Updated on each scroll event, so it is exact even when the reader
 * goes Back mid-scroll; `history.state` keeps a debounced copy for reloads,
 * because browsers limit how often `replaceState` may run.
 */
const positions = new Map<string, number>();

/**
 * Spacious' page scroll container (the parent of its `<article id="nd-page">`),
 * or null when there is none or it does not scroll (below `md` the window
 * scrolls, and Astro's own handling applies).
 */
function panelScroller(): HTMLElement | null {
  const scroller = document.getElementById('nd-page')?.parentElement ?? null;
  if (!scroller || getComputedStyle(scroller).overflowY === 'visible') return null;
  return scroller;
}

function stateField(state: unknown, key: string): unknown {
  return typeof state === 'object' && state !== null ? Reflect.get(state, key) : undefined;
}

/**
 * The current history entry's id, assigned on first use. Undefined for an
 * entry with a null state: the browser's own #fragment navigation (typed in
 * the address bar, say) creates those, and Astro leaves them alone, treating
 * any state on them as one of its own entries.
 */
function currentEntryId(): string | undefined {
  if (history.state === null) return undefined;
  const id = stateField(history.state, idKey);
  if (typeof id === 'string') return id;
  const fresh = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
  history.replaceState({ ...history.state, [idKey]: fresh }, '');
  return fresh;
}

/** Copies an entry's remembered position into its `history.state`, if it is still the current entry. */
function persistPosition(id: string): void {
  const top = positions.get(id);
  if (top === undefined || stateField(history.state, idKey) !== id) return;
  try {
    history.replaceState({ ...history.state, [positionKey]: top }, '');
  } catch {
    // Safari throws once replaceState runs too often. The copy only serves
    // reloads; positions still has the exact value.
  }
}

/** Scrolls to the URL's fragment target; false when there is none. */
function scrollToFragment(): boolean {
  let id = location.hash.slice(1);
  try {
    id = decodeURIComponent(id);
  } catch {
    // A malformed escape: look the fragment up as written.
  }
  const target = id === '' ? null : document.getElementById(id);
  target?.scrollIntoView();
  return target !== null;
}

/** Puts the panel where `state`'s entry left it, else at the URL's fragment, else at the top. */
function restorePanelScroll(scroller: HTMLElement, state: unknown): void {
  const id = stateField(state, idKey);
  const saved = (typeof id === 'string' ? positions.get(id) : undefined) ?? stateField(state, positionKey);
  if (typeof saved === 'number') scroller.scrollTop = saved;
  else if (!scrollToFragment()) scroller.scrollTop = 0;
}

/**
 * Where a scroll key moves the panel from `from`, or undefined for other keys.
 * Used only while nothing has focus: the browser then scrolls the window,
 * which does not scroll on desktop, instead of the panel.
 */
function keyScrollTop(event: KeyboardEvent, scroller: HTMLElement, from: number): number | undefined {
  if (event.altKey || event.ctrlKey) return undefined;
  const page = scroller.clientHeight * 0.875;
  const line = 40;
  const bottom = scroller.scrollHeight - scroller.clientHeight;
  if (event.metaKey) {
    // macOS: Command-Up and Command-Down go to the top and bottom.
    if (event.key === 'ArrowUp') return 0;
    if (event.key === 'ArrowDown') return bottom;
    return undefined;
  }
  switch (event.key) {
    case 'PageDown':
      return from + page;
    case 'PageUp':
      return from - page;
    case ' ':
      return from + (event.shiftKey ? -page : page);
    case 'ArrowDown':
      return from + line;
    case 'ArrowUp':
      return from - line;
    case 'Home':
      return 0;
    case 'End':
      return bottom;
    default:
      return undefined;
  }
}

/**
 * On desktop, Spacious scrolls the page inside its panel (the window does not
 * scroll) and remounts the panel for every pathname. Astro's ClientRouter only
 * manages window scrolling, so after a client-side navigation the new panel
 * always starts at the top: `#fragment` targets and Back/Forward positions are
 * lost. This redoes that bookkeeping for the panel:
 *
 * - every history entry remembers its panel position;
 * - after a page renders, Back/Forward (or a reload) restores the remembered
 *   position, and a push or replace to a URL with a fragment scrolls to it;
 * - Back/Forward between entries of the same page (no re-render), such as
 *   before and after a table-of-contents click, restores the position too;
 * - scroll keys pressed while nothing has focus scroll the panel.
 *
 * Below `md` the window scrolls again and Astro's own handling applies; the
 * panel is then not a scroll container, so this hook does nothing there.
 */
export function usePanelScroll(pathname: string): void {
  /** The navigation that is producing the next page; undefined on a full load. */
  const navigation = useRef<NavigationType | undefined>(undefined);
  const renderedPathname = useRef(pathname);
  /** Id of the history entry whose page the panel shows. */
  const shownEntry = useRef<string | undefined>(undefined);

  useEffect(() => {
    let timer: number | undefined;
    /**
     * Where the smooth scroll that the last scroll key started is heading, so
     * that keys pressed before it ends add up, as the browser's own do.
     */
    let keyTarget: number | undefined;
    let lastTop = 0;
    const onScroll = (event: Event) => {
      const scroller = event.target;
      if (!(scroller instanceof HTMLElement) || scroller !== panelScroller()) return;
      if (keyTarget !== undefined) {
        // Arrived, or another input took over and moves the panel away.
        const distance = Math.abs(keyTarget - scroller.scrollTop);
        if (distance < 1 || distance > Math.abs(keyTarget - lastTop)) keyTarget = undefined;
      }
      lastTop = scroller.scrollTop;
      // On the rendered page the panel shows the current entry, which a
      // same-page #fragment navigation may just have created. Once another
      // page's URL is current (a navigation in flight), it still shows the
      // entry it was rendered for.
      if (location.pathname === renderedPathname.current) shownEntry.current = currentEntryId();
      const id = shownEntry.current;
      if (id === undefined) return;
      positions.set(id, scroller.scrollTop);
      window.clearTimeout(timer);
      timer = window.setTimeout(() => persistPosition(id), 150);
    };
    const onBeforePreparation = (event: DocumentEventMap['astro:before-preparation']) => {
      // Push and replace still have the old entry current: persist its
      // position now. A traverse has already moved to the target entry.
      window.clearTimeout(timer);
      if (event.navigationType !== 'traverse' && shownEntry.current !== undefined) persistPosition(shownEntry.current);
      navigation.current = event.navigationType;
    };
    const onPopState = (event: PopStateEvent) => {
      // Astro ignores null states (and dispatches one itself after a same-page
      // #fragment push); cross-page traversals re-render and are restored by
      // the layout effect below.
      if (event.state === null || location.pathname !== renderedPathname.current) return;
      const scroller = panelScroller();
      if (!scroller) return;
      restorePanelScroll(scroller, event.state);
      shownEntry.current = currentEntryId();
    };
    const onAfterSwap = () => {
      // Astro swaps in a fresh copy of the same page for some same-page
      // navigations, such as the page's own sidebar link while at a #fragment,
      // and Back or Forward between those two entries. Nothing re-renders, so
      // the layout effect below does not run, and the swap leaves the panel at
      // the top. A navigation to another pathname is left to the layout effect
      // (it has either run already and cleared `navigation`, or runs next).
      const type = navigation.current;
      if (type === undefined || location.pathname !== renderedPathname.current) return;
      navigation.current = undefined;
      shownEntry.current = currentEntryId();
      const scroller = panelScroller();
      if (!scroller) return;
      if (type === 'traverse') restorePanelScroll(scroller, history.state);
      else if (!scrollToFragment()) scroller.scrollTop = 0;
    };
    const onKeyDown = (event: KeyboardEvent) => {
      const focused = document.activeElement;
      if (event.defaultPrevented || (focused !== null && focused !== document.body)) return;
      const scroller = panelScroller();
      if (!scroller) return;
      const target = keyScrollTop(event, scroller, keyTarget ?? scroller.scrollTop);
      if (target === undefined) return;
      event.preventDefault();
      const top = Math.min(Math.max(target, 0), scroller.scrollHeight - scroller.clientHeight);
      const instant = event.repeat || matchMedia('(prefers-reduced-motion: reduce)').matches;
      keyTarget = instant ? undefined : top;
      lastTop = scroller.scrollTop;
      scroller.scrollTo({ top, behavior: instant ? 'instant' : 'smooth' });
    };
    document.addEventListener('scroll', onScroll, { capture: true, passive: true });
    document.addEventListener('astro:before-preparation', onBeforePreparation);
    window.addEventListener('popstate', onPopState);
    document.addEventListener('astro:after-swap', onAfterSwap);
    document.addEventListener('keydown', onKeyDown);
    return () => {
      window.clearTimeout(timer);
      document.removeEventListener('scroll', onScroll, { capture: true });
      document.removeEventListener('astro:before-preparation', onBeforePreparation);
      window.removeEventListener('popstate', onPopState);
      document.removeEventListener('astro:after-swap', onAfterSwap);
      document.removeEventListener('keydown', onKeyDown);
    };
  }, []);

  useLayoutEffect(() => {
    const type = navigation.current;
    navigation.current = undefined;
    renderedPathname.current = pathname;
    shownEntry.current = currentEntryId();
    const scroller = panelScroller();
    if (!scroller) return;
    if (type === 'push' || type === 'replace') scrollToFragment();
    // Back/Forward, or a reload or cross-document visit of an entry.
    else restorePanelScroll(scroller, history.state);
  }, [pathname]);
}
