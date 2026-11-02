// Markdown pipeline for the guides in docs/guides/.
//
// The guides are written for GitHub: no frontmatter, a leading `# Title`, links
// between `.md` files, and GitHub alert blockquotes. These plugins adapt them
// at build time so the files themselves stay untouched: links, title and lead,
// code block titles, and Fumadocs UI component markup (steps, callouts, code
// frames, heading anchors) for prose that follows the guides' conventions.
//
// Page content is static HTML that is never hydrated, so everything here is
// markup and classes; src/styles/content.css and src/scripts/content.ts add the
// styles and the delegated behaviour. Every class is written out in full so
// Tailwind finds it. Guide-only plugins skip `.mdx` files, where
// `defaultMdxComponents` renders the real components.
//
// The helpers are pure and covered by `pnpm test`; the plugins only walk trees
// and apply them.

import { posix, relative, sep } from 'node:path';
import type { Element, ElementContent, Literal, Root as HastRoot, RootContent, Text } from 'hast';
import type { Code, Html, Nodes as MdastNodes, Paragraph, Root as MdastRoot } from 'mdast';
import { githubRepo, guideImagesDir, guidesDir, type Locale, publishedGuides } from './guides.ts';

/** The parts of a vfile these plugins touch (Astro stores frontmatter under `data.astro`). */
interface MarkdownFile {
  path?: string;
  data: { astro?: { frontmatter?: Record<string, unknown> } };
}

const zhGuidePathPattern = /(?:^|\/)zh\/[^/]+\.md(?:x)?$/;

/** Locale of a Markdown file from its path (`zh` under a `zh/` directory, `en` otherwise). */
export function guideLocale(file?: Pick<MarkdownFile, 'path'>): Locale {
  const normalized = file?.path?.split(sep).join('/') ?? '';
  return zhGuidePathPattern.test(normalized) ? 'zh' : 'en';
}

/**
 * Raw HTML from the guides (`<a><img></a>`, `<details>`). remark-rehype passes
 * it through as `raw` nodes, and rehype-raw parses it only after every user
 * rehype plugin has run.
 */
interface Raw extends Literal {
  type: 'raw';
}

declare module 'hast' {
  // A key of our own: mdast-util-to-hast registers `raw` with its own type
  // whenever its declarations are part of the program.
  interface RootContentMap {
    guideRaw: Raw;
  }
  interface ElementContentMap {
    guideRaw: Raw;
  }
}

export interface GuidePluginOptions {
  /** Absolute path of the repository root. */
  repoRoot: string;
  /** Whether a repo-relative path is a directory (GitHub uses /tree/ for those). */
  isDirectory: (repoPath: string) => boolean;
}

// ---------------------------------------------------------------------------
// Links

const schemePattern = /^[a-z][a-z0-9+.-]*:/i;
const guidePattern = new RegExp(`^${guidesDir}/(?:(zh)/)?([^/]+)\\.md$`);

/**
 * Percent-encodes each path segment canonically: `my file` becomes `my%20file`
 * and an existing `%23` stays `%23`. `undefined` for a malformed escape.
 */
function encodePath(path: string): string | undefined {
  try {
    return path
      .split('/')
      .map((segment) => encodeURIComponent(decodeURIComponent(segment)))
      .join('/');
  } catch {
    return undefined;
  }
}

/** Inverse of `encodePath` for an already canonical path (cannot throw). */
function decodePath(path: string): string {
  return path.split('/').map(decodeURIComponent).join('/');
}

/**
 * Resolves a link written in a guide to its URL on the docs site.
 *
 * `sourcePath` is the guide's repo-relative path. Returns `undefined` when the
 * link must stay as written: absolute URLs, `mailto:`, in-page `#anchors`, and
 * paths that climb out of the repository. A `?query` survives only on GitHub
 * URLs (where `?plain=1` means something); site routes drop it.
 */
export function resolveGuideHref(
  href: string,
  sourcePath: string,
  isDirectory: GuidePluginOptions['isDirectory'],
): string | undefined {
  if (href === '' || href.startsWith('#') || href.startsWith('//') || schemePattern.test(href)) {
    return undefined;
  }

  const hashIndex = href.indexOf('#');
  const beforeHash = hashIndex === -1 ? href : href.slice(0, hashIndex);
  const fragment = hashIndex === -1 ? '' : href.slice(hashIndex);
  const queryIndex = beforeHash.indexOf('?');
  const pathPart = queryIndex === -1 ? beforeHash : beforeHash.slice(0, queryIndex);
  const query = queryIndex === -1 ? '' : beforeHash.slice(queryIndex);

  // Resolve on encoded segments so an escaped `/` (`%2F`) stays inside its segment.
  const encoded = encodePath(pathPart);
  const sourceDir = encodePath(posix.dirname(sourcePath));
  if (encoded === undefined || sourceDir === undefined) return undefined;

  // GitHub resolves a leading `/` against the repository root.
  const joined = encoded.startsWith('/') ? encoded.slice(1) : posix.join(sourceDir, encoded);
  const target = posix.normalize(joined).replace(/\/+$/, '');
  if (target === '..' || target.startsWith('../')) return undefined;
  const plainTarget = decodePath(target);

  const guideMatch = guidePattern.exec(plainTarget);
  const guideLocale = guideMatch?.[1];
  const guide = guideMatch?.[2];
  if (guide !== undefined && publishedGuides.includes(guide)) {
    return guideLocale ? `/${guideLocale}/${guide}${fragment}` : `/${guide}${fragment}`;
  }

  if (plainTarget.startsWith(`${guideImagesDir}/`)) {
    return `/images/${target.slice(guideImagesDir.length + 1)}`;
  }

  if (target === '.' || target === '') return `${githubRepo}${fragment}`;
  const kind = pathPart.endsWith('/') || isDirectory(plainTarget) ? 'tree' : 'blob';
  return `${githubRepo}/${kind}/main/${target}${query}${fragment}`;
}

/**
 * Rewrites `href`, `src`, and `srcset` attributes in a raw HTML fragment (the
 * guides embed `<a><img></a>`). `data-src` and similar attributes are left alone.
 */
export function rewriteHtmlLinks(html: string, rewrite: (href: string) => string | undefined): string {
  return html.replace(
    /(?<![\w-])(href|src|srcset)\s*=\s*(["'])(.*?)\2/gi,
    (match, attribute: string, quote: string, value: string) => {
      const next = attribute.toLowerCase() === 'srcset' ? rewriteSrcset(value, rewrite) : rewrite(value);
      return next === undefined ? match : `${attribute}=${quote}${next}${quote}`;
    },
  );
}

/** Rewrites the URL of each `url descriptor` candidate in a `srcset` value. */
function rewriteSrcset(value: string, rewrite: (href: string) => string | undefined): string {
  return value
    .split(',')
    .map((candidate) => {
      const [url = '', ...descriptors] = candidate.trim().split(/\s+/);
      return [rewrite(url) ?? url, ...descriptors].join(' ');
    })
    .join(', ');
}

/** Repo-relative POSIX path of a guide, or `undefined` for files outside docs/guides/. */
function guideSourcePath(file: MarkdownFile, repoRoot: string): string | undefined {
  if (typeof file.path !== 'string') return undefined;
  const repoPath = relative(repoRoot, file.path).split(sep).join('/');
  return repoPath.startsWith(`${guidesDir}/`) ? repoPath : undefined;
}

function walk(node: MdastNodes, visit: (node: MdastNodes) => void): void {
  visit(node);
  if ('children' in node) {
    for (const child of node.children) walk(child, visit);
  }
}

/** Remark plugin: points guide links at site routes, served images, or GitHub. */
export function remarkGuideLinks({ repoRoot, isDirectory }: GuidePluginOptions) {
  return (tree: MdastRoot, file: MarkdownFile) => {
    const sourcePath = guideSourcePath(file, repoRoot);
    if (sourcePath === undefined) return;
    const rewrite = (href: string) => resolveGuideHref(href, sourcePath, isDirectory);

    walk(tree, (node) => {
      if (node.type === 'link' || node.type === 'definition' || node.type === 'image') {
        node.url = rewrite(node.url) ?? node.url;
      } else if (node.type === 'html') {
        node.value = rewriteHtmlLinks(node.value, rewrite);
      }
    });
  };
}

// ---------------------------------------------------------------------------
// Screenshot loading and layout

/** Reserves a local screenshot's aspect ratio and defers its offscreen download. */
export function rehypeGuideImages(images: Record<string, { width: number; height: number }>) {
  const sizeImage = (properties: Element['properties']) => {
    const image = images[String(properties.src)];
    if (!image) return;
    const width = Number(properties.width) || (Number(properties.height) ? Math.round(Number(properties.height) * image.width / image.height) : image.width);
    properties.width ??= width;
    properties.height ??= Math.round(width * image.height / image.width);
    properties.loading ??= 'lazy';
    properties.decoding ??= 'async';
  };

  return (tree: HastRoot) => {
    const visit = (parent: HastParent) => {
      for (const child of parent.children) {
        if (child.type === 'element' && child.tagName === 'img') sizeImage(child.properties);
        if (child.type === 'raw') {
          // Raw guide HTML is parsed only after user rehype plugins. Preserve
          // its authored markup and add only missing image attributes.
          child.value = child.value.replace(/<img\b(?:[^"'<>]|"[^"]*"|'[^']*')*\/?>/gi, (tag) => {
            const properties: Element['properties'] = {};
            for (const [, name, , value] of tag.matchAll(/\s(src|width|height|loading|decoding)\s*=\s*(["'])(.*?)\2/gi)) {
              properties[name.toLowerCase()] = value;
            }
            const existing = new Set(Object.keys(properties));
            sizeImage(properties);
            const added = Object.entries(properties).filter(([name]) => !existing.has(name));
            return tag.replace(/\/?>(?=$)/, (end) => `${added.map(([name, value]) => ` ${name}="${value}"`).join('')}${end}`);
          });
        }
        if ('children' in child) visit(child);
      }
    };
    visit(tree);
  };
}

// ---------------------------------------------------------------------------
// Title and description

/** Plain text of a node: link and emphasis syntax drops away, code keeps its text. */
export function plainText(node: MdastNodes): string {
  if (node.type === 'text' || node.type === 'inlineCode') return node.value;
  if (node.type === 'break') return ' ';
  if ('children' in node) return node.children.map(plainText).join('');
  return '';
}

/** Collapses whitespace and trims to `max` characters on a word boundary. */
export function summarize(text: string, max = 160): string {
  const flat = text.replace(/\s+/g, ' ').trim();
  if (flat.length <= max) return flat;
  const cut = flat.slice(0, max - 1);
  const lastSpace = cut.lastIndexOf(' ');
  return `${(lastSpace > 0 ? cut.slice(0, lastSpace) : cut).replace(/[\s,.;:，。；：、]+$/, '')}…`;
}

/**
 * Drops a trailing lead-in sentence such as "The result is:" or "结果如下：",
 * which only makes sense next to the block it introduces. Text with no earlier
 * sentence is kept.
 */
export function dropLeadIn(text: string): string {
  const flat = text.replace(/\s+/g, ' ').trim();
  if (!flat.endsWith(':') && !flat.endsWith('：')) return flat;
  const englishEnd = Math.max(flat.lastIndexOf('. '), flat.lastIndexOf('! '), flat.lastIndexOf('? '));
  const chineseEnd = Math.max(flat.lastIndexOf('。'), flat.lastIndexOf('！'), flat.lastIndexOf('？'));
  const end = Math.max(englishEnd, chineseEnd);
  return end === -1 ? flat : flat.slice(0, end + 1);
}

/**
 * Takes the guide's leading `# Title` out of the tree and returns it with the
 * first prose paragraph after it. The page layout renders both.
 */
export function extractTitle(tree: MdastRoot): { title?: string; description?: string } {
  const index = tree.children.findIndex((node) => node.type === 'heading' && node.depth === 1);
  if (index === -1) return {};

  const [heading] = tree.children.splice(index, 1);
  const title = heading === undefined ? undefined : plainText(heading).trim();
  // Skip paragraphs with no text of their own, such as a lone screenshot.
  const prose = tree.children
    .slice(index)
    .filter((node) => node.type === 'paragraph')
    .map((node) => plainText(node).trim())
    .find((text) => text !== '');
  const description = prose === undefined ? undefined : summarize(dropLeadIn(prose));
  return { title, description };
}

/** Raw HTML nodes at any depth (the guides' embedded `<a><img></a>` screenshots, `<details>`). */
export function htmlNodes(node: MdastNodes): Html[] {
  if (node.type === 'html') return [node];
  return 'children' in node ? node.children.flatMap(htmlNodes) : [];
}

/**
 * Remark plugin: moves a guide's H1 and lead paragraph into frontmatter, where
 * Astro exposes them as `entry.rendered.metadata.frontmatter`. Runs after
 * heading ids are assigned, so the remaining ids match GitHub's.
 */
export function remarkGuideTitle({ repoRoot }: Pick<GuidePluginOptions, 'repoRoot'>) {
  return (tree: MdastRoot, file: MarkdownFile) => {
    if (guideSourcePath(file, repoRoot) === undefined) return;
    const { title, description } = extractTitle(tree);
    file.data.astro ??= {};
    const frontmatter = (file.data.astro.frontmatter ??= {});
    if (title) frontmatter.title ??= title;
    if (description) frontmatter.description ??= description;
  };
}

// ---------------------------------------------------------------------------
// Trailers: review metadata and the maintainers note

/** How many closing blocks may hold trailers. */
const trailerWindow = 3;
const metadataPattern =
  /^(?:Last checked on |Checked against |Commands (?:and console labels )?were checked |最后核对于|核对依据为|已对照|(?:命令(?:与控制台标签)?已(?:对照|核对于)))/;
const maintainersPattern = /^(?:Maintainers: |维护者[：:]\s*)/;

/**
 * Classifies a guide's closing paragraph: `metadata` for "Last checked on …",
 * "Checked against …", "Commands were checked …", "Commands and console labels
 * were checked …", or their Chinese equivalents ("最后核对于 …", "核对依据为 …",
 * "已对照 …", "命令已核对于 …", "命令与控制台标签已核对于 …"); `maintainers` for
 * "Maintainers: …" or "维护者：…"; otherwise `undefined`.
 */
export function trailerKind(text: string): 'metadata' | 'maintainers' | undefined {
  const flat = text.replace(/\s+/g, ' ').trim();
  if (metadataPattern.test(flat)) return 'metadata';
  return maintainersPattern.test(flat) ? 'maintainers' : undefined;
}

/**
 * The trailer paragraphs among the guide's last three blocks, which the search
 * index leaves out like the page does. Blank each one with
 * `replaceSource(file, node, '', 'search')`.
 */
export function hiddenForSearch(tree: MdastRoot): Paragraph[] {
  return tree.children
    .slice(-trailerWindow)
    .filter((node): node is Paragraph => node.type === 'paragraph' && trailerKind(plainText(node)) !== undefined);
}

// ---------------------------------------------------------------------------
// Code block titles

/** A title for rehypeCode, and whether the block is sample output with no copy button. */
export interface CodeBlockTitle {
  title: string;
  noCopy: boolean;
}

const shellLanguages = new Set(['sh', 'bash', 'zsh', 'shell', 'console']);
const powerShellLanguages = new Set(['powershell', 'ps1', 'pwsh']);
const textLanguages = new Set(['', 'text', 'txt', 'plaintext']);
const expectedLeadIn =
  /(?:Expected:|Expected state:|must show:|The required result is:|(?:预期|预期输出|预期状态|应显示|必须显示|所需结果为)[：:])$/;
const forbiddenLeadIn = /(?:must not show:|(?:不应显示|不得显示)[：:])$/;
const configPathPattern = /^(?:~|\/)\S+$/;
const plistPathPattern = /^\S+\.plist$/;

/**
 * Title for a guide code block, from its language and the blocks before it
 * (`previous`, nearest first): shells get "Terminal" ("终端" in Chinese),
 * PowerShell "PowerShell", SSH config the file named in the lead-in paragraph
 * (or "SSH config" / "SSH 配置"), XML the `.plist` file named just before it,
 * and text after "Expected:", "Expected state:", "must show:", "The required
 * result is:", or their Chinese equivalents ("预期：", "预期输出：", "预期状态：",
 * "应显示：", "必须显示：", "所需结果为：") is "Expected output" ("预期输出" in
 * Chinese; after "must not show:" or "不应显示：" / "不得显示：", "Must not appear"
 * / "不应出现") with no copy button. A fence with its own meta keeps it.
 */
export function codeBlockTitle(
  code: Code,
  previous: readonly (MdastNodes | undefined)[],
  locale: Locale = 'en',
): CodeBlockTitle | undefined {
  if (code.meta) return undefined;
  const lang = code.lang?.toLowerCase() ?? '';
  const [before, earlier] = previous;
  const leadIn = before?.type === 'paragraph' ? before : undefined;
  const isZh = locale === 'zh';

  if (shellLanguages.has(lang)) return { title: isZh ? '终端' : 'Terminal', noCopy: false };
  if (powerShellLanguages.has(lang)) return { title: 'PowerShell', noCopy: false };
  if (lang === 'sshconfig' || lang === 'ssh-config') {
    return { title: configPath(leadIn) ?? (isZh ? 'SSH 配置' : 'SSH config'), noCopy: false };
  }
  if (lang === 'xml') return { title: plistName(before, earlier) ?? 'XML', noCopy: false };
  if (textLanguages.has(lang) && leadIn !== undefined) {
    const sentence = plainText(leadIn).replace(/\s+/g, ' ').trim();
    if (forbiddenLeadIn.test(sentence)) return { title: isZh ? '不应出现' : 'Must not appear', noCopy: true };
    if (expectedLeadIn.test(sentence)) return { title: isZh ? '预期输出' : 'Expected output', noCopy: true };
  }
  return undefined;
}

/** The single path-like inline code in a lead-in such as "Add this block to `~/.ssh/config`:". */
function configPath(leadIn: Paragraph | undefined): string | undefined {
  const paths = (leadIn?.children ?? []).flatMap((node) =>
    node.type === 'inlineCode' && configPathPattern.test(node.value) ? [node.value] : [],
  );
  return paths.length === 1 ? paths[0] : undefined;
}

/** File name of a one-line text block naming a `.plist`, such as the "Create:" block before a template. */
function plistName(...candidates: (MdastNodes | undefined)[]): string | undefined {
  for (const node of candidates) {
    if (node?.type !== 'code' || !textLanguages.has(node.lang?.toLowerCase() ?? '')) continue;
    const value = node.value.trim();
    if (plistPathPattern.test(value)) return posix.basename(value);
  }
  return undefined;
}

/** rehypeCode meta string for a title: `title="Terminal"`, plus `noCopy` for sample output. */
export function codeMeta({ title, noCopy }: CodeBlockTitle): string | undefined {
  if (title.includes('"')) return undefined;
  return noCopy ? `title="${title}" noCopy` : `title="${title}"`;
}

/**
 * Remark plugin: titles guide code blocks (see `codeBlockTitle`) through the
 * meta string rehypeCode reads, and maps the guides' `sshconfig` fences (the
 * name GitHub knows) to Shiki's `ssh-config`.
 */
export function remarkGuideCode() {
  return (tree: MdastRoot, file: Pick<MarkdownFile, 'path'>) => {
    if (file.path?.endsWith('.mdx')) return;
    const locale = guideLocale(file);
    walk(tree, (node) => {
      if (!('children' in node)) return;
      const children: MdastNodes[] = node.children;
      children.forEach((child, index) => {
        if (child.type !== 'code') return;
        const title = codeBlockTitle(child, [children[index - 1], children[index - 2]], locale);
        const meta = title === undefined ? undefined : codeMeta(title);
        if (meta !== undefined) child.meta = meta;
        if (child.lang === 'sshconfig') child.lang = 'ssh-config';
      });
    });
  };
}

// ---------------------------------------------------------------------------
// hast helpers

/** Anything with hast children: a root, an element, or a nested root left by rehypeCode. */
type HastParent = { children: RootContent[] };

function element(tagName: string, properties: Element['properties'], children: ElementContent[] = []): Element {
  return { type: 'element', tagName, properties, children };
}

function text(value: string): Text {
  return { type: 'text', value };
}

/** Text content of a node; raw HTML and comments contribute nothing. */
function hastText(node: RootContent | HastRoot): string {
  if (node.type === 'text') return node.value;
  return 'children' in node ? node.children.map(hastText).join('') : '';
}

function isElement(node: RootContent | undefined, ...tagNames: string[]): node is Element {
  return node?.type === 'element' && (tagNames.length === 0 || tagNames.includes(node.tagName));
}

/** The line breaks remark-rehype puts between blocks. */
function isWhitespace(node: RootContent): boolean {
  return node.type === 'text' && node.value.trim() === '';
}

/** Level of an `<h1>`–`<h6>` element, otherwise `undefined`. */
function headingLevel(node: RootContent | undefined): number | undefined {
  if (node?.type !== 'element') return undefined;
  const level = /^h([1-6])$/.exec(node.tagName)?.[1];
  return level === undefined ? undefined : Number(level);
}

/** Index of the first node at or after `start` that is not a line break, or -1. */
function nextBlockIndex(nodes: readonly RootContent[], start: number): number {
  for (let index = Math.max(start, 0); index < nodes.length; index++) {
    const node = nodes[index];
    if (node !== undefined && !isWhitespace(node)) return index;
  }
  return -1;
}

/** Removes `node` and the line break after it (or before it, at the end). */
function removeChild(parent: HastParent, node: RootContent): void {
  const index = parent.children.indexOf(node);
  if (index === -1) return;
  const after = parent.children[index + 1];
  const before = parent.children[index - 1];
  if (after !== undefined && isWhitespace(after)) parent.children.splice(index, 2);
  else if (before !== undefined && isWhitespace(before)) parent.children.splice(index - 1, 2);
  else parent.children.splice(index, 1);
}

/**
 * Replaces elements below `parent`, depth first. `replace` returns the new
 * element, which is not visited further, or `undefined` to keep the element
 * and descend into it. Code blocks are never entered.
 */
function mapElements(
  parent: HastParent,
  replace: (node: Element, ancestors: readonly Element[]) => Element | undefined,
  ancestors: readonly Element[] = [],
): void {
  parent.children = parent.children.map((child) => {
    if (child.type !== 'element') return child;
    const next = replace(child, ancestors);
    if (next !== undefined) return next;
    if (child.tagName !== 'pre') mapElements(child, replace, [...ancestors, child]);
    return child;
  });
}

/** Class names of an element; Shiki sets `class` as a string rather than hast's `className`. */
function classList(node: Element): string[] {
  const value = node.properties.className ?? node.properties.class;
  if (Array.isArray(value)) return value.map(String);
  return typeof value === 'string' ? value.split(/\s+/).filter(Boolean) : [];
}

function addClasses(node: Element, classes: readonly string[]): void {
  const { class: _class, ...properties } = node.properties;
  node.properties = { ...properties, className: [...classList(node), ...classes] };
}

/** Drops the doctype a root may hold, which cannot go inside an element. */
function elementContent(nodes: readonly RootContent[]): ElementContent[] {
  return nodes.filter((node): node is ElementContent => node.type !== 'doctype');
}

// ---------------------------------------------------------------------------
// Icons

type IconName =
  | 'CalendarCheck'
  | 'Check'
  | 'ChevronRight'
  | 'CircleCheck'
  | 'CircleX'
  | 'Clipboard'
  | 'CopyCheck'
  | 'FileCode'
  | 'Info'
  | 'Laptop'
  | 'Lightbulb'
  | 'Link'
  | 'MapPin'
  | 'MessageSquareWarning'
  | 'OctagonAlert'
  | 'Server'
  | 'Smartphone'
  | 'Terminal'
  | 'TriangleAlert';

type IconShape = readonly [tag: 'circle' | 'line' | 'path' | 'rect', attributes: Readonly<Record<string, string>>];

/** Shapes of the Lucide icons used here, copied from lucide-react 1.55.0 (24x24 viewBox). */
const icons: Record<IconName, readonly IconShape[]> = {
  CalendarCheck: [
    ['path', { d: 'M8 2v3' }],
    ['path', { d: 'M16 2v3' }],
    ['rect', { x: '3', y: '3', width: '18', height: '18', rx: '2' }],
    ['path', { d: 'M3 9h18' }],
    ['path', { d: 'm9 15 2 2 4-4' }],
  ],
  Check: [['path', { d: 'M20 6 9 17l-5-5' }]],
  ChevronRight: [['path', { d: 'm9 18 6-6-6-6' }]],
  CircleCheck: [
    ['circle', { cx: '12', cy: '12', r: '10' }],
    ['path', { d: 'm16 9-5.5 5.5L8 12' }],
  ],
  CircleX: [
    ['circle', { cx: '12', cy: '12', r: '10' }],
    ['path', { d: 'm15 9-6 6' }],
    ['path', { d: 'm9 9 6 6' }],
  ],
  Clipboard: [
    ['rect', { width: '8', height: '4', x: '8', y: '2', rx: '1', ry: '1' }],
    ['path', { d: 'M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2' }],
  ],
  CopyCheck: [
    ['path', { d: 'm12 15 2 2 4-4' }],
    ['rect', { width: '14', height: '14', x: '8', y: '8', rx: '2', ry: '2' }],
    ['path', { d: 'M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2' }],
  ],
  FileCode: [
    [
      'path',
      { d: 'M6 22a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h8a2.4 2.4 0 0 1 1.704.706l3.588 3.588A2.4 2.4 0 0 1 20 8v12a2 2 0 0 1-2 2z' },
    ],
    ['path', { d: 'M14 2v5a1 1 0 0 0 1 1h5' }],
    ['path', { d: 'M10 12.5 8 15l2 2.5' }],
    ['path', { d: 'm14 12.5 2 2.5-2 2.5' }],
  ],
  Info: [
    ['circle', { cx: '12', cy: '12', r: '10' }],
    ['path', { d: 'M12 16v-4' }],
    ['path', { d: 'M12 8h.01' }],
  ],
  Laptop: [
    [
      'path',
      {
        d: 'M18 5a2 2 0 0 1 2 2v8.526a2 2 0 0 0 .212.897l1.068 2.127a1 1 0 0 1-.9 1.45H3.62a1 1 0 0 1-.9-1.45l1.068-2.127A2 2 0 0 0 4 15.526V7a2 2 0 0 1 2-2z',
      },
    ],
    ['path', { d: 'M20.054 15.987H3.946' }],
  ],
  Lightbulb: [
    ['path', { d: 'M15 14c.2-1 .7-1.7 1.5-2.5 1-.9 1.5-2.2 1.5-3.5A6 6 0 0 0 6 8c0 1 .2 2.2 1.5 3.5.7.7 1.3 1.5 1.5 2.5' }],
    ['path', { d: 'M9 18h6' }],
    ['path', { d: 'M10 22h4' }],
  ],
  Link: [
    ['path', { d: 'M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71' }],
    ['path', { d: 'M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71' }],
  ],
  MapPin: [
    ['path', { d: 'M20 10c0 4.993-5.539 10.193-7.399 11.799a1 1 0 0 1-1.202 0C9.539 20.193 4 14.993 4 10a8 8 0 0 1 16 0' }],
    ['circle', { cx: '12', cy: '10', r: '3' }],
  ],
  MessageSquareWarning: [
    [
      'path',
      { d: 'M22 17a2 2 0 0 1-2 2H6.828a2 2 0 0 0-1.414.586l-2.202 2.202A.71.71 0 0 1 2 21.286V5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2z' },
    ],
    ['path', { d: 'M12 15h.01' }],
    ['path', { d: 'M12 7v4' }],
  ],
  OctagonAlert: [
    ['path', { d: 'M12 16h.01' }],
    ['path', { d: 'M12 8v4' }],
    [
      'path',
      {
        d: 'M15.312 2a2 2 0 0 1 1.414.586l4.688 4.688A2 2 0 0 1 22 8.688v6.624a2 2 0 0 1-.586 1.414l-4.688 4.688a2 2 0 0 1-1.414.586H8.688a2 2 0 0 1-1.414-.586l-4.688-4.688A2 2 0 0 1 2 15.312V8.688a2 2 0 0 1 .586-1.414l4.688-4.688A2 2 0 0 1 8.688 2z',
      },
    ],
  ],
  Server: [
    ['rect', { width: '20', height: '8', x: '2', y: '2', rx: '2', ry: '2' }],
    ['rect', { width: '20', height: '8', x: '2', y: '14', rx: '2', ry: '2' }],
    ['line', { x1: '6', x2: '6.01', y1: '6', y2: '6' }],
    ['line', { x1: '6', x2: '6.01', y1: '18', y2: '18' }],
  ],
  Smartphone: [
    ['rect', { width: '14', height: '20', x: '5', y: '2', rx: '2', ry: '2' }],
    ['path', { d: 'M12 18h.01' }],
  ],
  Terminal: [
    ['path', { d: 'M12 19h8' }],
    ['path', { d: 'm4 17 6-6-6-6' }],
  ],
  TriangleAlert: [
    ['path', { d: 'm21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3' }],
    ['path', { d: 'M12 9v4' }],
    ['path', { d: 'M12 17h.01' }],
  ],
};

/** A Lucide icon as inline SVG (stroked, hidden from assistive technology). */
function lucideIcon(name: IconName, className: string[]): Element {
  return element(
    'svg',
    {
      xmlns: 'http://www.w3.org/2000/svg',
      viewBox: '0 0 24 24',
      fill: 'none',
      stroke: 'currentColor',
      strokeWidth: '2',
      strokeLinecap: 'round',
      strokeLinejoin: 'round',
      ariaHidden: 'true',
      className,
    },
    icons[name].map(([tag, attributes]) => element(tag, { ...attributes })),
  );
}

// ---------------------------------------------------------------------------
// Callouts

type CalloutType = 'info' | 'idea' | 'success' | 'warning' | 'error';

interface CalloutOptions {
  type: CalloutType;
  icon: IconName;
  /** Bold first line; omitted for callouts whose body speaks for itself. */
  title?: string;
}

/** The markup and classes of Fumadocs UI's <Callout>, around `body`. */
function callout({ type, icon, title }: CalloutOptions, body: ElementContent[]): Element {
  // Like <Callout>'s icons: filled with the callout colour and stroked in the
  // card colour, except the lightbulb, which strokes in colour.
  const stroke = type === 'idea' ? 'text-(--callout-color)' : 'text-fd-card';
  return element(
    'div',
    {
      className: 'flex gap-2 my-4 rounded-xl border bg-fd-card p-3 ps-1 text-sm text-fd-card-foreground'.split(' '),
      style: `--callout-color: var(--color-fd-${type}, var(--color-fd-muted))`,
      role: 'note',
      ...(title === undefined ? {} : { ariaLabel: title }),
    },
    [
      element('div', { role: 'none', className: ['w-0.5', 'bg-(--callout-color)/50', 'rounded-sm'] }),
      lucideIcon(icon, ['size-5', '-me-0.5', 'shrink-0', 'fill-(--callout-color)', stroke]),
      element('div', { className: ['flex', 'flex-col', 'gap-2', 'min-w-0', 'flex-1'] }, [
        ...(title === undefined ? [] : [element('p', { className: ['font-medium', 'my-0!'] }, [text(title)])]),
        element('div', { className: ['text-fd-muted-foreground', 'prose-no-margin', 'empty:hidden'] }, body),
      ]),
    ],
  );
}

// ---------------------------------------------------------------------------
// GitHub alerts

type AlertKind = 'NOTE' | 'TIP' | 'IMPORTANT' | 'WARNING' | 'CAUTION';

/** Fumadocs callout type, localized label, and Lucide icon for each alert. */
const alerts: Record<AlertKind, { type: CalloutType; label: Record<Locale, string>; icon: IconName }> = {
  NOTE: { type: 'info', label: { en: 'Note', zh: '注意' }, icon: 'Info' },
  TIP: { type: 'idea', label: { en: 'Tip', zh: '提示' }, icon: 'Lightbulb' },
  IMPORTANT: { type: 'info', label: { en: 'Important', zh: '重要' }, icon: 'MessageSquareWarning' },
  WARNING: { type: 'warning', label: { en: 'Warning', zh: '警告' }, icon: 'TriangleAlert' },
  CAUTION: { type: 'error', label: { en: 'Caution', zh: '危险' }, icon: 'OctagonAlert' },
};

const alertPattern = /^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\][^\S\n]*(?:\n|$)/i;

/** Returns the alert kind and the text after the marker, if `text` opens a GitHub alert. */
export function parseAlertMarker(text: string): { kind: AlertKind; rest: string } | undefined {
  const match = alertPattern.exec(text);
  const kind = match?.[1]?.toUpperCase();
  if (match === null || kind === undefined || !(kind in alerts)) return undefined;
  return { kind: kind as AlertKind, rest: text.slice(match[0].length) };
}

/**
 * Rehype plugin: renders `> [!NOTE]`-style blockquotes with the markup and
 * classes of Fumadocs UI's <Callout>, since plain Markdown cannot use the
 * React component.
 */
export function rehypeGithubAlerts() {
  return (tree: HastRoot, file?: Pick<MarkdownFile, 'path'>) => {
    const locale = guideLocale(file);
    const visit = (parent: HastRoot | Element) => {
      parent.children = parent.children.map((child) => {
        if (child.type !== 'element') return child;
        const alert = child.tagName === 'blockquote' ? toCallout(child, locale) : undefined;
        if (alert) return alert;
        visit(child);
        return child;
      });
    };
    visit(tree);
  };
}

function toCallout(blockquote: Element, locale: Locale): Element | undefined {
  const paragraph = blockquote.children.find((child): child is Element => child.type === 'element');
  const first = paragraph?.tagName === 'p' ? paragraph.children[0] : undefined;
  if (paragraph === undefined || first?.type !== 'text') return undefined;
  const marker = parseAlertMarker(first.value);
  if (marker === undefined) return undefined;

  first.value = marker.rest;
  const body = blockquote.children.filter((child) => {
    if (child !== paragraph) return true;
    return paragraph.children.some((node) => node.type !== 'text' || node.value.trim() !== '');
  });

  const { type, label, icon } = alerts[marker.kind];
  return callout({ type, icon, title: label[locale] }, body);
}

// ---------------------------------------------------------------------------
// Guide components

/**
 * Rehype plugin: turns the guides' prose conventions (both English and
 * Chinese) into Fumadocs UI component markup. Runs before rehypeCode, while
 * code blocks are plain <pre>.
 *
 * - Review metadata closing a guide ("Last checked on …" / "最后核对于 …", etc.)
 *   becomes a muted footer line; the maintainers note ("Maintainers: …" /
 *   "维护者：…") is removed (`hiddenForSearch` does the same for search).
 * - A short first paragraph moves to `frontmatter.lead` for the page header
 *   (skipping any leading HTML comment such as the translation sync marker).
 * - "You need …" / "你需要 …" before the first section, "**It worked if** …" /
 *   "**成功的标志是** …", and "Checkpoint:" / "检查点：" with the blocks after
 *   it become callouts.
 * - The list after "Before you start" / "Prerequisites" ("开始之前" / "准备工作"
 *   / "前置条件") becomes a checklist.
 * - Runs of numbered headings ("1. …", "Step 1: …", "Phase 1: …", "步骤 1：…",
 *   "阶段 1：…") become <Steps>; `frontmatter.steps` maps each step heading's
 *   id to its number.
 * - "**Run on: …**" / "**运行位置：…**" labels become badges, key combinations
 *   <kbd>, and menu paths ("Settings > General") get chevrons.
 *
 * Heading ids and heading text stay exactly as they were.
 */
export function rehypeGuideComponents() {
  return (tree: HastRoot, file: MarkdownFile) => {
    if (file.path?.endsWith('.mdx')) return;
    const locale = guideLocale(file);
    file.data.astro ??= {};
    const frontmatter = (file.data.astro.frontmatter ??= {});

    const footer = formatTrailers(tree);
    const lead = extractLead(tree);
    if (lead !== undefined) frontmatter.lead = lead;
    addRequirementCallouts(tree);
    addSuccessCallouts(tree, footer, locale);
    addChecklists(tree);
    frontmatter.steps = groupSteps(tree, footer);
    mapElements(tree, (node) => (node.tagName === 'p' ? toRunOnBadge(node) : undefined));
    mapElements(tree, polishInline);
    addMenuPathSeparators(tree);
  };
}

/**
 * Restyles review metadata among the last blocks as a footer line and removes
 * the maintainers note. Returns the footer lines, where steps must end.
 */
function formatTrailers(tree: HastRoot): Set<RootContent> {
  const footer = new Set<RootContent>();
  const tail = tree.children.filter((node) => !isWhitespace(node)).slice(-trailerWindow);
  for (const node of tail) {
    if (!isElement(node, 'p')) continue;
    const kind = trailerKind(hastText(node));
    if (kind === 'maintainers') removeChild(tree, node);
    if (kind !== 'metadata') continue;
    node.properties = {
      className:
        'not-prose mt-10 flex items-start gap-1.5 border-t pt-4 text-sm text-fd-muted-foreground [&_a]:font-medium [&_a]:text-fd-foreground [&_a]:underline [&_a]:decoration-fd-primary [&_a]:decoration-[1.5px] [&_a]:underline-offset-[3.5px]'.split(
          ' ',
        ),
    };
    // One flex item for the text, so links stay inline.
    node.children = [lucideIcon('CalendarCheck', ['mt-0.5', 'size-4', 'shrink-0']), element('span', {}, node.children)];
    footer.add(node);
  }
  return footer;
}

const leadMaxLength = 320;

/**
 * HTML for the page header when `paragraph` can serve as the guide's lead:
 * at most 320 characters of plain phrasing content (see `phrasingHtml`), and
 * not a lead-in ending in a colon, which belongs next to its block.
 */
export function leadHtml(paragraph: Element): string | undefined {
  if (paragraph.tagName !== 'p') return undefined;
  const flat = hastText(paragraph).replace(/\s+/g, ' ').trim();
  if (flat === '' || flat.length > leadMaxLength || flat.endsWith(':') || flat.endsWith('：')) return undefined;
  return phrasingHtml(paragraph.children);
}

/** Whether a node is a standalone HTML comment (such as the top translation sync marker). */
function isHtmlComment(node: RootContent): boolean {
  return node.type === 'comment' || (node.type === 'raw' && /^<!--[\s\S]*-->$/.test(node.value.trim()));
}

/** Moves the opening paragraph out of the body when it can serve as the lead. */
function extractLead(tree: HastRoot): string | undefined {
  const first = tree.children.find((node) => !isWhitespace(node) && !isHtmlComment(node));
  if (!isElement(first, 'p')) return undefined;
  const html = leadHtml(first);
  if (html !== undefined) removeChild(tree, first);
  return html;
}

const phrasingTags = new Set(['a', 'br', 'code', 'del', 'em', 'span', 'strong']);
const safeSchemes = new Set(['http', 'https', 'mailto']);

/**
 * Serializes inline content to HTML when it is plain phrasing: text, strong,
 * em, code, del, br, links (href and title only; http, https, mailto, or
 * relative), and spans (class only). Anything else, raw HTML included, gives
 * `undefined`. Text and attribute values are escaped.
 */
export function phrasingHtml(nodes: readonly ElementContent[]): string | undefined {
  let html = '';
  for (const node of nodes) {
    if (node.type === 'text') {
      // Source line breaks are spaces in HTML; keep the string on one line.
      html += escapeHtml(node.value.replace(/[ \t]*\n[ \t]*/g, ' '));
      continue;
    }
    if (node.type !== 'element' || !phrasingTags.has(node.tagName)) return undefined;
    const attributes = phrasingAttributes(node);
    if (attributes === undefined) return undefined;
    if (node.tagName === 'br') {
      if (node.children.length > 0) return undefined;
      html += '<br>';
      continue;
    }
    const inner = phrasingHtml(node.children);
    if (inner === undefined) return undefined;
    html += `<${node.tagName}${attributes}>${inner}</${node.tagName}>`;
  }
  return html;
}

function phrasingAttributes(node: Element): string | undefined {
  let html = '';
  for (const [name, value] of Object.entries(node.properties)) {
    if (value === undefined || value === null) continue;
    if (node.tagName === 'a' && (name === 'href' || name === 'title') && typeof value === 'string') {
      if (name === 'href' && !isSafeHref(value)) return undefined;
      html += ` ${name}="${escapeAttribute(value)}"`;
    } else if (node.tagName === 'span' && name === 'className' && Array.isArray(value)) {
      html += ` class="${escapeAttribute(value.join(' '))}"`;
    } else {
      return undefined;
    }
  }
  return html;
}

function isSafeHref(href: string): boolean {
  // Browsers ignore control characters and spaces inside a scheme ("java\tscript:").
  const scheme = /^([a-z][a-z0-9+.-]*):/i.exec(href.replace(/[\u0000- \u007f]+/g, ''))?.[1];
  return scheme === undefined || safeSchemes.has(scheme.toLowerCase());
}

function escapeHtml(value: string): string {
  return value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function escapeAttribute(value: string): string {
  return escapeHtml(value).replace(/"/g, '&quot;');
}

/** "You need …" or "你需要…" paragraphs before the first section become info callouts. */
function addRequirementCallouts(tree: HastRoot): void {
  for (const [index, node] of tree.children.entries()) {
    if (isElement(node, 'h2')) return;
    if (!isElement(node, 'p')) continue;
    const leading = hastText(node).trimStart();
    if (leading.startsWith('You need ') || leading.startsWith('你需要')) {
      tree.children[index] = callout({ type: 'info', icon: 'Info' }, [node]);
    }
  }
}

/**
 * "**It worked if** …" / "**成功的标志是** …" paragraphs become success
 * callouts, and a paragraph reading "Checkpoint:" / "检查点：" becomes the
 * title of a success callout around the blocks after it (see `checkpointEnd`),
 * such as a command and the sentence saying what it must print.
 */
function addSuccessCallouts(parent: HastParent, stops: ReadonlySet<RootContent>, locale: Locale): void {
  const { children } = parent;
  const checkpointTitle = locale === 'zh' ? '检查点' : 'Checkpoint';
  for (let index = 0; index < children.length; index++) {
    const node = children[index];
    if (node?.type !== 'element' || node.tagName === 'pre') continue;
    if (isSuccessCheck(node)) {
      children[index] = callout({ type: 'success', icon: 'CircleCheck' }, [node]);
    } else if (isCheckpoint(node)) {
      const start = nextBlockIndex(children, index + 1);
      const end = checkpointEnd(children, index + 1, stops);
      const body = start === -1 ? [] : children.slice(start, end);
      // A callout must not split raw HTML such as <details> … </details>.
      if (body.length > 0 && rawTagsBalanced(body)) {
        const checkpoint = callout({ type: 'success', icon: 'CircleCheck', title: checkpointTitle }, elementContent(body));
        children.splice(index, end - index, checkpoint);
      }
    } else {
      addSuccessCallouts(node, stops, locale);
    }
  }
}

const successCheckLabels = new Set(['It worked if', '成功的标志是']);

function isSuccessCheck(node: Element): boolean {
  const first = node.children[0];
  return node.tagName === 'p' && isElement(first, 'strong') && successCheckLabels.has(hastText(first).trim());
}

const checkpointLabels = new Set(['Checkpoint:', '检查点：', '检查点:']);

function isCheckpoint(node: RootContent): boolean {
  return isElement(node, 'p') && checkpointLabels.has(hastText(node).trim());
}

/**
 * End (exclusive) of the blocks a checkpoint holds, starting at `start`: every
 * sibling up to the next heading, thematic break, callout, or checkpoint, and
 * never a node in `stops` (the closing review metadata). Line breaks after the
 * last block stay outside.
 */
function checkpointEnd(children: readonly RootContent[], start: number, stops: ReadonlySet<RootContent>): number {
  let end = start;
  for (let index = start; index < children.length; index++) {
    const node = children[index];
    if (node === undefined || stops.has(node) || endsCheckpoint(node)) break;
    if (!isWhitespace(node)) end = index + 1;
  }
  return end;
}

function endsCheckpoint(node: RootContent): boolean {
  if (node.type !== 'element') return false;
  return headingLevel(node) !== undefined || node.tagName === 'hr' || node.properties.role === 'note' || isCheckpoint(node);
}

const checklistSections = new Set(['before-you-start', 'prerequisites', '开始之前', '准备工作', '前置条件']);

/** The list right after "Before you start" / "Prerequisites" ("开始之前" / "准备工作" / "前置条件", one paragraph may come first) becomes a checklist. */
function addChecklists(tree: HastRoot): void {
  const { children } = tree;
  children.forEach((node, index) => {
    if (!isElement(node, 'h2') || !checklistSections.has(String(node.properties.id))) return;
    const first = nextBlockIndex(children, index + 1);
    if (first === -1) return;
    const list = children[isElement(children[first], 'p') ? nextBlockIndex(children, first + 1) : first];
    if (isElement(list, 'ul') && !classList(list).includes('contains-task-list')) toChecklist(list);
  });
}

function toChecklist(list: Element): void {
  addClasses(list, ['list-none', 'rounded-xl', 'border', 'bg-fd-card', 'p-4']);
  for (const item of list.children) {
    if (!isElement(item, 'li')) continue;
    addClasses(item, ['relative', 'ps-7', 'first:mt-0', 'last:mb-0']);
    item.children.unshift(lucideIcon('CircleCheck', ['absolute', 'inset-s-0', 'top-1.5', 'size-4', 'text-fd-primary']));
  }
}

// ---------------------------------------------------------------------------
// Steps

const stepPattern = /^(?:(?:(?:Step|Phase)\s+)?(\d+)[.:]\s+|(?:步骤|阶段)\s*(\d+)(?:[.:]\s+|：\s*))(?=\S)/;

/**
 * Number and prefix of a step heading: "2. Install Tailscale" gives 2 and
 * "2. "; "Step 2: Install" gives 2 and "Step 2: "; "Phase 2: Move" gives 2
 * and "Phase 2: "; "步骤 2：安装" gives 2 and "步骤 2："; "阶段 2：迁移" gives
 * 2 and "阶段 2：". `undefined` for other headings.
 */
export function parseStepHeading(text: string): { number: number; prefix: string } | undefined {
  const match = stepPattern.exec(text);
  const number = match?.[1] ?? match?.[2];
  return match === null || number === undefined ? undefined : { number: Number(number), prefix: match[0] };
}

interface Step {
  heading: Element;
  number: number;
  prefix: string;
  /** Range of root children the step holds, heading included. */
  start: number;
  end: number;
}

/**
 * Wraps each run of numbered headings, h2 or h3 numbered 1, 2, … n with
 * n ≥ 2, in fumadocs' Steps markup (`div.fd-steps > div.fd-step`). A step
 * holds its heading and everything up to the next heading of the same or a
 * higher level, deeper headings included; a run also ends at any node in
 * `stops`. The number prefix stays in the heading text, for screen readers
 * and the table of contents, inside an `sr-only` span; the step circle shows
 * the number instead. Returns the step number of each step heading id.
 */
export function groupSteps(tree: HastRoot, stops: ReadonlySet<RootContent> = new Set()): Record<string, number> {
  const numbers: Record<string, number> = {};
  const output: RootContent[] = [];
  const { children } = tree;
  let index = 0;
  while (index < children.length) {
    const run = stepRun(children, index, stops);
    const last = run?.at(-1);
    if (run === undefined || last === undefined) {
      const node = children[index];
      if (node !== undefined) output.push(node);
      index++;
      continue;
    }
    const steps = run.map((step) => {
      hidePrefix(step.heading, step.prefix);
      const id = step.heading.properties.id;
      if (typeof id === 'string') numbers[id] = step.number;
      return element('div', { className: ['fd-step'] }, elementContent(children.slice(step.start, step.end)));
    });
    output.push(element('div', { className: ['fd-steps'] }, steps));
    index = last.end;
  }
  tree.children = output;
  return numbers;
}

/** The run of steps whose first heading is `children[start]`, if there is one. */
function stepRun(children: readonly RootContent[], start: number, stops: ReadonlySet<RootContent>): Step[] | undefined {
  const level = headingLevel(children[start]);
  if (level !== 2 && level !== 3) return undefined;

  const run: Step[] = [];
  let index = start;
  while (index < children.length) {
    const heading = children[index];
    if (!isElement(heading) || headingLevel(heading) !== level) break;
    const step = stepPrefix(heading);
    if (step === undefined || step.number !== run.length + 1) break;
    let end = index + 1;
    while (end < children.length) {
      const node = children[end];
      if (node === undefined || stops.has(node)) break;
      const depth = headingLevel(node);
      if (depth !== undefined && depth <= level) break;
      end++;
    }
    run.push({ heading, ...step, start: index, end });
    index = end;
  }

  // A step boundary must not split raw HTML such as <details> … </details>.
  const balanced = run.every((step) => rawTagsBalanced(children.slice(step.start, step.end)));
  return run.length >= 2 && balanced ? run : undefined;
}

/** Step number and prefix of a heading whose first text node starts with that prefix. */
function stepPrefix(heading: Element): { number: number; prefix: string } | undefined {
  const step = parseStepHeading(hastText(heading));
  const first = heading.children[0];
  return step !== undefined && first?.type === 'text' && first.value.startsWith(step.prefix) ? step : undefined;
}

/** Moves the number prefix ("1. ", "Step 1: ") into an `sr-only` span. */
function hidePrefix(heading: Element, prefix: string): void {
  const [first, ...rest] = heading.children;
  if (first?.type !== 'text') return;
  const remainder = first.value.slice(prefix.length);
  heading.children = [
    element('span', { className: ['sr-only'] }, [text(prefix)]),
    ...(remainder === '' ? [] : [text(remainder)]),
    ...rest,
  ];
}

const voidElements = new Set(['area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'source', 'track', 'wbr']);

/** Whether the raw HTML among `nodes` closes every tag it opens. */
function rawTagsBalanced(nodes: readonly RootContent[]): boolean {
  let depth = 0;
  for (const node of nodes) {
    if (node.type !== 'raw') continue;
    for (const [, closing, name = '', selfClosing] of node.value.matchAll(/<(\/?)([a-zA-Z][\w-]*)[^>]*?(\/?)>/g)) {
      if (voidElements.has(name.toLowerCase()) || selfClosing) continue;
      depth += closing ? -1 : 1;
      if (depth < 0) return false;
    }
  }
  return depth === 0;
}

// ---------------------------------------------------------------------------
// Inline polish

const runOnPattern =
  /^(?:((?:Then run|Run(?: first| in another session)?) on:)\s+(.+)|((?:运行位置|(?:先|接着|然后|在另一会话中)?运行于)[：:])\s*(.+)|在\s*(.+?)\s*上运行[：:]?)$/;

/** A "**Run on: …**" / "**运行位置：…**" label: the label text, the machine named, and an icon for it. */
export interface RunOn {
  label: string;
  target: string;
  icon: 'Server' | 'Laptop' | 'Smartphone' | 'MapPin';
}

/**
 * Parses a label such as "Run on: macOS", "Then run on: VPS", "运行位置：macOS",
 * "先运行于：VPS", "接着运行于：macOS", "在另一会话中运行于：VPS", or
 * "在 macOS 上运行：". The icon is a server for a VPS, a laptop for a Mac, a
 * phone for iOS, and a pin otherwise.
 */
export function parseRunOn(text: string): RunOn | undefined {
  const flat = text.replace(/\s+/g, ' ').trim();
  const match = runOnPattern.exec(flat);
  if (match === null) return undefined;
  const label = match[1] ?? match[3] ?? '运行位置：';
  const target = (match[2] ?? match[4] ?? match[5] ?? '').trim();
  if (target === '') return undefined;
  if (/(?<![A-Za-z0-9])VPS(?![A-Za-z0-9])/.test(target)) return { label, target, icon: 'Server' };
  if (/(?<![A-Za-z0-9])(?:Mac|macOS)(?![A-Za-z0-9])/.test(target)) return { label, target, icon: 'Laptop' };
  if (/(?<![A-Za-z0-9])(?:iOS|iPhone|iPad)(?![A-Za-z0-9])/.test(target)) return { label, target, icon: 'Smartphone' };
  return { label, target, icon: 'MapPin' };
}

/** A paragraph holding only a "**Run on: …**" label, restyled as a badge. */
function toRunOnBadge(paragraph: Element): Element | undefined {
  const [label, ...rest] = paragraph.children;
  if (rest.length > 0 || !isElement(label, 'strong') || !label.children.every((node) => node.type === 'text')) {
    return undefined;
  }
  const runOn = parseRunOn(hastText(label));
  if (runOn === undefined) return undefined;
  const badge = element(
    'strong',
    {
      className:
        'inline-flex max-w-full items-start gap-1.5 rounded-2xl border bg-fd-secondary px-2.5 py-1 text-sm text-fd-secondary-foreground'.split(
          ' ',
        ),
    },
    [
      lucideIcon(runOn.icon, ['mt-0.5', 'size-4', 'shrink-0', 'text-fd-primary']),
      element('span', {}, [
        element('span', { className: ['font-normal', 'text-fd-muted-foreground'] }, [text(runOn.label)]),
        text(` ${runOn.target}`),
      ]),
    ],
  );
  return { ...paragraph, children: [badge] };
}

const shortcutPattern = /^(?:Control|Command|Option|Shift)(?:-[A-Za-z0-9]+)+$/;

/** Whether text names a key combination such as "Control-C" or "Command-Shift-K". */
export function isShortcut(text: string): boolean {
  return shortcutPattern.test(text.trim());
}

/** Items of a menu path such as "Settings > Overlay Networks"; `undefined` without " > ". */
export function menuPathItems(text: string): string[] | undefined {
  const items = text.split(' > ');
  return items.length > 1 && items.every((item) => item.trim() !== '') ? items : undefined;
}

/**
 * `mapElements` callback: key combinations in bold or code become <kbd>, and
 * bold menu paths outside headings, links, and code get chevrons.
 */
function polishInline(node: Element, ancestors: readonly Element[]): Element | undefined {
  if ((node.tagName === 'strong' || node.tagName === 'code') && isShortcut(hastText(node))) {
    return element('kbd', {}, [text(hastText(node).trim())]);
  }
  const barrier = ancestors.some((ancestor) => headingLevel(ancestor) !== undefined || ['a', 'code'].includes(ancestor.tagName));
  return node.tagName === 'strong' && !barrier ? toMenuPath(node) : undefined;
}

/** Each " > " becomes a chevron; the text stays for screen readers and copying. */
function toMenuPath(strong: Element): Element | undefined {
  const [only, ...rest] = strong.children;
  if (rest.length > 0 || only?.type !== 'text') return undefined;
  const items = menuPathItems(only.value);
  if (items === undefined) return undefined;
  const children = items.flatMap((item, index): ElementContent[] =>
    index === 0 ? [text(item)] : [...menuSeparator(), text(item)],
  );
  return { ...strong, children };
}

/** A menu path's " > ": kept for screen readers and copying, shown as a chevron. */
function menuSeparator(): ElementContent[] {
  return [
    element('span', { className: ['sr-only'] }, [text(' > ')]),
    lucideIcon('ChevronRight', ['inline', 'size-3.5', 'mx-0.5', 'align-[-0.125em]', 'text-fd-muted-foreground']),
  ];
}

const separatorPattern = /^\s+>\s+$/;
const trailingSeparatorPattern = /\s+>\s+$/;

/**
 * Menu paths written as separate bold items get the same chevrons as one bold
 * path: a " > " between two bold items ("**…** > **Edit**"), and one ending
 * the text right before such a pair ("Heeler > **Hosts** > **Add Host**").
 */
function addMenuSeparators(nodes: readonly ElementContent[]): ElementContent[] {
  return nodes.flatMap((node, index): ElementContent[] => {
    const [before, after, between, last] = [nodes[index - 1], nodes[index + 1], nodes[index + 2], nodes[index + 3]];
    if (node.type !== 'text' || !isElement(after, 'strong')) return [node];
    if (isElement(before, 'strong') && separatorPattern.test(node.value)) return menuSeparator();
    const trailing = trailingSeparatorPattern.exec(node.value);
    const pairFollows = between?.type === 'text' && separatorPattern.test(between.value) && isElement(last, 'strong');
    if (trailing === null || !pairFollows) return [node];
    const rest = node.value.slice(0, trailing.index);
    return [...(rest === '' ? [] : [text(rest)]), ...menuSeparator()];
  });
}

/** Applies `addMenuSeparators` to every element below `parent` outside headings, links, and code. */
function addMenuPathSeparators(parent: HastParent): void {
  for (const child of parent.children) {
    if (child.type !== 'element' || headingLevel(child) !== undefined || ['a', 'code', 'pre'].includes(child.tagName)) continue;
    child.children = addMenuSeparators(child.children);
    addMenuPathSeparators(child);
  }
}

// ---------------------------------------------------------------------------
// Fumadocs components for plain Markdown

/**
 * Rehype plugin: gives code blocks, tables, and headings the markup of
 * Fumadocs UI's MDX components (<CodeBlock>, its table wrapper, <Heading>),
 * since plain Markdown cannot use React components. MDX files are skipped;
 * there `defaultMdxComponents` does this itself.
 */
export function rehypeFumadocsElements() {
  return (tree: HastRoot, file: Pick<MarkdownFile, 'path'>) => {
    if (file.path?.endsWith('.mdx')) return;
    const locale = guideLocale(file);
    const visit = (parent: HastParent) => {
      parent.children = parent.children.map((child) => {
        if (child.type === 'element') {
          if (child.tagName === 'pre' && classList(child).includes('shiki')) return toCodeFrame(child, locale);
          if (child.tagName === 'table') return toTableFrame(child);
          if (/^h[2-6]$/.test(child.tagName) && typeof child.properties.id === 'string') {
            return toAnchoredHeading(child, child.properties.id, locale);
          }
        }
        // rehypeCode leaves each highlighted block inside a nested root node,
        // which the hast types do not model; descend into anything with children.
        if ('children' in child) visit(child);
        return child;
      });
    };
    visit(tree);
  };
}

const fieldTables = [
  ['Field', 'Value'],
  ['Host field', 'Value'],
  ['Console setting', 'Value'],
  ['Tab', 'Setting'],
  ['Value', 'Example'],
  ['Placeholder', 'Example', 'Meaning'],
  ['字段', '值'],
  ['Host 字段', '值'],
  ['控制台设置', '值'],
  ['标签页', '设置'],
  ['值', '示例'],
  ['占位符', '示例', '含义'],
].map((headers) => headers.join('\n'));

/**
 * `gallery` for a table of screenshots (raw `<img>` in its cells), `fields`
 * for a form-values table such as "Field | Value" ("字段 | 值" in Chinese),
 * otherwise `undefined`.
 */
export function tableKind(table: Element): 'fields' | 'gallery' | undefined {
  const hasImage = (node: RootContent): boolean =>
    (node.type === 'raw' && /<img\b/i.test(node.value)) ||
    (node.type === 'element' && (node.tagName === 'img' || node.children.some(hasImage)));
  if (table.children.some(hasImage)) return 'gallery';

  const head = table.children.find((node) => isElement(node, 'thead'));
  const row = isElement(head) ? head.children.find((node) => isElement(node, 'tr')) : undefined;
  const headers = isElement(row) ? row.children.filter((node) => isElement(node, 'th')).map((cell) => hastText(cell).trim()) : [];
  return fieldTables.includes(headers.join('\n')) ? 'fields' : undefined;
}

/** Like the MDX table wrapper: scrolls wide tables on its own. `data-table` selects a layout in content.css. */
function toTableFrame(table: Element): Element {
  const kind = tableKind(table);
  return element(
    'div',
    {
      className: ['relative', 'overflow-auto', 'prose-no-margin', 'my-6'],
      ...(kind === undefined ? {} : { dataTable: kind }),
    },
    [table],
  );
}

/**
 * Like <Heading>: clears the sticky header on fragment jumps, links to itself,
 * and has a copy-link button (src/scripts/content.ts copies the URL). The
 * button is labelled by aria-label alone: any text inside a heading would join
 * its table-of-contents entry. With no text to change, it is not a live
 * region; content.ts announces the copy through a status element instead.
 */
function toAnchoredHeading(heading: Element, id: string, locale: Locale): Element {
  const button = element(
    'button',
    {
      type: 'button',
      dataCopyAnchor: '',
      ariaLabel: locale === 'zh' ? '复制锚点链接' : 'Copy anchor link',
      className:
        'group inline-flex items-center justify-center rounded-md text-sm font-medium duration-100 disabled:pointer-events-none disabled:opacity-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-fd-ring hover:bg-fd-accent hover:text-fd-accent-foreground p-1 [&_svg]:size-4 not-prose shrink-0 text-fd-muted-foreground opacity-0 transition-opacity group-hover/heading:opacity-100 focus-visible:opacity-100 data-checked:opacity-100'.split(
          ' ',
        ),
    },
    [lucideIcon('Link', ['group-data-checked:hidden']), lucideIcon('CopyCheck', ['hidden', 'group-data-checked:block'])],
  );
  return {
    ...heading,
    properties: {
      ...heading.properties,
      className: ['group/heading', 'flex', 'scroll-m-28', 'flex-row', 'items-center', 'gap-1'],
    },
    children: [element('a', { href: `#${id}`, dataCard: '' }, heading.children), button],
  };
}

/** Icon for a code block title: a prompt for shells, a check or a cross for sample output, a file otherwise. */
function codeTitleIcon(title: string): IconName {
  if (title === 'Terminal' || title === '终端' || title === 'PowerShell') return 'Terminal';
  if (title === 'Expected output' || title === '预期输出') return 'CircleCheck';
  if (title === 'Must not appear' || title === '不应出现') return 'CircleX';
  return 'FileCode';
}

/**
 * Static copy button like <CodeBlock>'s, so it works without hydration:
 * src/scripts/content.ts copies on click and sets data-checked, which swaps
 * the clipboard icon for a check mark.
 */
function copyButton(locale: Locale): Element {
  return element(
    'button',
    {
      type: 'button',
      dataCopyCode: '',
      ariaLive: 'polite',
      className:
        'group inline-flex items-center justify-center rounded-md p-1 text-fd-muted-foreground transition-colors duration-100 hover:text-fd-accent-foreground data-checked:text-fd-accent-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-fd-ring'.split(
          ' ',
        ),
    },
    [
      lucideIcon('Clipboard', ['size-4', 'group-data-checked:hidden']),
      lucideIcon('Check', ['size-4', 'hidden', 'group-data-checked:inline']),
      element('span', { className: ['sr-only'] }, [text(locale === 'zh' ? '复制代码' : 'Copy code')]),
    ],
  );
}

function toCodeFrame(pre: Element, locale: Locale): Element {
  // rehypeCode attaches a language icon for <CodeBlock>, and Shiki copies the
  // meta (title, allowCopy) onto the <pre>; none of these are HTML attributes.
  // The viewport takes over the <pre>'s tab stop.
  const {
    icon: _icon,
    class: _class,
    className: _className,
    title,
    allowCopy,
    tabindex: _tabindex,
    tabIndex: _tabIndex,
    ...properties
  } = pre.properties;
  const preClasses = classList(pre);
  const caption = typeof title === 'string' && title.trim() !== '' ? title.trim() : undefined;
  const copyable = allowCopy !== 'false' && allowCopy !== false;
  const floatingButton = copyable && caption === undefined;
  // Same as <CodeBlock>: keeps the end of each line clear of a floating
  // button. Set on the <pre> because its .shiki class resets the variable.
  const style = [properties.style, floatingButton ? '--padding-right: calc(var(--spacing) * 8)' : undefined]
    .filter((value) => typeof value === 'string' && value !== '')
    .join('; ');

  // <CodeBlock> puts a <figcaption> in this header row, where it cannot
  // caption the figure (it must be the figure's first or last child), so the
  // title is a plain element here; the viewport's aria-label names the code.
  const header =
    caption === undefined
      ? []
      : [
          element('div', { className: 'flex text-fd-muted-foreground items-center gap-2 h-9.5 border-b px-4'.split(' ') }, [
            lucideIcon(codeTitleIcon(caption), ['size-3.5', 'shrink-0']),
            element('div', { className: ['flex-1', 'truncate'] }, [text(caption)]),
            ...(copyable ? [element('div', { className: ['-me-2'] }, [copyButton(locale)])] : []),
          ]),
        ];

  return element(
    'figure',
    {
      dir: 'ltr',
      className: 'my-4 bg-fd-card rounded-xl shiki relative border not-prose overflow-hidden text-sm'.split(' '),
      dataCodeFrame: '',
      ...(caption === undefined ? {} : { dataTitled: '' }),
    },
    [
      ...header,
      ...(floatingButton
        ? [
            element(
              'div',
              { className: 'absolute top-2 right-2 z-2 backdrop-blur-lg rounded-lg text-fd-muted-foreground'.split(' ') },
              [copyButton(locale)],
            ),
          ]
        : []),
      // Focusable so keyboards can scroll it, and named for that focus stop.
      // A group rather than <CodeBlock>'s region: a named region is a
      // landmark, and dozens of "Terminal" landmarks would bury the page's own.
      element(
        'div',
        {
          role: 'group',
          tabIndex: 0,
          ariaLabel: caption ?? (locale === 'zh' ? '代码' : 'Code'),
          className:
            'text-[0.8125rem] py-3.5 overflow-auto max-h-[600px] fd-scroll-container focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-fd-ring'.split(
              ' ',
            ),
        },
        [
          element(
            'pre',
            {
              ...properties,
              className: [...preClasses, 'min-w-full', 'w-max', '*:flex', '*:flex-col'],
              style: style === '' ? undefined : style,
            },
            pre.children,
          ),
        ],
      ),
    ],
  );
}
