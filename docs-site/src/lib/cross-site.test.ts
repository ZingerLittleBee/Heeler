// Unit tests for the heeler.si in-page origin swap. Run with `pnpm test`.

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { describe, it } from 'node:test';
import { runInNewContext } from 'node:vm';
import { docsOrigin, landingOrigin, rewriteCrossSiteAnchors, rewriteCrossSiteHref } from './cross-site.ts';

describe('rewriteCrossSiteHref', () => {
  it('rewrites docs.heeler.bybee.dev onto docs.heeler.si, keeping path, query, and hash', () => {
    assert.equal(rewriteCrossSiteHref(docsOrigin, 'heeler.si'), 'https://docs.heeler.si');
    assert.equal(rewriteCrossSiteHref(`${docsOrigin}/`, 'heeler.si'), 'https://docs.heeler.si/');
    assert.equal(rewriteCrossSiteHref(`${docsOrigin}/chat`, 'heeler.si'), 'https://docs.heeler.si/chat');
    assert.equal(
      rewriteCrossSiteHref(`${docsOrigin}/pairing#after-pairing`, 'heeler.si'),
      'https://docs.heeler.si/pairing#after-pairing',
    );
    assert.equal(
      rewriteCrossSiteHref(`${docsOrigin}/usage?from=home#add-a-widget`, 'heeler.si'),
      'https://docs.heeler.si/usage?from=home#add-a-widget',
    );
    assert.equal(rewriteCrossSiteHref(`${docsOrigin}?from=home#top`, 'heeler.si'), 'https://docs.heeler.si?from=home#top');
    assert.equal(rewriteCrossSiteHref(`${docsOrigin}#top`, 'heeler.si'), 'https://docs.heeler.si#top');
  });

  it('rewrites heeler.bybee.dev onto heeler.si, keeping path, query, and hash', () => {
    assert.equal(rewriteCrossSiteHref(landingOrigin, 'docs.heeler.si'), 'https://heeler.si');
    assert.equal(rewriteCrossSiteHref(`${landingOrigin}/`, 'docs.heeler.si'), 'https://heeler.si/');
    assert.equal(rewriteCrossSiteHref(`${landingOrigin}/ipad`, 'docs.heeler.si'), 'https://heeler.si/ipad');
    assert.equal(rewriteCrossSiteHref(`${landingOrigin}/#faq`, 'docs.heeler.si'), 'https://heeler.si/#faq');
    assert.equal(rewriteCrossSiteHref(`${landingOrigin}/?ref=docs`, 'docs.heeler.si'), 'https://heeler.si/?ref=docs');
  });

  it('leaves hrefs unchanged on the canonical hosts and on other hostnames', () => {
    for (const hostname of ['heeler.bybee.dev', 'docs.heeler.bybee.dev', 'localhost', 'docs.heeler.si', 'evilheeler.si', 'heeler.si.evil.com']) {
      assert.equal(rewriteCrossSiteHref(`${docsOrigin}/chat`, hostname), `${docsOrigin}/chat`, hostname);
    }
    for (const hostname of ['heeler.bybee.dev', 'docs.heeler.bybee.dev', 'localhost', 'heeler.si', 'evildocs.heeler.si', 'docs.heeler.si.evil.com']) {
      assert.equal(rewriteCrossSiteHref(`${landingOrigin}/`, hostname), `${landingOrigin}/`, hostname);
    }
  });

  it('leaves other origins, relative URLs, and look-alike hosts alone', () => {
    for (const href of [
      'https://github.com/ZingerLittleBee/Heeler',
      'https://herdr.dev',
      'https://apps.apple.com/app/id6797263135',
      '/chat',
      '#faq',
      `${docsOrigin}.evil.example/chat`,
      `${landingOrigin}.evil.example/`,
      `${docsOrigin}@evil.example/chat`,
      `${landingOrigin}@evil.example/`,
      `${docsOrigin}:8443/chat`,
      `${landingOrigin}:8443/`,
    ]) {
      assert.equal(rewriteCrossSiteHref(href, 'heeler.si'), href, href);
      assert.equal(rewriteCrossSiteHref(href, 'docs.heeler.si'), href, href);
    }
  });
});

describe('rewriteCrossSiteAnchors', () => {
  it('rewrites matching anchors and leaves <link> and other hosts alone', () => {
    const document = fakeDocument([
      ['a', `${landingOrigin}/`],
      ['a', `${landingOrigin}/ipad#gallery`],
      ['a', 'https://herdr.dev'],
      ['link', `${landingOrigin}/sitemap-index.xml`],
    ]);
    rewriteCrossSiteAnchors('docs.heeler.si', document);
    assert.deepEqual(
      document.nodes.map((node) => [node.tagName, node.getAttribute('href')]),
      [
        ['a', 'https://heeler.si/'],
        ['a', 'https://heeler.si/ipad#gallery'],
        ['a', 'https://herdr.dev'],
        ['link', `${landingOrigin}/sitemap-index.xml`],
      ],
    );

    const landing = fakeDocument([
      ['a', `${docsOrigin}/chat`],
      ['link', `${docsOrigin}/sitemap-index.xml`],
    ]);
    rewriteCrossSiteAnchors('heeler.si', landing);
    rewriteCrossSiteAnchors('heeler.si', landing); // Repeated page-load events are harmless.
    assert.equal(landing.nodes[0]?.getAttribute('href'), 'https://docs.heeler.si/chat');
    assert.equal(landing.nodes[1]?.getAttribute('href'), `${docsOrigin}/sitemap-index.xml`);

    const canonical = fakeDocument([['a', `${landingOrigin}/`]]);
    rewriteCrossSiteAnchors('docs.heeler.bybee.dev', canonical);
    assert.equal(canonical.nodes[0]?.getAttribute('href'), `${landingOrigin}/`);
  });
});


describe('landing inline origin swap', () => {
  const layout = readFileSync(new URL('../../../landing/src/layouts/Layout.astro', import.meta.url), 'utf8');
  const script = /<script is:inline>([\s\S]*?)<\/script>/.exec(layout)?.[1];
  assert.ok(script, 'landing layout contains its inline cross-site script');

  it('executes the shipped script, preserving suffixes and only changing sibling anchors', () => {
    const document = fakeDocument([
      ['a', `${docsOrigin}/usage?from=home#add-a-widget`],
      ['a', `${docsOrigin}?from=home#top`],
      ['a', `${docsOrigin}#top`],
      ['a', `${docsOrigin}.evil.example/chat`],
      ['a', `${docsOrigin}@evil.example/chat`],
      ['a', '/ipad'],
      ['link', `${docsOrigin}/sitemap-index.xml`],
    ]);
    runInNewContext(script, { location: { hostname: 'heeler.si' }, document });
    runInNewContext(script, { location: { hostname: 'heeler.si' }, document });
    assert.deepEqual(document.nodes.map((node) => node.href), [
      'https://docs.heeler.si/usage?from=home#add-a-widget',
      'https://docs.heeler.si?from=home#top',
      'https://docs.heeler.si#top',
      `${docsOrigin}.evil.example/chat`,
      `${docsOrigin}@evil.example/chat`,
      '/ipad',
      `${docsOrigin}/sitemap-index.xml`,
    ]);
  });

  it('does not rewrite on old or look-alike page hosts', () => {
    for (const hostname of ['heeler.bybee.dev', 'docs.heeler.si', 'localhost', 'evilheeler.si', 'heeler.si.evil.com']) {
      const document = fakeDocument([['a', `${docsOrigin}/chat`]]);
      runInNewContext(script, { location: { hostname }, document });
      assert.equal(document.nodes[0]?.href, `${docsOrigin}/chat`, hostname);
    }
  });
});

/** A document stand-in with `a`/`link` elements that expose href attributes. */
function fakeDocument(entries: readonly [tag: string, href: string][]): { nodes: FakeElement[]; querySelectorAll: (selector: string) => FakeElement[] } {
  const nodes = entries.map(([tagName, href]) => new FakeElement(tagName, href));
  return {
    nodes,
    querySelectorAll(selector: string) {
      const match = /^([a-z]+)\[href\^="([^"]+)"\]$/i.exec(selector);
      if (match === null) return [];
      const [, tag, prefix] = match;
      return nodes.filter((node) => node.tagName === tag && (node.getAttribute('href') ?? '').startsWith(prefix ?? ''));
    },
  };
}

class FakeElement {
  tagName: string;
  href: string;

  constructor(tagName: string, href: string) {
    this.tagName = tagName;
    this.href = href;
  }

  getAttribute(name: string): string | null {
    return name === 'href' ? this.href : null;
  }

  setAttribute(name: string, value: string): void {
    if (name === 'href') this.href = value;
  }
}
