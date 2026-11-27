// Verify the public HTML/XML contract, not the layout's implementation.
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';

const dist = new URL('../dist/', import.meta.url);
const read = (path) => readFileSync(new URL(path, dist), 'utf8');
const origin = 'https://heeler.bybee.dev';
const docsOrigin = 'https://docs.heeler.bybee.dev';
const appStoreUrl = 'https://apps.apple.com/us/app/id6797263135';
const stripTags = (html) => html.replace(/<[^>]+>/g, '').replace(/\s+/g, ' ').trim();
const decodeEntities = (text) =>
  text
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'");
const getAttr = (attrs, name) => {
  const match = attrs.match(new RegExp(`(?:^|\\s)${name}="([^"]*)"`, 'i'));
  return match ? decodeEntities(match[1]) : undefined;
};
const hasAnchorWithHref = (html, url) =>
  [...html.matchAll(/<a\b([^>]*)>/gi)].some(([, attrs = '']) => getAttr(attrs, 'href') === url);

for (const [file, route] of [['index.html', '/'], ['ipad.html', '/ipad'], ['404.html', '/404']]) {
  const html = read(file);
  assert.match(html, /name="apple-itunes-app" content="app-id=6797263135"/);
  assert.ok(html.includes(`property="og:image" content="${origin}/social-card.jpg"`), file);
  assert.match(html, /property="og:image:width" content="1200"/);
  assert.match(html, /property="og:image:height" content="630"/);
  assert.match(html, /name="twitter:card" content="summary_large_image"/);
  assert.ok(html.includes(`name="twitter:image" content="${origin}/social-card.jpg"`), file);
  assert.equal([...html.matchAll(/<h1\b/g)].length, 1, file);
  const canonicals = [...html.matchAll(/<link rel="canonical" href="([^"]+)"/g)].map((match) => match[1]);
  assert.deepEqual(canonicals, route === '/404' ? [] : [`${origin}${route}`], file);
  if (route === '/404') assert.match(html, /name="robots" content="noindex"/);
  else {
    assert.doesNotMatch(html, /content="noindex"/);
    assert.ok(html.includes(`property="og:url" content="${origin}${route}"`), file);
  }
  for (const [, src] of html.matchAll(/(?<=\s)(?:href|src)="(\/[^"#]*)(?:#[^"]*)?"/g)) {
    if (src === '/') continue;
    assert.ok(existsSync(new URL(src.slice(1), dist)) || existsSync(new URL(`${src.slice(1)}.html`, dist)), `${file}: ${src}`);
  }
  // Heading hierarchy must never skip levels (e.g. h1 -> h3 without an intervening h2).
  let prevHeading = 0;
  for (const [, levelStr] of html.matchAll(/<h([1-6])\b/g)) {
    const level = Number(levelStr);
    if (prevHeading > 0) {
      assert.ok(level <= prevHeading + 1, `${file}: skipped heading level h${prevHeading} -> h${level}`);
    }
    prevHeading = level;
  }
}

const checkMetaLength = (label, value, max) => {
  assert.ok(value.trim().length > 0, `${label} must be non-empty`);
  if (value.length > max) {
    console.warn(`check-seo warning: ${label} exceeds ${max} chars (${value.length}): ${value}`);
  }
};

const home = read('index.html');
const homeTitle = decodeEntities(home.match(/<title>([^<]+)<\/title>/)[1]);
const homeDescription = decodeEntities(home.match(/<meta name="description" content="([^"]+)"/)[1]);
checkMetaLength('homepage <title>', homeTitle, 60);
checkMetaLength('homepage description', homeDescription, 155);
assert.ok(homeDescription.includes('tmux, and Rex.'), 'homepage description must include Rex');
assert.doesNotMatch(homeDescription, /\bRex\s*\(/i, 'homepage description must not qualify Rex in parentheses');
assert.ok(homeDescription.includes('herdr-core'), 'homepage description must mention herdr-core');

// H1 spacing: words across stacked spans must keep a space when extracted as text.
const homeH1Raw = home.match(/<h1\b[^>]*>(.*?)<\/h1>/s)[1];
assert.equal(stripTags(homeH1Raw), 'Leave the desk. Keep your agents.');

// Hero note & Rex consistency + no overclaiming relay copy.
const heroNote = stripTags(home.match(/<p class="hero-n"[^>]*>(.*?)<\/p>/s)[1]);
assert.equal(heroNote, 'Works with Herdr TUI, Herdr desktop (herdr-core), tmux, and Rex.', `unexpected hero-n: ${heroNote}`);
assert.doesNotMatch(heroNote, /\bRex\s*\(/i, `hero-n must not qualify Rex in parentheses: ${heroNote}`);
assert.ok(!home.includes('The relay only ever sees ciphertext.'), 'stale overclaiming relay note');
assert.ok(!home.includes('The relay sees ciphertext.'), 'stale overclaiming privacy copy');
assert.ok(!home.includes('as ciphertext it cannot read.'), 'stale overclaiming FAQ copy');
assert.ok(!home.includes('only Live Activity'), 'stale overclaiming FAQ relay copy');

// Reach section heading hierarchy: an h2 must precede the two h3 cards ("Say it." and "Home Wi-Fi").
const reachStart = home.indexOf('</section>', home.indexOf('id="backends"'));
const privateStart = home.indexOf('id="private"');
assert.ok(reachStart > 0 && privateStart > reachStart, 'could not locate Reach section');
const reachHeadings = [...home.slice(reachStart, privateStart).matchAll(/<h([1-6])\b/g)].map((m) => Number(m[1]));
assert.deepEqual(reachHeadings, [2, 3, 3], `Reach heading sequence must be [2, 3, 3], got ${JSON.stringify(reachHeadings)}`);

// Decorative floating cards (.ts and .fg) must be aria-hidden="true", and hidden step nav buttons unfocusable.
const decorativeDivs = [...home.matchAll(/<div\b([^>]*\bclass="[^"]*\b(?:ts|fg)\b[^"]*"[^>]*)>/g)];
assert.ok(decorativeDivs.length >= 10, `expected >= 10 decorative .ts/.fg divs, found ${decorativeDivs.length}`);
for (const [tag, attrs] of decorativeDivs) {
  assert.match(attrs, /\baria-hidden="true"/, `decorative card missing aria-hidden="true": ${tag}`);
}
const railBlock = home.match(/<div\b[^>]*class="[^"]*\brl\b[^"]*"[^>]*>(.*?)<\/div>/s);
assert.ok(railBlock, 'missing .rl step nav');
assert.match(railBlock[0], /\baria-hidden="true"/, '.rl must start aria-hidden="true" while invisible');
for (const [btn] of railBlock[1].matchAll(/<button\b[^>]*>/g)) {
  assert.match(btn, /\btabindex="-1"/, `hidden step nav button must start with tabindex="-1": ${btn}`);
}

// Homepage internal /ipad link outside FAQ and docs guide links.
const boxSlice = home.slice(home.indexOf('Also in the box.'), home.indexOf('id="faq"'));
assert.ok(hasAnchorWithHref(boxSlice, '/ipad'), 'Box section must link visibly to /ipad');
for (const slug of ['pairing', 'herdr-core', 'tmux', 'rex', 'windows-setup', 'overlay-networks']) {
  assert.ok(hasAnchorWithHref(home, `${docsOrigin}/${slug}`), `homepage missing guide link ${docsOrigin}/${slug}`);
}

// /ipad page checks: metadata, CTA, back link, guides, Rex, and all 7 screenshots.
const ipad = read('ipad.html');
const ipadTitle = decodeEntities(ipad.match(/<title>([^<]+)<\/title>/)[1]);
const ipadDescription = decodeEntities(ipad.match(/<meta name="description" content="([^"]+)"/)[1]);
checkMetaLength('/ipad <title>', ipadTitle, 60);
checkMetaLength('/ipad description', ipadDescription, 155);
const backLink = ipad.match(/<a\b([^>]*\sclass="[^"]*\bback-link\b[^"]*"[^>]*)>/);
assert.ok(backLink, '/ipad missing .back-link');
assert.equal(getAttr(backLink[1], 'href'), '/', `/ipad back link must point to /: ${backLink[0]}`);
const ipadMain = ipad.match(/<main\b[^>]*>(.*?)<\/main>/s);
assert.ok(ipadMain, '/ipad missing <main>');
const ipadCtaBlock = ipadMain[1].match(/<div\b[^>]*class="[^"]*\bipad-actions\b[^"]*"[^>]*>(.*?)<\/div>/s);
assert.ok(ipadCtaBlock, '/ipad missing .ipad-actions body CTA block inside <main>');
const ipadCtaLink = ipadCtaBlock[1].match(/<a\b([^>]*\sclass="[^"]*\bstore-link\b[^"]*"[^>]*)>(.*?)<\/a>/s);
assert.ok(ipadCtaLink, '/ipad .ipad-actions missing .store-link CTA');
assert.equal(getAttr(ipadCtaLink[1], 'href'), appStoreUrl, `/ipad body CTA must link to ${appStoreUrl}`);
assert.match(ipadCtaLink[2], /<img\b[^>]*alt="Download on the App Store"/, '/ipad body CTA must render the App Store badge');
assert.ok(ipad.includes('and Rex on macOS, Linux, and Windows.'), '/ipad must mention Rex');
assert.doesNotMatch(ipad, /\bRex\s*\(/i, '/ipad must not qualify Rex in parentheses');
assert.equal([...ipad.matchAll(/<figure\b/g)].length, 7, '/ipad must keep all 7 screenshots');
for (const slug of ['pairing', 'herdr-core', 'tmux', 'windows-setup', 'rex']) {
  assert.ok(hasAnchorWithHref(ipad, `${docsOrigin}/${slug}`), `/ipad missing guide link ${docsOrigin}/${slug}`);
}

const graph = JSON.parse(home.match(/<script[^>]*type="application\/ld\+json"[^>]*>(.*?)<\/script>/s)[1])['@graph'];
const application = graph.find((entry) => entry['@type'] === 'MobileApplication');
assert.equal(application.operatingSystem, 'iOS, iPadOS');
assert.match(application.downloadUrl, /\/id6797263135$/);
const faq = graph.find((entry) => entry['@type'] === 'FAQPage');
assert.equal(faq.mainEntity.length, [...home.matchAll(/<details\b/g)].length);
for (const question of faq.mainEntity) {
  assert.ok(home.includes(question.name));
  assert.ok(home.includes(question.acceptedAnswer.text));
}
const sitemap = read('sitemap-0.xml');
assert.deepEqual([...sitemap.matchAll(/<loc>(.*?)<\/loc>/g)].map((match) => match[1]).sort(), [`${origin}/`, `${origin}/ipad`]);
assert.ok(read('sitemap-index.xml').includes(`${origin}/sitemap-0.xml`));
assert.ok(read('robots.txt').includes(`Sitemap: ${origin}/sitemap-index.xml`));
assert.ok(existsSync(new URL('social-card.jpg', dist)));
assert.deepEqual(new Set(read('_redirects').trim().split('\n')), new Set([
  '/index / 301', '/index.html / 301',
  '/ipad.html /ipad 301', '/ipad/ /ipad 301',
  '/ipad/index /ipad 301', '/ipad/index.html /ipad 301',
]));
for (const icon of JSON.parse(read('site.webmanifest')).icons) {
  assert.ok(existsSync(new URL(icon.src.slice(1), dist)), icon.src);
}
console.log('check-seo: 3 pages, 2 canonical sitemap URLs, permanent redirects, social cards, app metadata, headings, a11y, guides, /ipad CTA, FAQ, and linked assets passed.');
