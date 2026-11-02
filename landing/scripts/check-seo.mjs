// Verify the public HTML/XML contract, not the layout's implementation.
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';

const dist = new URL('../dist/', import.meta.url);
const read = (path) => readFileSync(new URL(path, dist), 'utf8');
const origin = 'https://heeler.bybee.dev';
for (const [file, route] of [['index.html', '/'], ['ipad.html', '/ipad'], ['404.html', '/404']]) {
  const html = read(file);
  assert.match(html, /name="apple-itunes-app" content="app-id=6797263135"/);
  assert.equal([...html.matchAll(/<h1\b/g)].length, 1, file);
  const canonicals = [...html.matchAll(/<link rel="canonical" href="([^"]+)"/g)].map((match) => match[1]);
  assert.deepEqual(canonicals, route === '/404' ? [] : [`${origin}${route}`], file);
  if (route === '/404') assert.match(html, /name="robots" content="noindex"/);
  else {
    assert.doesNotMatch(html, /content="noindex"/);
    assert.ok(html.includes(`property="og:url" content="${origin}${route}"`), file);
  }
  for (const [, src] of html.matchAll(/(?:href|src)="(\/[^"#]*)(?:#[^"]*)?"/g)) {
    if (src === '/') continue;
    assert.ok(existsSync(new URL(src.slice(1), dist)) || existsSync(new URL(`${src.slice(1)}.html`, dist)), `${file}: ${src}`);
  }
}
const home = read('index.html');
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
for (const icon of JSON.parse(read('site.webmanifest')).icons) {
  assert.ok(existsSync(new URL(icon.src.slice(1), dist)), icon.src);
}
console.log('check-seo: 3 pages, 2 canonical sitemap URLs, app metadata, FAQ, and linked assets passed.');
