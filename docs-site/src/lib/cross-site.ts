// When the sites are served on heeler.si, rewrite in-page anchors that still
// point at the canonical bybee.dev origins. Canonical, sitemap, and robots stay
// on those origins; only `<a href>` changes, and only in the browser.

/** Canonical landing origin (`site` in landing/astro.config.mjs). */
export const landingOrigin = 'https://heeler.bybee.dev';

/** Canonical docs origin (`site` in docs-site/astro.config.mjs). */
export const docsOrigin = 'https://docs.heeler.bybee.dev';

const landingSiOrigin = 'https://heeler.si';
const docsSiOrigin = 'https://docs.heeler.si';

function swapFor(hostname: string): { from: string; to: string } | undefined {
  if (hostname === 'heeler.si') return { from: docsOrigin, to: docsSiOrigin };
  if (hostname === 'docs.heeler.si') return { from: landingOrigin, to: landingSiOrigin };
  return undefined;
}

/**
 * Rewrite a sibling-site href when this page is served on a heeler.si host.
 * Path, query, and hash are kept. Other hostnames and hrefs are unchanged.
 */
export function rewriteCrossSiteHref(href: string, hostname: string): string {
  const swap = swapFor(hostname);
  if (swap === undefined) return href;
  if (href === swap.from || href.startsWith(`${swap.from}/`) || href.startsWith(`${swap.from}?`) || href.startsWith(`${swap.from}#`)) {
    return swap.to + href.slice(swap.from.length);
  }
  return href;
}

/** An element that can read and write its `href` attribute. */
interface HrefNode {
  getAttribute(name: string): string | null;
  setAttribute(name: string, value: string): void;
}

/** A tree that can select anchors; `Document` satisfies this. */
interface HrefRoot {
  querySelectorAll(selector: string): Iterable<HrefNode>;
}

/**
 * Rewrites matching `a[href]` attributes on `root` for the given hostname.
 * Only anchors; never `<link>`.
 */
export function rewriteCrossSiteAnchors(hostname: string, root: HrefRoot): void {
  const swap = swapFor(hostname);
  if (swap === undefined) return;
  for (const anchor of root.querySelectorAll(`a[href^="${swap.from}"]`)) {
    const href = anchor.getAttribute('href');
    if (href === null) continue;
    const next = rewriteCrossSiteHref(href, hostname);
    if (next !== href) anchor.setAttribute('href', next);
  }
}
