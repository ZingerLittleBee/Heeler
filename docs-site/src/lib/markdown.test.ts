// Unit tests for the guide pipeline helpers. Run with `pnpm test` (Node's
// built-in runner; Node strips the TypeScript types).

import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import type { Element, ElementContent, Root as HastRoot, RootContent } from 'hast';
import type { Code, Paragraph, PhrasingContent, Root as MdastRoot } from 'mdast';
import { htmlLang, localeFromPath, localePath, sidebarTitle } from './guides.ts';
import {
  codeBlockTitle,
  codeMeta,
  dropLeadIn,
  extractTitle,
  groupSteps,
  hiddenForSearch,
  htmlNodes,
  isShortcut,
  leadHtml,
  menuPathItems,
  parseAlertMarker,
  parseRunOn,
  parseStepHeading,
  phrasingHtml,
  rehypeFumadocsElements,
  rehypeGithubAlerts,
  rehypeGuideComponents,
  rehypeGuideImages,
  remarkGuideCode,
  resolveGuideHref,
  rewriteHtmlLinks,
  summarize,
  tableKind,
  trailerKind,
} from './markdown.ts';

const repo = 'https://github.com/ZingerLittleBee/Heeler';
const source = 'docs/guides/tailscale.md';
const zhSource = 'docs/guides/zh/tailscale.md';
const directories = new Set(['docs/adr', 'Sources/Heeler']);
const resolve = (href: string) => resolveGuideHref(href, source, (path) => directories.has(path));
const resolveZh = (href: string) => resolveGuideHref(href, zhSource, (path) => directories.has(path));

describe('locale helpers', () => {
  it('derives the active locale from the URL pathname', () => {
    assert.equal(localeFromPath('/'), 'en');
    assert.equal(localeFromPath('/tailscale'), 'en');
    assert.equal(localeFromPath('/zh'), 'zh');
    assert.equal(localeFromPath('/zh/'), 'zh');
    assert.equal(localeFromPath('/zh/tailscale'), 'zh');
    assert.equal(localeFromPath('/zh-extra'), 'en');
  });

  it('switches a pathname between English and Chinese without keeping fragments', () => {
    assert.equal(localePath('/', 'zh'), '/zh');
    assert.equal(localePath('/tailscale', 'zh'), '/zh/tailscale');
    assert.equal(localePath('/zh', 'en'), '/');
    assert.equal(localePath('/zh/', 'en'), '/');
    assert.equal(localePath('/zh/tailscale', 'en'), '/tailscale');
    assert.equal(localePath('/zh/tailscale.html', 'en'), '/tailscale');
  });

  it('returns the BCP 47 language tag and localized sidebar title', () => {
    assert.equal(htmlLang('en'), 'en');
    assert.equal(htmlLang('zh'), 'zh-CN');
    assert.equal(sidebarTitle('overlay-networks', 'en'), 'Overview');
    assert.equal(sidebarTitle('overlay-networks', 'zh'), '概览');
    assert.equal(sidebarTitle('tailscale', 'zh'), 'Tailscale');
  });
});

describe('resolveGuideHref', () => {
  it('routes published guides to flat site URLs and keeps the fragment', () => {
    assert.equal(resolve('overlay-networks.md#prepare-the-host'), '/overlay-networks#prepare-the-host');
    assert.equal(resolve('tailscale.md#troubleshooting'), '/tailscale#troubleshooting');
    assert.equal(resolve('./zerotier.md'), '/zerotier');
  });

  it('routes Chinese guides under docs/guides/zh/ to /zh/<slug> and keeps shared ../images/ on /images/', () => {
    assert.equal(resolveZh('overlay-networks.md#准备-host'), '/zh/overlay-networks#准备-host');
    assert.equal(resolveZh('./zerotier.md'), '/zh/zerotier');
    assert.equal(resolveZh('../images/overlay-networks/tailscale-form.png'), '/images/overlay-networks/tailscale-form.png');
    assert.equal(
      resolveZh('../native-windows-testing.md#4-test-device-key-authentication'),
      `${repo}/blob/main/docs/guides/native-windows-testing.md#4-test-device-key-authentication`,
    );
  });

  it('sends unpublished files to GitHub on main, keeping line anchors', () => {
    assert.equal(
      resolve('native-windows-testing.md#4-test-device-key-authentication'),
      `${repo}/blob/main/docs/guides/native-windows-testing.md#4-test-device-key-authentication`,
    );
    assert.equal(resolve('../agents/overlay-network-guides.md'), `${repo}/blob/main/docs/agents/overlay-network-guides.md`);
    assert.equal(resolve('../../README.md#adding-a-machine'), `${repo}/blob/main/README.md#adding-a-machine`);
    assert.equal(resolve('../../Sources/Heeler/App.swift#L12'), `${repo}/blob/main/Sources/Heeler/App.swift#L12`);
    assert.equal(resolve('/CHANGELOG.md'), `${repo}/blob/main/CHANGELOG.md`);
  });

  it('uses /tree/ for directories', () => {
    assert.equal(resolve('../adr'), `${repo}/tree/main/docs/adr`);
    assert.equal(resolve('../research/'), `${repo}/tree/main/docs/research`);
    assert.equal(resolve('../../'), repo);
  });

  it('serves guide images from /images/', () => {
    assert.equal(resolve('images/overlay-networks/tailscale-form.png'), '/images/overlay-networks/tailscale-form.png');
  });

  it('keeps percent-escapes canonical instead of encoding them twice', () => {
    assert.equal(resolve('../../a%23b.md'), `${repo}/blob/main/a%23b.md`);
    assert.equal(resolve('../../a%2Fb.md'), `${repo}/blob/main/a%2Fb.md`);
    assert.equal(resolve('../../My%20File.md'), `${repo}/blob/main/My%20File.md`);
    assert.equal(resolve('../../my file.md'), `${repo}/blob/main/my%20file.md`);
    assert.equal(resolve('../../100%.md'), undefined);
  });

  it('drops a query on site routes and keeps it on GitHub', () => {
    assert.equal(resolve('zerotier.md?plain=1#x'), '/zerotier#x');
    assert.equal(resolve('releasing.md?plain=1#L3'), `${repo}/blob/main/docs/guides/releasing.md?plain=1#L3`);
  });

  it('leaves absolute URLs, mail links, anchors, and paths outside the repo alone', () => {
    for (const href of ['https://herdr.dev', 'mailto:someone@example.com', '#troubleshooting', '//cdn.example', '../../../x.md']) {
      assert.equal(resolve(href), undefined, href);
    }
  });
});

describe('rewriteHtmlLinks', () => {
  it('rewrites href and src in raw HTML', () => {
    const html = '<a href="images/a.png"><img src="images/a.png" width="300" alt="A"></a>';
    assert.equal(
      rewriteHtmlLinks(html, resolve),
      '<a href="/images/a.png"><img src="/images/a.png" width="300" alt="A"></a>',
    );
  });

  it('handles srcset and spaced attributes but not data-* look-alikes', () => {
    assert.equal(
      rewriteHtmlLinks('<img data-src="images/a.png" srcset="images/a.png 2x, images/b.png 3x"><a href = "zerotier.md">', resolve),
      '<img data-src="images/a.png" srcset="/images/a.png 2x, /images/b.png 3x"><a href="/zerotier">',
    );
  });
});

describe('rehypeGuideImages', () => {
  it('sizes raw and Markdown screenshots without changing authored attributes or external images', () => {
    const raw = { type: 'raw' as const, value: '<a href="/images/phone.png"><img src="/images/phone.png" width="300" alt="Host > Routes"></a><img src="https://example.com/photo.png">' };
    const markdown: Element = { type: 'element', tagName: 'img', properties: { src: '/images/wide.png', height: 120, loading: 'eager' }, children: [] };
    const tree: HastRoot = { type: 'root', children: [raw, markdown] };
    rehypeGuideImages({ '/images/phone.png': { width: 1200, height: 2600 }, '/images/wide.png': { width: 900, height: 600 } })(tree);
    assert.equal(raw.value, '<a href="/images/phone.png"><img src="/images/phone.png" width="300" alt="Host > Routes" height="650" loading="lazy" decoding="async"></a><img src="https://example.com/photo.png">');
    assert.deepEqual(markdown.properties, { src: '/images/wide.png', width: 180, height: 120, loading: 'eager', decoding: 'async' });
  });
});

describe('extractTitle', () => {
  it('removes the H1 and returns it with the next paragraph as plain text', () => {
    const tree: MdastRoot = {
      type: 'root',
      children: [
        { type: 'heading', depth: 1, children: [{ type: 'text', value: 'Connect Heeler' }] },
        {
          type: 'paragraph',
          children: [
            { type: 'text', value: 'Use ' },
            { type: 'strong', children: [{ type: 'text', value: 'Settings' }] },
            { type: 'text', value: ' and\n' },
            { type: 'link', url: 'tailscale.md', children: [{ type: 'inlineCode', value: 'tailscale' }] },
            { type: 'text', value: '.' },
          ],
        },
        { type: 'heading', depth: 2, children: [{ type: 'text', value: 'Steps' }] },
      ],
    };
    assert.deepEqual(extractTitle(tree), { title: 'Connect Heeler', description: 'Use Settings and tailscale.' });
    assert.deepEqual(
      tree.children.map((node) => node.type),
      ['paragraph', 'heading'],
    );
  });

  it('skips paragraphs without prose and a trailing lead-in sentence', () => {
    const tree: MdastRoot = {
      type: 'root',
      children: [
        { type: 'heading', depth: 1, children: [{ type: 'text', value: 'T' }] },
        { type: 'paragraph', children: [{ type: 'image', url: 'x.png', alt: 'only image' }] },
        { type: 'paragraph', children: [{ type: 'text', value: 'Use a VPS. The result is:' }] },
      ],
    };
    assert.deepEqual(extractTitle(tree), { title: 'T', description: 'Use a VPS.' });
  });

  it('returns nothing without an H1', () => {
    assert.deepEqual(extractTitle({ type: 'root', children: [] }), {});
  });
});

describe('dropLeadIn', () => {
  it('drops a final sentence that ends in a colon', () => {
    assert.equal(dropLeadIn('Follow this guide.\nThe result is:'), 'Follow this guide.');
    assert.equal(dropLeadIn('Run this:'), 'Run this:');
    assert.equal(dropLeadIn('Plain text.'), 'Plain text.');
  });
});

describe('htmlNodes', () => {
  it('finds raw HTML at any depth', () => {
    const tree: MdastRoot = {
      type: 'root',
      children: [
        { type: 'html', value: '<details>' },
        { type: 'paragraph', children: [{ type: 'text', value: 'Keep' }, { type: 'html', value: '<br>' }] },
      ],
    };
    assert.deepEqual(
      htmlNodes(tree).map((node) => node.value),
      ['<details>', '<br>'],
    );
  });
});

describe('rehypeFumadocsElements', () => {
  it('wraps tables and anchors headings in Markdown files only', () => {
    const build = (): HastRoot => ({
      type: 'root',
      children: [
        { type: 'element', tagName: 'h2', properties: { id: 'steps' }, children: [{ type: 'text', value: 'Steps' }] },
        { type: 'element', tagName: 'table', properties: {}, children: [] },
      ],
    });

    const markdown = build();
    rehypeFumadocsElements()(markdown, { path: '/repo/docs/guides/tailscale.md' });
    const [heading, wrapper] = markdown.children;
    assert.ok(heading?.type === 'element' && wrapper?.type === 'element');
    assert.ok((heading.properties.className as string[]).includes('scroll-m-28'));
    assert.deepEqual(heading.children[0], {
      type: 'element',
      tagName: 'a',
      properties: { href: '#steps', dataCard: '' },
      children: [{ type: 'text', value: 'Steps' }],
    });
    assert.equal(wrapper.tagName, 'div');
    assert.equal((wrapper.children[0] as Element).tagName, 'table');

    const mdx = build();
    rehypeFumadocsElements()(mdx, { path: '/repo/docs-site/content/index.mdx' });
    assert.deepEqual(mdx, build());
  });
});

describe('summarize', () => {
  it('keeps short text and trims long text on a word boundary', () => {
    assert.equal(summarize('  short\n text '), 'short text');
    const long = 'word '.repeat(60);
    const result = summarize(long);
    assert.ok(result.length <= 160, `${result.length}`);
    assert.ok(result.endsWith('word…'));
  });
});

describe('GitHub alerts', () => {
  it('parses the alert marker', () => {
    assert.deepEqual(parseAlertMarker('[!IMPORTANT]\nAllow only tcp:22.'), { kind: 'IMPORTANT', rest: 'Allow only tcp:22.' });
    assert.deepEqual(parseAlertMarker('[!note]'), { kind: 'NOTE', rest: '' });
    assert.equal(parseAlertMarker('[!INFO]\nText'), undefined);
    assert.equal(parseAlertMarker('Plain quote'), undefined);
  });

  it('turns an alert blockquote into a callout and leaves other quotes alone', () => {
    const quote = (text: string): Element => ({
      type: 'element',
      tagName: 'blockquote',
      properties: {},
      children: [{ type: 'element', tagName: 'p', properties: {}, children: [{ type: 'text', value: text }] }],
    });
    const tree: HastRoot = { type: 'root', children: [quote('[!WARNING]\nBack up first.'), quote('Just a quote.')] };
    rehypeGithubAlerts()(tree);

    const [callout, plain] = tree.children;
    assert.ok(callout?.type === 'element' && plain?.type === 'element');
    assert.equal(callout.tagName, 'div');
    assert.equal(callout.properties.role, 'note');
    assert.match(String(callout.properties.style), /--color-fd-warning/);
    assert.match(JSON.stringify(callout), /"value":"Warning"/);
    assert.match(JSON.stringify(callout), /"value":"Back up first\."/);
    assert.doesNotMatch(JSON.stringify(callout), /\[!WARNING\]/);
    assert.equal(plain.tagName, 'blockquote');
  });
});

// ---------------------------------------------------------------------------
// Fixtures for the guide components

type Child = ElementContent | string;

/** A hast element; strings become text nodes. */
function h(tagName: string, properties: Element['properties'] = {}, ...children: Child[]): Element {
  return {
    type: 'element',
    tagName,
    properties,
    children: children.map((child): ElementContent => (typeof child === 'string' ? { type: 'text', value: child } : child)),
  };
}

/** Raw HTML as remark-rehype passes it to rehype plugins. */
function raw(value: string): ElementContent {
  return { type: 'raw', value };
}

/** Inline content; strings become text nodes. */
function inline(...children: Child[]): ElementContent[] {
  return h('span', {}, ...children).children;
}

/** A root whose blocks are separated by line breaks, as remark-rehype emits them. */
function root(...blocks: RootContent[]): HastRoot {
  return {
    type: 'root',
    children: blocks.flatMap((block, index): RootContent[] => (index === 0 ? [block] : [{ type: 'text', value: '\n' }, block])),
  };
}

interface TestFile {
  path: string;
  data: { astro?: { frontmatter?: Record<string, unknown> } };
}

const guideFile = (): TestFile => ({ path: '/repo/docs/guides/example.md', data: {} });
const mdxFile = (): TestFile => ({ path: '/repo/docs-site/content/index.mdx', data: {} });

/** Runs rehypeGuideComponents on a guide and returns its frontmatter. */
function runGuide(tree: HastRoot): Record<string, unknown> {
  const file = guideFile();
  rehypeGuideComponents()(tree, file);
  return file.data.astro?.frontmatter ?? {};
}

function isElement(node: RootContent | undefined): node is Element {
  return node?.type === 'element';
}

function classesOf(node: Element): string[] {
  const value = node.properties.className;
  return Array.isArray(value) ? value.map(String) : [];
}

/** Text content, as the table of contents and the search index read it. */
function textOf(node: RootContent | HastRoot): string {
  if (node.type === 'text') return node.value;
  return 'children' in node ? node.children.map(textOf).join('') : '';
}

/** Elements below `node` (itself included) that pass `test`, in document order. */
function findAll(node: RootContent | HastRoot, test: (element: Element) => boolean): Element[] {
  const found: Element[] = [];
  const visit = (current: RootContent | HastRoot) => {
    if (current.type === 'element' && test(current)) found.push(current);
    if ('children' in current) current.children.forEach(visit);
  };
  visit(node);
  return found;
}

const byTag =
  (tagName: string) =>
  (node: Element): boolean =>
    node.tagName === tagName;
const isNote = (node: Element): boolean => node.properties.role === 'note';

/**
 * Block outline of a tree: tag names with `#id`, and the children of step
 * containers in brackets. Text and line breaks are left out.
 */
function outline(nodes: readonly RootContent[]): string[] {
  return nodes.flatMap((node) => {
    if (node.type !== 'element') return [];
    const id = typeof node.properties.id === 'string' ? `#${node.properties.id}` : '';
    const steps = classesOf(node).filter((name) => name === 'fd-steps' || name === 'fd-step');
    const label = `${node.tagName}${id}${steps.map((name) => `.${name}`).join('')}`;
    return steps.length > 0 ? [`${label}[${outline(node.children).join(' ')}]`] : [label];
  });
}

// ---------------------------------------------------------------------------
// Steps

describe('parseStepHeading', () => {
  it('reads "1. ", "Step 1: ", and "Phase 1: " prefixes', () => {
    assert.deepEqual(parseStepHeading('1. Install Tailscale'), { number: 1, prefix: '1. ' });
    assert.deepEqual(parseStepHeading('12. Test the tunnel'), { number: 12, prefix: '12. ' });
    assert.deepEqual(parseStepHeading('Step 3: Copy the Heeler Device Key'), { number: 3, prefix: 'Step 3: ' });
    assert.deepEqual(parseStepHeading('Phase 2: Move the tunnel'), { number: 2, prefix: 'Phase 2: ' });
  });

  it('ignores other headings', () => {
    for (const text of ['Install Tailscale', '1.Install', '1. ', '2026 plans', 'Step two: Copy', 'Phases 1: x']) {
      assert.equal(parseStepHeading(text), undefined, text);
    }
  });
});

describe('groupSteps', () => {
  it('wraps a run of numbered sections, deeper headings included, and maps ids to numbers', () => {
    const tree = root(
      h('h2', { id: 'before-you-start' }, 'Before you start'),
      h('p', {}, 'Intro.'),
      h('h2', { id: '1-install' }, '1. Install'),
      h('p', {}, 'a'),
      h('h3', { id: 'details' }, 'Details'),
      h('p', {}, 'b'),
      h('h2', { id: '2-sign-in' }, '2. Sign in'),
      h('p', {}, 'c'),
      h('h2', { id: 'troubleshooting' }, 'Troubleshooting'),
    );
    assert.deepEqual(groupSteps(tree), { '1-install': 1, '2-sign-in': 2 });
    assert.deepEqual(outline(tree.children), [
      'h2#before-you-start',
      'p',
      'div.fd-steps[div.fd-step[h2#1-install p h3#details p] div.fd-step[h2#2-sign-in p]]',
      'h2#troubleshooting',
    ]);
  });

  it('keeps the number prefix for screen readers in an sr-only span', () => {
    const first = h('h2', { id: 'step-1-copy' }, 'Step 1: Copy ', h('code', {}, 'id'));
    const tree = root(first, h('h2', { id: 'step-2-paste' }, 'Step 2: Paste'));
    groupSteps(tree);
    const [prefix, rest, code] = first.children;
    assert.ok(isElement(prefix));
    assert.deepEqual(classesOf(prefix), ['sr-only']);
    assert.equal(textOf(prefix), 'Step 1: ');
    assert.deepEqual(rest, { type: 'text', value: 'Copy ' });
    assert.ok(isElement(code) && code.tagName === 'code');
    assert.equal(textOf(first), 'Step 1: Copy id');
  });

  it('wraps h3 steps inside a section and ends them at the next h2', () => {
    const tree = root(
      h('h2', { id: 'setup' }, 'Setup'),
      h('h3', { id: '1-a' }, '1. A'),
      h('p', {}, 'a'),
      h('h3', { id: '2-b' }, '2. B'),
      h('p', {}, 'b'),
      h('h2', { id: 'next' }, 'Next'),
      h('p', {}, 'c'),
    );
    assert.deepEqual(groupSteps(tree), { '1-a': 1, '2-b': 2 });
    assert.deepEqual(outline(tree.children), [
      'h2#setup',
      'div.fd-steps[div.fd-step[h3#1-a p] div.fd-step[h3#2-b p]]',
      'h2#next',
      'p',
    ]);
  });

  it('starts a new run when the numbering starts over', () => {
    const tree = root(
      h('h2', { id: '1-a' }, '1. A'),
      h('h2', { id: '2-b' }, '2. B'),
      h('h2', { id: '1-c' }, '1. C'),
      h('h2', { id: '2-d' }, '2. D'),
    );
    assert.deepEqual(groupSteps(tree), { '1-a': 1, '2-b': 2, '1-c': 1, '2-d': 2 });
    assert.deepEqual(outline(tree.children), [
      'div.fd-steps[div.fd-step[h2#1-a] div.fd-step[h2#2-b]]',
      'div.fd-steps[div.fd-step[h2#1-c] div.fd-step[h2#2-d]]',
    ]);
  });

  it('needs headings numbered 1 to n at one level', () => {
    const cases: [string, HastRoot][] = [
      ['single step', root(h('h2', { id: 'a' }, '1. A'), h('p', {}, 'a'), h('h2', { id: 'b' }, 'B'))],
      ['run starting at 2', root(h('h2', { id: 'b' }, '2. B'), h('h2', { id: 'c' }, '3. C'))],
      ['gap in the numbers', root(h('h2', { id: 'a' }, '1. A'), h('h2', { id: 'c' }, '3. C'))],
      ['mixed levels', root(h('h2', { id: 'a' }, '1. A'), h('h3', { id: 'b' }, '2. B'))],
      ['h4 steps', root(h('h4', { id: 'a' }, '1. A'), h('h4', { id: 'b' }, '2. B'))],
      ['prefix outside the first text', root(h('h2', { id: 'a' }, h('em', {}, '1. A')), h('h2', { id: 'b' }, h('em', {}, '2. B')))],
    ];
    for (const [name, tree] of cases) {
      const before = structuredClone(tree);
      assert.deepEqual(groupSteps(tree), {}, name);
      assert.deepEqual(tree, before, name);
    }
  });

  it('ends the last step at a stop node', () => {
    const footer = h('p', {}, 'Last checked on 2026-10-09.');
    const tree = root(h('h2', { id: 'a' }, '1. A'), h('p', {}, 'a'), h('h2', { id: 'b' }, '2. B'), h('p', {}, 'b'), footer);
    groupSteps(tree, new Set([footer]));
    assert.deepEqual(outline(tree.children), ['div.fd-steps[div.fd-step[h2#a p] div.fd-step[h2#b p]]', 'p']);
    assert.equal(tree.children.at(-1), footer);
  });

  it('never splits raw HTML between steps', () => {
    const split = root(h('h2', { id: 'a' }, '1. A'), raw('<details>'), h('h2', { id: 'b' }, '2. B'), raw('</details>'));
    assert.deepEqual(groupSteps(split), {});

    const whole = root(
      h('h2', { id: 'a' }, '1. A'),
      raw('<details><summary>More</summary>'),
      h('p', {}, 'Inside.', raw('<br>')),
      raw('</details>'),
      raw('<a href="/images/a.png"><img src="/images/a.png" alt="A" /></a>'),
      h('h2', { id: 'b' }, '2. B'),
    );
    assert.deepEqual(groupSteps(whole), { a: 1, b: 2 });
  });
});

// ---------------------------------------------------------------------------
// rehypeGuideComponents

describe('rehypeGuideComponents', () => {
  it('leaves MDX files alone', () => {
    const tree = root(
      h('p', {}, 'Short lead.'),
      h('p', {}, 'You need a Mac.'),
      h('h2', { id: 'a' }, '1. A'),
      h('h2', { id: 'b' }, '2. B'),
      h('p', {}, 'Last checked on 2026-10-09.'),
    );
    const before = structuredClone(tree);
    const file = mdxFile();
    rehypeGuideComponents()(tree, file);
    assert.deepEqual(tree, before);
    assert.deepEqual(file.data, {});
  });

  it('always sets frontmatter.steps', () => {
    assert.deepEqual(runGuide(root(h('h2', { id: 'a' }, 'A'))).steps, {});
    const frontmatter = runGuide(root(h('h2', { id: '1-a' }, '1. A'), h('h2', { id: '2-b' }, '2. B')));
    assert.deepEqual(frontmatter.steps, { '1-a': 1, '2-b': 2 });
  });

  it('moves a short opening paragraph into frontmatter.lead', () => {
    const tree = root(
      h('p', {}, 'Heeler joins your ', h('a', { href: '/tailscale' }, 'tailnet'), ' with\n', h('strong', {}, 'no'), ' VPN.'),
      h('h2', { id: 'steps' }, 'Steps'),
    );
    const frontmatter = runGuide(tree);
    assert.equal(frontmatter.lead, 'Heeler joins your <a href="/tailscale">tailnet</a> with <strong>no</strong> VPN.');
    assert.deepEqual(outline(tree.children), ['h2#steps']);
  });

  it('keeps an opening paragraph that cannot serve as the lead', () => {
    const cases: [string, Element][] = [
      ['lead-in sentence', h('p', {}, 'Use a VPS. The result is:')],
      ['too long', h('p', {}, 'word '.repeat(70))],
      ['raw HTML', h('p', {}, 'See ', raw('<img src="/images/a.png" alt="A">'))],
      ['image', h('p', {}, h('img', { src: '/images/a.png', alt: 'A' }))],
      ['other attributes', h('p', {}, h('a', { href: '/x', target: '_blank' }, 'x'))],
    ];
    for (const [name, paragraph] of cases) {
      const tree = root(paragraph, h('h2', { id: 'next' }, 'Next'));
      assert.equal(runGuide(tree).lead, undefined, name);
      assert.deepEqual(outline(tree.children), ['p', 'h2#next'], name);
    }

    const headingFirst = root(h('h2', { id: 'a' }, 'A'), h('p', {}, 'Short.'));
    assert.equal(runGuide(headingFirst).lead, undefined);
    assert.deepEqual(outline(headingFirst.children), ['h2#a', 'p']);
  });

  it('restyles closing review metadata, removes the maintainers note, and ends steps before them', () => {
    const metadata = h(
      'p',
      {},
      'Commands and console labels were checked against ZeroTier\'s ',
      h('a', { href: 'https://docs.zerotier.com/' }, 'documentation'),
      ' on 2026-10-09.',
    );
    const tree = root(
      h('h2', { id: '1-a' }, '1. A'),
      h('p', {}, 'a'),
      h('h2', { id: '2-b' }, '2. B'),
      h('p', {}, 'b'),
      metadata,
      h('p', {}, 'Maintainers: see the ', h('a', { href: 'https://example.com/record' }, 'guide maintenance record'), '.'),
    );
    const frontmatter = runGuide(tree);

    assert.deepEqual(outline(tree.children), ['div.fd-steps[div.fd-step[h2#1-a p] div.fd-step[h2#2-b p]]', 'p']);
    assert.equal(tree.children.at(-1), metadata);
    assert.ok(classesOf(metadata).includes('border-t'));
    assert.ok(classesOf(metadata).includes('not-prose'));
    const [icon, body] = metadata.children;
    assert.ok(isElement(icon) && icon.tagName === 'svg');
    assert.ok(isElement(body) && body.tagName === 'span');
    assert.equal(textOf(metadata), "Commands and console labels were checked against ZeroTier's documentation on 2026-10-09.");
    assert.doesNotMatch(JSON.stringify(tree), /Maintainers/);
    assert.deepEqual(frontmatter.steps, { '1-a': 1, '2-b': 2 });
  });

  it('only treats the last three blocks as trailers', () => {
    const early = h('p', {}, 'Checked against Tailscale 1.90.');
    const tree = root(h('h2', { id: 'a' }, 'A'), early, h('p', {}, 'b'), h('p', {}, 'c'), h('p', {}, 'd'));
    runGuide(tree);
    assert.deepEqual(early.properties, {});
    assert.equal(textOf(early), 'Checked against Tailscale 1.90.');
  });
});

describe('leadHtml and phrasingHtml', () => {
  it('serializes plain phrasing content', () => {
    assert.equal(
      phrasingHtml(
        inline(
          h('strong', {}, 'Bold'),
          ' ',
          h('em', {}, 'it'),
          h('br'),
          h('code', {}, 'a<b'),
          h('del', {}, 'old'),
          h('span', { className: ['sr-only'] }, 'hidden'),
          h('a', { href: 'mailto:help@example.com' }, 'mail'),
          h('a', { href: 'https://herdr.dev', title: 'herdr' }, 'site'),
        ),
      ),
      '<strong>Bold</strong> <em>it</em><br><code>a&lt;b</code><del>old</del><span class="sr-only">hidden</span>' +
        '<a href="mailto:help@example.com">mail</a><a href="https://herdr.dev" title="herdr">site</a>',
    );
  });

  it('escapes text and attribute values', () => {
    assert.equal(
      phrasingHtml(
        inline('a < b & "c" > d', h('a', { href: '/x?a=1&b="2"', title: '<t>' }, '<go>'), h('span', { className: ['a"b'] }, 'x')),
      ),
      'a &lt; b &amp; "c" &gt; d<a href="/x?a=1&amp;b=&quot;2&quot;" title="&lt;t&gt;">&lt;go&gt;</a><span class="a&quot;b">x</span>',
    );
  });

  it('rejects unsafe links, other attributes, raw HTML, and other elements', () => {
    const rejected: ElementContent[] = [
      h('a', { href: 'javascript:alert(1)' }, 'x'),
      h('a', { href: 'java\tscript:alert(1)' }, 'x'),
      h('a', { href: ' JAVASCRIPT:alert(1)' }, 'x'),
      h('a', { href: 'data:text/html,x' }, 'x'),
      h('a', { href: '/x', target: '_blank' }, 'x'),
      h('span', { style: 'color: red' }, 'x'),
      h('strong', { id: 'x' }, 'x'),
      h('img', { src: '/images/a.png', alt: '' }),
      h('kbd', {}, 'x'),
      h('em', {}, raw('<b>x</b>')),
      raw('<b>x</b>'),
    ];
    for (const node of rejected) {
      assert.equal(phrasingHtml([node]), undefined, JSON.stringify(node));
    }
  });

  it('accepts only short paragraphs that are not lead-ins', () => {
    assert.equal(leadHtml(h('p', {}, 'Line one\n  line two.')), 'Line one line two.');
    assert.equal(leadHtml(h('p', {}, 'x'.repeat(320))), 'x'.repeat(320));
    assert.equal(leadHtml(h('p', {}, 'x'.repeat(321))), undefined);
    assert.equal(leadHtml(h('p', {}, 'You need:')), undefined);
    assert.equal(leadHtml(h('p', {}, '  ')), undefined);
    assert.equal(leadHtml(h('div', {}, 'Short.')), undefined);
  });
});

// ---------------------------------------------------------------------------
// Trailers

describe('trailers', () => {
  it('classifies review metadata and the maintainers note', () => {
    assert.equal(trailerKind('Last checked on 2026-10-09 on macOS.'), 'metadata');
    assert.equal(trailerKind("Checked against Tailscale's documentation on 2026-10-09."), 'metadata');
    assert.equal(trailerKind('Commands were checked against EasyTier v2.6.4 on macOS in October 2026.'), 'metadata');
    assert.equal(trailerKind('Commands and console labels\nwere checked against ZeroTier.'), 'metadata');
    assert.equal(trailerKind('Maintainers: see the guide maintenance record.'), 'maintainers');
    assert.equal(trailerKind('This guide was last checked on Monday.'), undefined);
    assert.equal(trailerKind('Maintainers see the record.'), undefined);
  });

  it('lists the trailer paragraphs among the last three blocks for search', () => {
    const paragraph = (...children: PhrasingContent[]): Paragraph => ({ type: 'paragraph', children });
    const early = paragraph({ type: 'text', value: 'Last checked on 2026-01-01.' });
    const metadata = paragraph({ type: 'text', value: 'Checked against Tailscale 1.90.' });
    const maintainers = paragraph(
      { type: 'text', value: 'Maintainers: see the ' },
      { type: 'link', url: 'https://example.com', children: [{ type: 'text', value: 'record' }] },
      { type: 'text', value: '.' },
    );
    const tree: MdastRoot = {
      type: 'root',
      children: [early, paragraph({ type: 'text', value: 'Body.' }), metadata, maintainers],
    };
    const hidden = hiddenForSearch(tree);
    assert.equal(hidden.length, 2);
    assert.equal(hidden[0], metadata);
    assert.equal(hidden[1], maintainers);
    assert.deepEqual(hiddenForSearch({ type: 'root', children: [paragraph({ type: 'text', value: 'Body.' })] }), []);
  });
});

// ---------------------------------------------------------------------------
// Code block titles

const code = (lang: string | null, value = 'x', meta: string | null = null): Code => ({ type: 'code', lang, meta, value });
const words = (value: string): Paragraph => ({ type: 'paragraph', children: [{ type: 'text', value }] });
const leadIn = (...children: PhrasingContent[]): Paragraph => ({ type: 'paragraph', children });

describe('codeBlockTitle', () => {
  it('titles shell and PowerShell blocks', () => {
    for (const lang of ['sh', 'bash', 'zsh', 'shell', 'console', 'Bash']) {
      assert.deepEqual(codeBlockTitle(code(lang), []), { title: 'Terminal', noCopy: false }, lang);
    }
    for (const lang of ['powershell', 'ps1', 'pwsh', 'PowerShell']) {
      assert.deepEqual(codeBlockTitle(code(lang), []), { title: 'PowerShell', noCopy: false }, lang);
    }
  });

  it('titles SSH config with the one path its lead-in names', () => {
    const named = leadIn({ type: 'text', value: 'Add this block to ' }, { type: 'inlineCode', value: '~/.ssh/config' }, { type: 'text', value: ':' });
    assert.deepEqual(codeBlockTitle(code('sshconfig'), [named]), { title: '~/.ssh/config', noCopy: false });
    const absolute = leadIn({ type: 'text', value: 'Create ' }, { type: 'inlineCode', value: '/etc/ssh/sshd_config.d/60-herdr-forwarding.conf' });
    assert.deepEqual(codeBlockTitle(code('ssh-config'), [absolute]), {
      title: '/etc/ssh/sshd_config.d/60-herdr-forwarding.conf',
      noCopy: false,
    });

    const two = leadIn({ type: 'inlineCode', value: '~/.ssh/config' }, { type: 'text', value: ' or ' }, { type: 'inlineCode', value: '/etc/ssh/ssh_config' });
    const notPath = leadIn({ type: 'text', value: 'Add a ' }, { type: 'inlineCode', value: 'Host' }, { type: 'text', value: ' block:' });
    for (const previous of [[two], [notPath], [], [code('text', '~/.ssh/config')]]) {
      assert.deepEqual(codeBlockTitle(code('sshconfig'), previous), { title: 'SSH config', noCopy: false });
    }
  });

  it('titles XML with the .plist file named just before it', () => {
    const path = code('text', '~/Library/LaunchAgents/dev.herdr.VPS_NAME-reverse-ssh.plist');
    assert.deepEqual(codeBlockTitle(code('xml'), [path]), { title: 'dev.herdr.VPS_NAME-reverse-ssh.plist', noCopy: false });
    assert.deepEqual(codeBlockTitle(code('xml'), [words('With this content:'), path]), {
      title: 'dev.herdr.VPS_NAME-reverse-ssh.plist',
      noCopy: false,
    });
    assert.deepEqual(codeBlockTitle(code('xml'), [code('text', 'a.plist\nb.plist')]), { title: 'XML', noCopy: false });
    assert.deepEqual(codeBlockTitle(code('xml'), [code('bash', 'a.plist')]), { title: 'XML', noCopy: false });
    assert.deepEqual(codeBlockTitle(code('xml'), []), { title: 'XML', noCopy: false });
  });

  it('marks sample output after an expectation as not copyable', () => {
    const expected = { title: 'Expected output', noCopy: true };
    assert.deepEqual(codeBlockTitle(code('text'), [words('Expected:')]), expected);
    assert.deepEqual(codeBlockTitle(code(null), [words('Expected state:')]), expected);
    assert.deepEqual(codeBlockTitle(code('txt'), [words('The local-address column\nmust show:')]), expected);
    assert.deepEqual(codeBlockTitle(code('plaintext'), [words('The required result is:')]), expected);
    assert.deepEqual(codeBlockTitle(code('text'), [words('It must not show:')]), { title: 'Must not appear', noCopy: true });
  });

  it('leaves other blocks and fences with their own meta untitled', () => {
    assert.equal(codeBlockTitle(code('json'), [words('Expected:')]), undefined);
    assert.equal(codeBlockTitle(code('text'), [words('Open:')]), undefined);
    assert.equal(codeBlockTitle(code('text'), [code('text', 'Expected:')]), undefined);
    assert.equal(codeBlockTitle(code('text'), []), undefined);
    assert.equal(codeBlockTitle(code('bash', 'ls', 'title="Mine"'), []), undefined);
  });
});

describe('codeMeta', () => {
  it('writes the meta string rehypeCode reads', () => {
    assert.equal(codeMeta({ title: 'Terminal', noCopy: false }), 'title="Terminal"');
    assert.equal(codeMeta({ title: 'Expected output', noCopy: true }), 'title="Expected output" noCopy');
    assert.equal(codeMeta({ title: 'say "hi"', noCopy: false }), undefined);
  });
});

describe('remarkGuideCode', () => {
  const build = () => {
    const ssh = code('sshconfig', 'Host vps');
    const shell = code('bash', 'ls');
    const output = code('text', 'OK');
    const own = code('bash', 'ls', 'title="Mine"');
    const tree: MdastRoot = {
      type: 'root',
      children: [
        leadIn({ type: 'text', value: 'Add this to ' }, { type: 'inlineCode', value: '~/.ssh/config' }, { type: 'text', value: ':' }),
        ssh,
        {
          type: 'list',
          children: [{ type: 'listItem', children: [words('Run:'), shell, words('Expected:'), output] }],
        },
        own,
      ],
    };
    return { tree, ssh, shell, output, own };
  };

  it('titles fences at any depth and renames sshconfig for Shiki', () => {
    const { tree, ssh, shell, output, own } = build();
    remarkGuideCode()(tree, { path: '/repo/docs/guides/example.md' });
    assert.equal(ssh.meta, 'title="~/.ssh/config"');
    assert.equal(ssh.lang, 'ssh-config');
    assert.equal(shell.meta, 'title="Terminal"');
    assert.equal(output.meta, 'title="Expected output" noCopy');
    assert.equal(own.meta, 'title="Mine"');
  });

  it('leaves MDX files alone', () => {
    const { tree } = build();
    const before = structuredClone(tree);
    remarkGuideCode()(tree, { path: '/repo/docs-site/content/index.mdx' });
    assert.deepEqual(tree, before);
  });
});

// ---------------------------------------------------------------------------
// Callouts and checklists

describe('guide callouts', () => {
  it('turns "You need" before the first section into an info callout', () => {
    const need = h('p', {}, 'You need a Heeler version with ', h('strong', {}, 'Settings > Overlay Networks'), '.');
    const later = h('p', {}, 'You need a VPS too.');
    const tree = root(h('p', {}, 'The lead.'), need, h('h2', { id: 'a' }, 'A'), later);
    runGuide(tree);

    const notes = findAll(tree, isNote);
    assert.equal(notes.length, 1);
    const [note] = notes;
    assert.ok(note !== undefined);
    assert.match(String(note.properties.style), /--color-fd-info/);
    assert.equal(note.properties.ariaLabel, undefined);
    assert.equal(findAll(note, (node) => node === need).length, 1);
    assert.deepEqual(outline(tree.children), ['div', 'h2#a', 'p']);
  });

  it('turns "It worked if" paragraphs into success callouts at any depth', () => {
    const check = h('p', {}, h('strong', {}, 'It worked if'), ' the network shows ', h('code', {}, 'OK PRIVATE'), '.');
    const item = h('li', {}, h('p', {}, 'Join the network.'), check);
    const tree = root(h('h2', { id: 'a' }, 'A'), h('ol', {}, item), h('p', {}, h('strong', {}, 'It worked'), ' maybe.'));
    runGuide(tree);

    const notes = findAll(tree, isNote);
    assert.equal(notes.length, 1);
    const [note] = notes;
    assert.ok(note !== undefined);
    assert.match(String(note.properties.style), /--color-fd-success/);
    assert.equal(note.properties.ariaLabel, undefined);
    assert.ok(item.children.includes(note));
    assert.equal(findAll(note, (node) => node === check).length, 1);
  });

  it('wraps the block after "Checkpoint:" in a titled success callout', () => {
    const list = h(
      'ul',
      { className: ['contains-task-list'] },
      h('li', { className: ['task-list-item'] }, h('input', { type: 'checkbox', disabled: true }), ' The key is mode 600.'),
    );
    const tree = root(
      h('h2', { id: 'a' }, 'A'),
      h('p', {}, 'Checkpoint:'),
      list,
      h('p', {}, 'Checkpoint:'),
      h('h3', { id: 'b' }, 'B'),
      h('p', {}, 'Checkpoint:'),
      h('hr'),
    );
    runGuide(tree);

    const notes = findAll(tree, isNote);
    assert.equal(notes.length, 1);
    const [note] = notes;
    assert.ok(note !== undefined);
    assert.equal(note.properties.ariaLabel, 'Checkpoint');
    assert.match(String(note.properties.style), /--color-fd-success/);
    assert.equal(findAll(note, (node) => node === list).length, 1);
    assert.deepEqual(
      findAll(note, byTag('p')).map(textOf),
      ['Checkpoint'],
    );
    assert.deepEqual(outline(tree.children), ['h2#a', 'div', 'p', 'h3#b', 'p', 'hr']);
  });

  it('keeps every block up to the next heading in a checkpoint, such as a command and what it must print', () => {
    const command = h('pre', {}, h('code', {}, 'grep -F "$DEVICE_KEY" ~/.ssh/authorized_keys'));
    const criterion = h('p', {}, 'The command must print exactly one matching authorized-key line.');
    const tree = root(h('h2', { id: 'a' }, 'A'), h('p', {}, 'Checkpoint:'), command, criterion, h('h2', { id: 'b' }, 'B'), h('p', {}, 'b'));
    runGuide(tree);

    const [note] = findAll(tree, isNote);
    assert.ok(note !== undefined);
    const body = findAll(note, (node) => node === command || node === criterion);
    assert.deepEqual(body, [command, criterion]);
    assert.deepEqual(outline(tree.children), ['h2#a', 'div', 'h2#b', 'p']);
    // The line break before the next heading stays outside the callout.
    assert.deepEqual(tree.children[3], { type: 'text', value: '\n' });
  });

  it('ends a checkpoint at a callout, another checkpoint, closing review metadata, or unbalanced raw HTML', () => {
    const alert = h('blockquote', {}, h('p', {}, '[!NOTE]\nA note.'));
    const footer = h('p', {}, 'Last checked on 2026-10-09.');
    const tree = root(
      h('h2', { id: 'a' }, 'A'),
      h('p', {}, 'Checkpoint:'),
      h('ul', {}, h('li', {}, 'One.')),
      alert,
      h('p', {}, 'Checkpoint:'),
      h('ul', {}, h('li', {}, 'Two.')),
      h('p', {}, 'Checkpoint:'),
      h('ul', {}, h('li', {}, 'Three.')),
      footer,
    );
    rehypeGithubAlerts()(tree);
    runGuide(tree);

    const notes = findAll(tree, isNote);
    assert.deepEqual(
      notes.map((note) => note.properties.ariaLabel),
      ['Checkpoint', 'Note', 'Checkpoint', 'Checkpoint'],
    );
    for (const note of notes) assert.deepEqual(findAll(note, isNote), [note]);
    assert.equal(tree.children.filter(isElement).at(-1), footer);
    assert.ok(classesOf(footer).includes('border-t'));

    const split = root(h('h2', { id: 'a' }, 'A'), h('p', {}, 'Checkpoint:'), raw('<details>'), h('h3', { id: 'b' }, 'B'), raw('</details>'));
    runGuide(split);
    assert.deepEqual(findAll(split, isNote), []);
  });
});

describe('checklists', () => {
  it('marks the list under "Before you start" or "Prerequisites", one lead-in paragraph allowed', () => {
    const direct = h('ul', {}, h('li', {}, 'an iPhone with Heeler installed;'), h('li', {}, 'a Mac with herdr installed.'));
    const afterLeadIn = h('ul', {}, h('li', {}, 'a VPS.'));
    const other = h('ul', {}, h('li', {}, 'Other.'));
    const tree = root(
      h('h2', { id: 'before-you-start' }, 'Before you start'),
      direct,
      h('h2', { id: 'prerequisites' }, 'Prerequisites'),
      h('p', {}, 'You need:'),
      afterLeadIn,
      h('h2', { id: 'other' }, 'Other'),
      other,
    );
    runGuide(tree);

    for (const list of [direct, afterLeadIn]) {
      assert.ok(classesOf(list).includes('list-none'));
      assert.ok(classesOf(list).includes('bg-fd-card'));
      for (const item of list.children.filter(isElement)) {
        assert.ok(classesOf(item).includes('ps-7'));
        const [icon] = item.children;
        assert.ok(isElement(icon) && icon.tagName === 'svg');
        assert.equal(icon.properties.ariaHidden, 'true');
      }
    }
    assert.equal(textOf(direct), 'an iPhone with Heeler installed;a Mac with herdr installed.');
    assert.deepEqual(other.properties, {});
  });

  it('leaves task lists and lists further down alone', () => {
    const tasks = h('ul', { className: ['contains-task-list'] }, h('li', { className: ['task-list-item'] }, 'Task'));
    const late = h('ul', {}, h('li', {}, 'Late.'));
    runGuide(root(h('h2', { id: 'before-you-start' }, 'Before you start'), tasks));
    runGuide(root(h('h2', { id: 'prerequisites' }, 'Prerequisites'), h('p', {}, 'One.'), h('p', {}, 'Two.'), late));
    assert.deepEqual(classesOf(tasks), ['contains-task-list']);
    assert.deepEqual(late.properties, {});
  });
});

// ---------------------------------------------------------------------------
// Inline polish

describe('inline polish helpers', () => {
  it('recognizes key combinations', () => {
    for (const text of ['Control-C', 'Command-Shift-K', 'Option-Tab', ' Shift-1 ']) assert.equal(isShortcut(text), true, text);
    for (const text of ['Control', 'Control-', 'Ctrl-C', 'control-c', 'Control C']) assert.equal(isShortcut(text), false, text);
  });

  it('splits menu paths on " > "', () => {
    assert.deepEqual(menuPathItems('Settings > Overlay Networks > Add Network'), ['Settings', 'Overlay Networks', 'Add Network']);
    for (const text of ['Settings', 'a>b', 'Settings > ', ' > General']) assert.equal(menuPathItems(text), undefined, text);
  });

  it('parses "Run on" labels and picks an icon for the machine', () => {
    assert.deepEqual(parseRunOn('Run on: macOS'), { label: 'Run on:', target: 'macOS', icon: 'Laptop' });
    assert.deepEqual(parseRunOn('Run first on: VPS'), { label: 'Run first on:', target: 'VPS', icon: 'Server' });
    assert.deepEqual(parseRunOn('Run in another session on: VPS'), {
      label: 'Run in another session on:',
      target: 'VPS',
      icon: 'Server',
    });
    assert.deepEqual(parseRunOn('Then run on: macOS'), { label: 'Then run on:', target: 'macOS', icon: 'Laptop' });
    assert.equal(parseRunOn('Run on: the new client Mac')?.icon, 'Laptop');
    assert.equal(parseRunOn('Run on: VPS provider console and VPS')?.icon, 'Server');
    assert.equal(parseRunOn('Run on: iOS')?.icon, 'Smartphone');
    assert.equal(parseRunOn('Run on: Windows PC')?.icon, 'MapPin');
    for (const text of ['Run this on: VPS', 'Run on:', 'Runs on: VPS', 'Run on VPS']) assert.equal(parseRunOn(text), undefined, text);
  });
});

describe('inline polish', () => {
  it('renders key combinations in bold or code as <kbd>', () => {
    const paragraph = h(
      'p',
      {},
      'Press ',
      h('strong', {}, 'Control-C'),
      ' or ',
      h('code', {}, 'Command-Shift-K'),
      ', not ',
      h('code', {}, 'Control'),
      '.',
    );
    const tree = root(h('h2', { id: 'a' }, 'A'), paragraph);
    runGuide(tree);
    assert.deepEqual(findAll(tree, byTag('kbd')).map(textOf), ['Control-C', 'Command-Shift-K']);
    assert.deepEqual(findAll(tree, byTag('code')).map(textOf), ['Control']);
    assert.equal(textOf(paragraph), 'Press Control-C or Command-Shift-K, not Control.');
  });

  it('adds chevrons to bold menu paths outside headings and links', () => {
    const tree = root(
      h('h2', { id: 'a' }, 'Open ', h('strong', {}, 'Settings > General')),
      h('p', {}, 'Open ', h('strong', {}, 'Settings > Overlay Networks > Add Network'), '.'),
      h('p', {}, h('a', { href: '/x' }, h('strong', {}, 'Settings > General'))),
    );
    runGuide(tree);

    // The plugin replaces nodes, so read them back from the tree.
    const [inHeading, polished, inLink] = findAll(tree, byTag('strong'));
    assert.ok(inHeading !== undefined && polished !== undefined && inLink !== undefined);
    assert.equal(textOf(polished), 'Settings > Overlay Networks > Add Network');
    assert.equal(findAll(polished, byTag('svg')).length, 2);
    assert.deepEqual(
      findAll(polished, (node) => classesOf(node).includes('sr-only')).map(textOf),
      [' > ', ' > '],
    );
    assert.deepEqual(inHeading.children, [{ type: 'text', value: 'Settings > General' }]);
    assert.deepEqual(inLink.children, [{ type: 'text', value: 'Settings > General' }]);
  });

  it('adds chevrons between menu items written as separate bold text', () => {
    const pair = h('p', {}, 'choose ', h('strong', {}, '…'), ' > ', h('strong', {}, 'Edit'), ', and change it.');
    const chain = h('li', {}, 'go to Heeler > ', h('strong', {}, 'Hosts'), ' > ', h('strong', {}, 'Add Host'), ', then');
    const prose = h('p', {}, 'if a > ', h('strong', {}, 'b'), ' and ', h('strong', {}, 'c'), ' > d');
    const linked = h('p', {}, h('a', { href: '/x' }, h('strong', {}, 'A'), ' > ', h('strong', {}, 'B')));
    const heading = h('h3', { id: 'b' }, h('strong', {}, 'A'), ' > ', h('strong', {}, 'B'));
    const tree = root(h('h2', { id: 'a' }, 'A'), pair, h('ul', {}, chain), prose, linked, heading);
    const before = textOf(tree);
    runGuide(tree);

    const separators = (node: Element) => findAll(node, (child) => classesOf(child).includes('sr-only')).map(textOf);
    assert.deepEqual(separators(pair), [' > ']);
    assert.equal(findAll(pair, byTag('svg')).length, 1);
    assert.deepEqual(separators(chain), [' > ', ' > ']);
    assert.equal(findAll(chain, byTag('svg')).length, 2);
    for (const unchanged of [prose, linked, heading]) assert.deepEqual(separators(unchanged), []);
    assert.equal(textOf(tree), before);
  });

  it('turns a paragraph holding only a "Run on" label into a badge', () => {
    const tree = root(
      h('h2', { id: 'a' }, 'A'),
      h('p', {}, h('strong', {}, 'Run on: VPS')),
      h('p', {}, h('strong', {}, 'Run on: VPS'), ' and wait.'),
      h('p', {}, h('strong', {}, 'Run on: ', h('code', {}, 'mac'))),
    );
    runGuide(tree);

    // The plugin replaces paragraphs, so read them back from the tree.
    const [, badge, sentence, formatted] = tree.children.filter(isElement);
    assert.ok(badge !== undefined && sentence !== undefined && formatted !== undefined);
    const [strong] = badge.children;
    assert.ok(isElement(strong) && strong.tagName === 'strong');
    assert.ok(classesOf(strong).includes('rounded-2xl'));
    const [icon, label] = strong.children;
    assert.ok(isElement(icon) && icon.tagName === 'svg');
    assert.ok(isElement(label));
    assert.equal(textOf(strong), 'Run on: VPS');
    assert.deepEqual(
      findAll(label, (node) => classesOf(node).includes('text-fd-muted-foreground')).map(textOf),
      ['Run on:'],
    );
    for (const paragraph of [sentence, formatted]) {
      const [unchanged] = paragraph.children;
      assert.ok(isElement(unchanged));
      assert.deepEqual(unchanged.properties, {});
    }
  });
});

// ---------------------------------------------------------------------------
// rehypeFumadocsElements: tables, headings, code frames

describe('tables', () => {
  const table = (headers: string[], cell: Child = 'x'): Element =>
    h('table', {}, h('thead', {}, h('tr', {}, ...headers.map((name) => h('th', {}, name)))), h('tbody', {}, h('tr', {}, h('td', {}, cell))));

  it('classifies form-value tables and screenshot galleries', () => {
    assert.equal(tableKind(table(['Field', 'Value'])), 'fields');
    assert.equal(tableKind(table(['Host field', 'Value'])), 'fields');
    assert.equal(tableKind(table(['Placeholder', 'Example', 'Meaning'])), 'fields');
    assert.equal(tableKind(table(['Tailscale', 'ZeroTier'], raw('<a href="/images/a.png"><img src="/images/a.png" alt="A"></a>'))), 'gallery');
    assert.equal(tableKind(table(['Before', 'After'], h('img', { src: '/images/a.png', alt: '' }))), 'gallery');
    assert.equal(tableKind(table(['Symptom', 'Fix'])), undefined);
    assert.equal(tableKind(table(['Field'])), undefined);
    assert.equal(tableKind(h('table', {})), undefined);
  });

  it('labels the scrolling wrapper with data-table', () => {
    const tree = root(table(['Field', 'Value']), table(['Symptom', 'Fix']));
    rehypeFumadocsElements()(tree, guideFile());
    const wrappers = tree.children.filter(isElement);
    assert.deepEqual(
      wrappers.map((wrapper) => [wrapper.tagName, wrapper.properties.dataTable]),
      [
        ['div', 'fields'],
        ['div', undefined],
      ],
    );
  });
});

describe('heading anchors', () => {
  it('adds a copy-link button with no text of its own, so ids and TOC text stay', () => {
    const heading = h('h3', { id: 'details' }, h('span', { className: ['sr-only'] }, '1. '), 'Details');
    const tree = root(heading, h('h1', { id: 'title' }, 'Title'), h('h2', {}, 'No id'));
    rehypeFumadocsElements()(tree, guideFile());

    const [anchored, title, plain] = tree.children.filter(isElement);
    assert.ok(anchored !== undefined && title !== undefined && plain !== undefined);
    assert.equal(anchored.properties.id, 'details');
    assert.equal(textOf(anchored), '1. Details');
    const [link, button] = anchored.children;
    assert.ok(isElement(link) && link.tagName === 'a');
    assert.equal(link.properties.href, '#details');
    assert.ok(isElement(button) && button.tagName === 'button');
    assert.equal(button.properties.type, 'button');
    assert.equal(button.properties.dataCopyAnchor, '');
    assert.equal(button.properties.ariaLabel, 'Copy anchor link');
    // No text to change, so no live region; content.ts announces the copy.
    assert.equal(button.properties.ariaLive, undefined);
    assert.equal(textOf(button), '');
    assert.equal(findAll(button, byTag('svg')).length, 2);
    assert.deepEqual(title.properties, { id: 'title' });
    assert.deepEqual(plain.properties, {});
  });
});

describe('code frames', () => {
  const shiki = (properties: Element['properties']): Element =>
    h(
      'pre',
      { class: 'shiki shiki-themes github-light github-dark', style: '--shiki-light:#24292e', tabindex: '0', icon: '<svg></svg>', ...properties },
      h('code', {}, h('span', { className: ['line'] }, 'ls')),
    );
  const frame = (pre: Element): Element => {
    const tree = root(pre);
    rehypeFumadocsElements()(tree, guideFile());
    const [figure] = tree.children;
    assert.ok(isElement(figure) && figure.tagName === 'figure');
    assert.equal(figure.properties.dataCodeFrame, '');
    return figure;
  };
  const copyButtons = (figure: Element) => findAll(figure, (node) => node.properties.dataCopyCode !== undefined);
  const innerPre = (figure: Element): Element => {
    const [pre] = findAll(figure, byTag('pre'));
    assert.ok(pre !== undefined);
    return pre;
  };
  /** The title in the header row (a <figcaption> there could not caption the figure). */
  const titles = (figure: Element) => findAll(figure, (node) => classesOf(node).includes('truncate')).map(textOf);
  /** The scrolling viewport: focusable and named, but a group, not a landmark region. */
  const viewportOf = (figure: Element): Element => {
    assert.deepEqual(findAll(figure, (node) => node.properties.role === 'region'), []);
    const [viewport, ...others] = findAll(figure, (node) => node.properties.role === 'group');
    assert.ok(viewport !== undefined && others.length === 0);
    assert.equal(viewport.properties.tabIndex, 0);
    return viewport;
  };

  it('puts the title and copy button in a header', () => {
    const figure = frame(shiki({ title: 'Terminal' }));
    assert.equal(figure.properties.dataTitled, '');
    assert.deepEqual(titles(figure), ['Terminal']);
    assert.deepEqual(findAll(figure, byTag('figcaption')), []);
    assert.equal(copyButtons(figure).length, 1);
    assert.deepEqual(findAll(figure, (node) => classesOf(node).includes('absolute')), []);
    assert.equal(viewportOf(figure).properties.ariaLabel, 'Terminal');

    const pre = innerPre(figure);
    assert.deepEqual(Object.keys(pre.properties).sort(), ['className', 'style']);
    assert.ok(classesOf(pre).includes('shiki'));
    assert.equal(pre.properties.style, '--shiki-light:#24292e');
  });

  it('floats the copy button over an untitled frame and keeps line ends clear of it', () => {
    const figure = frame(shiki({}));
    assert.equal(figure.properties.dataTitled, undefined);
    assert.deepEqual(titles(figure), []);
    const [floating] = findAll(figure, (node) => classesOf(node).includes('absolute'));
    assert.ok(floating !== undefined);
    assert.equal(copyButtons(floating).length, 1);
    assert.equal(copyButtons(figure).length, 1);
    assert.match(String(innerPre(figure).properties.style), /^--shiki-light:#24292e; --padding-right: /);
    assert.equal(viewportOf(figure).properties.ariaLabel, 'Code');
  });

  it('gives sample output no copy button', () => {
    const titled = frame(shiki({ title: 'Expected output', allowCopy: 'false' }));
    assert.deepEqual(titles(titled), ['Expected output']);
    assert.deepEqual(copyButtons(titled), []);

    const untitled = frame(shiki({ allowCopy: false, style: undefined }));
    assert.deepEqual(copyButtons(untitled), []);
    assert.equal(innerPre(untitled).properties.style, undefined);
  });
});

describe('Chinese guide conventions', () => {
  const zhFile = () => ({ path: '/repo/docs/guides/zh/tailscale.md', data: {} as { astro?: { frontmatter?: Record<string, unknown> } } });

  it('drops Chinese lead-in sentences and extracts lead after a top HTML comment', () => {
    assert.equal(dropLeadIn('连接你的 Mac。输出如下：'), '连接你的 Mac。');
    assert.equal(leadHtml(h('p', {}, '结果如下：')), undefined);

    const tree = root(
      raw('<!-- Translated from docs/guides/tailscale.md at 2b014a24 -->'),
      h('p', {}, '从 Heeler 连接你的 Mac。'),
      h('h2', { id: '准备工作' }, '准备工作'),
    );
    const file = zhFile();
    rehypeGuideComponents()(tree, file);
    assert.equal(file.data.astro?.frontmatter?.lead, '从 Heeler 连接你的 Mac。');
  });

  it('classifies Chinese review metadata and maintainers trailers', () => {
    assert.equal(trailerKind('最后核对于 2026-10-09（macOS）。'), 'metadata');
    assert.equal(trailerKind('核对依据为 Tailscale 文档（2026-10-09）。'), 'metadata');
    assert.equal(trailerKind('命令已对照 Tailscale 1.104.1 核对（2026 年 10 月）。'), 'metadata');
    assert.equal(trailerKind('命令与控制台标签已核对于 2026-10-09。'), 'metadata');
    assert.equal(trailerKind('维护者：参见指南维护记录。'), 'maintainers');
  });

  it('titles Chinese code blocks and localized expectations', () => {
    const shBlock: Code = { type: 'code', lang: 'sh', value: 'herdr status' };
    const sshBlock: Code = { type: 'code', lang: 'sshconfig', value: 'Host vps' };
    const outBlock: Code = { type: 'code', lang: 'text', value: 'ok' };
    const expectP: Paragraph = { type: 'paragraph', children: [{ type: 'text', value: '预期输出：' }] };
    const forbidP: Paragraph = { type: 'paragraph', children: [{ type: 'text', value: '不应显示：' }] };

    assert.deepEqual(codeBlockTitle(shBlock, [], 'zh'), { title: '终端', noCopy: false });
    assert.deepEqual(codeBlockTitle(sshBlock, [], 'zh'), { title: 'SSH 配置', noCopy: false });
    assert.deepEqual(codeBlockTitle(outBlock, [expectP], 'zh'), { title: '预期输出', noCopy: true });
    assert.deepEqual(codeBlockTitle(outBlock, [forbidP], 'zh'), { title: '不应出现', noCopy: true });

    const mdTree: MdastRoot = { type: 'root', children: [expectP, { ...outBlock }, { ...shBlock }] };
    remarkGuideCode()(mdTree, zhFile());
    assert.equal((mdTree.children[1] as Code).meta, 'title="预期输出" noCopy');
    assert.equal((mdTree.children[2] as Code).meta, 'title="终端"');
  });

  it('renders localized GitHub alert labels for Chinese guides', () => {
    const tree = root(
      h('blockquote', {}, h('p', {}, '[!NOTE]\n补充说明。')),
      h('blockquote', {}, h('p', {}, '[!TIP]\n小贴士。')),
      h('blockquote', {}, h('p', {}, '[!IMPORTANT]\n重要信息。')),
      h('blockquote', {}, h('p', {}, '[!WARNING]\n警告信息。')),
      h('blockquote', {}, h('p', {}, '[!CAUTION]\n危险操作。')),
    );
    rehypeGithubAlerts()(tree, zhFile());
    const notes = findAll(tree, (node) => node.properties.role === 'note');
    assert.deepEqual(
      notes.map((note) => note.properties.ariaLabel),
      ['注意', '提示', '重要', '警告', '危险'],
    );
  });

  it('recognizes Chinese requirement callouts, success checks, checkpoints, checklists, steps, and Run on badges', () => {
    const checklist = h('ul', {}, h('li', {}, '一台装有 Heeler 的 iPhone'));
    const tree = root(
      h('p', {}, '导语段落。'),
      h('p', {}, '你需要准备一个 Tailscale 账号。'),
      h('h2', { id: '开始之前' }, '开始之前'),
      checklist,
      h('h2', { id: '步骤-1安装' }, '步骤 1：安装'),
      h('p', {}, h('strong', {}, '运行位置：macOS')),
      h('p', {}, h('strong', {}, '成功的标志是'), ' 菜单栏出现图标。'),
      h('h2', { id: '步骤-2验证' }, '步骤 2：验证'),
      h('p', {}, '检查点：'),
      h('p', {}, '状态显示已连接。'),
    );
    const file = zhFile();
    rehypeGuideComponents()(tree, file);

    assert.deepEqual(file.data.astro?.frontmatter?.steps, { '步骤-1安装': 1, '步骤-2验证': 2 });
    assert.ok(classesOf(checklist).includes('list-none'));
    const notes = findAll(tree, (node) => node.properties.role === 'note');
    assert.equal(notes.length, 3);
    assert.equal(notes[2]?.properties.ariaLabel, '检查点');
  });

  it('parses Chinese step headings, Run on labels, field tables, and Fumadocs element labels', () => {
    assert.deepEqual(parseStepHeading('步骤 2：安装 Tailscale'), { number: 2, prefix: '步骤 2：' });
    assert.deepEqual(parseStepHeading('阶段 1：准备新 VPS'), { number: 1, prefix: '阶段 1：' });
    assert.deepEqual(parseStepHeading('3. 验证连接'), { number: 3, prefix: '3. ' });

    assert.deepEqual(parseRunOn('运行位置：macOS'), { label: '运行位置：', target: 'macOS', icon: 'Laptop' });
    assert.deepEqual(parseRunOn('先运行于：VPS'), { label: '先运行于：', target: 'VPS', icon: 'Server' });
    assert.deepEqual(parseRunOn('接着运行于：macOS'), { label: '接着运行于：', target: 'macOS', icon: 'Laptop' });
    assert.deepEqual(parseRunOn('在另一会话中运行于：VPS'), { label: '在另一会话中运行于：', target: 'VPS', icon: 'Server' });
    assert.deepEqual(parseRunOn('在 iOS 上运行：'), { label: '运行位置：', target: 'iOS', icon: 'Smartphone' });

    const zhTable = h('table', {}, h('thead', {}, h('tr', {}, h('th', {}, '字段'), h('th', {}, '值'))));
    assert.equal(tableKind(zhTable), 'fields');

    const tree = root(
      h('h2', { id: '准备-host' }, '准备 Host'),
      h('pre', { class: 'shiki' }, h('code', {}, h('span', { className: ['line'] }, 'ls'))),
    );
    rehypeFumadocsElements()(tree, zhFile());
    const [heading, figure] = tree.children.filter(isElement);
    assert.ok(heading !== undefined && figure !== undefined);
    const anchorBtn = findAll(heading, byTag('button'))[0];
    assert.equal(anchorBtn?.properties.ariaLabel, '复制锚点链接');
    const copyBtn = findAll(figure, (node) => node.properties.dataCopyCode !== undefined)[0];
    assert.equal(copyBtn ? textOf(copyBtn) : '', '复制代码');
    const viewport = findAll(figure, (node) => node.properties.role === 'group')[0];
    assert.equal(viewport?.properties.ariaLabel, '代码');
  });
});
