// Behaviour for the article markup that src/lib/markdown.ts generates (and the
// MDX <Heading> buttons). Page content is a static slot inside a persisted
// React island and is never hydrated, so everything here is a delegated
// listener on `document`: it keeps working when navigation swaps the article,
// and it never depends on astro:page-load. The one element it adds, a live
// region for copy announcements, sits on <body> outside the article and is
// re-created when missing. Load this module on every docs page; loading it
// twice is harmless.

export {};

declare global {
  interface Window {
    /** Set once the listeners below are registered. */
    __heelerContent?: boolean;
  }
}

/** How long a copy button shows its check mark, as in Fumadocs UI. */
const checkedDuration = 1500;
const svgNamespace = 'http://www.w3.org/2000/svg';
/** Lucide CopyCheck, for MDX heading buttons, which render a single icon. */
const copyCheckShapes =
  '<path d="m12 15 2 2 4-4"></path><rect width="14" height="14" x="8" y="8" rx="2" ry="2"></rect><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"></path>';
/** Lucide X, for the lightbox close button. */
const closeIcon = `<svg xmlns="${svgNamespace}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M18 6 6 18"></path><path d="m6 6 12 12"></path></svg>`;

const copyCodeSelector = '[data-copy-code]';
/** Guide heading buttons (data-copy-anchor) and MDX <Heading> buttons alike. */
const copyAnchorSelector = '.prose :is(h1, h2, h3, h4, h5, h6)[id] > button';
const screenshotSelector = '.prose a[href^="/images/"]';
const statusSelector = '[data-copy-status]';

function isZhPage(): boolean {
  return document.documentElement.lang.startsWith('zh');
}

const resetTimers = new WeakMap<HTMLElement, number>();
/** An MDX heading button's own icon and label while it shows the check mark. */
const mdxOriginals = new WeakMap<HTMLElement, { icon?: string; label?: string | null }>();

/**
 * A visually hidden live region, outside the article, that announces copies
 * from buttons with no text of their own to change (guide heading buttons).
 * A navigation that swaps <body> drops it, so it is created again on demand.
 */
function copyStatus(): HTMLElement {
  const existing = document.querySelector<HTMLElement>(statusSelector);
  if (existing) return existing;
  const status = document.createElement('div');
  status.dataset.copyStatus = '';
  status.setAttribute('role', 'status');
  status.className = 'sr-only';
  document.body.append(status);
  return status;
}

/** Writes to the clipboard; false when the browser refuses or has no clipboard. */
async function writeClipboard(value: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(value);
    return true;
  } catch {
    return false;
  }
}

/**
 * Sets data-checked on a copy button and runs `reset` after a moment. A second
 * click before then restarts the timer rather than stacking another one.
 */
function showChecked(button: HTMLElement, reset: () => void): void {
  const pending = resetTimers.get(button);
  if (pending !== undefined) window.clearTimeout(pending);
  button.dataset.checked = '';
  resetTimers.set(
    button,
    window.setTimeout(() => {
      resetTimers.delete(button);
      delete button.dataset.checked;
      reset();
    }, checkedDuration),
  );
}

async function copyCode(button: HTMLElement): Promise<void> {
  const code = button.closest('figure')?.querySelector('pre')?.textContent;
  if (code == null || !(await writeClipboard(code.replace(/\n$/, '')))) return;
  const zh = isZhPage();
  const label = button.querySelector('.sr-only');
  if (label) label.textContent = zh ? '已复制代码' : 'Copied code';
  showChecked(button, () => {
    if (label) label.textContent = zh ? '复制代码' : 'Copy code';
  });
}

/** Copies the page URL with the heading's fragment, as <Heading> does. */
async function copyAnchor(button: HTMLElement): Promise<void> {
  const id = button.parentElement?.id;
  if (!id) return;
  const url = new URL(window.location.href);
  url.hash = id;
  // Guide headings announce through the status region. It has to exist before
  // its text changes, and it is emptied first so that copying again is
  // announced again.
  const status = button.hasAttribute('data-copy-anchor') ? copyStatus() : undefined;
  if (status) status.textContent = '';
  if (!(await writeClipboard(url.href))) return;

  const zh = isZhPage();
  if (status) {
    // CSS swaps the icons on data-checked.
    const copiedAnchor = zh ? '已复制锚点链接' : 'Copied anchor link';
    const copyAnchorLabel = zh ? '复制锚点链接' : 'Copy anchor link';
    button.setAttribute('aria-label', copiedAnchor);
    status.textContent = copiedAnchor;
    showChecked(button, () => {
      button.setAttribute('aria-label', copyAnchorLabel);
      if (status.textContent === copiedAnchor) status.textContent = '';
    });
    return;
  }
  // MDX headings render one icon and a visually hidden label: swap both.
  const icon = button.querySelector('svg');
  const label = button.querySelector('.sr-only');
  if (!mdxOriginals.has(button)) mdxOriginals.set(button, { icon: icon?.innerHTML, label: label?.textContent });
  if (icon) icon.innerHTML = copyCheckShapes;
  if (label) label.textContent = zh ? '已复制锚点链接' : 'Copied Anchor Link';
  showChecked(button, () => {
    const original = mdxOriginals.get(button);
    mdxOriginals.delete(button);
    if (icon && original?.icon !== undefined) icon.innerHTML = original.icon;
    if (label && original?.label != null) label.textContent = original.label;
  });
}

/**
 * Shows a screenshot full size in a modal <dialog>, created on demand, instead
 * of leaving the page for the bare image. Any click or Escape closes it, and
 * focus returns to the link.
 */
function openLightbox(link: HTMLAnchorElement, image: HTMLImageElement): void {
  const dialog = document.createElement('dialog');
  dialog.dataset.lightbox = '';
  const name = image.alt.trim();
  if (name !== '') dialog.setAttribute('aria-label', name);

  const close = document.createElement('button');
  close.type = 'button';
  close.dataset.lightboxClose = '';
  close.setAttribute('aria-label', isZhPage() ? '关闭' : 'Close');
  close.innerHTML = closeIcon;

  const full = document.createElement('img');
  full.src = link.href;
  full.alt = image.alt;
  full.decoding = 'async';

  dialog.append(close, full);
  dialog.addEventListener('click', () => dialog.close());
  dialog.addEventListener('close', () => {
    dialog.remove();
    if (link.isConnected) link.focus({ preventScroll: true });
  });
  document.body.append(dialog);
  dialog.showModal();
}

function onClick(event: MouseEvent): void {
  const target = event.target;
  if (!(target instanceof Element)) return;

  const codeButton = target.closest<HTMLElement>(copyCodeSelector);
  if (codeButton) {
    void copyCode(codeButton);
    return;
  }
  const anchorButton = target.closest<HTMLElement>(copyAnchorSelector);
  if (anchorButton) {
    void copyAnchor(anchorButton);
    return;
  }

  // Modified and non-primary clicks keep the browser's own behaviour (new tab,
  // download), as do clicks something else already handled.
  if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) {
    return;
  }
  const link = target.closest<HTMLAnchorElement>(screenshotSelector);
  const image = link?.querySelector('img');
  if (!link || !image) return;
  // Runs in the capture phase, so Astro's router sees defaultPrevented and
  // does not navigate to the image.
  event.preventDefault();
  openLightbox(link, image);
}

if (!window.__heelerContent) {
  window.__heelerContent = true;
  document.addEventListener('click', onClick, { capture: true });
  // Have the status region in place well before the first copy, also after
  // Astro's client-side navigation swaps in a new <body>.
  copyStatus();
  document.addEventListener('astro:after-swap', () => void copyStatus());
}
