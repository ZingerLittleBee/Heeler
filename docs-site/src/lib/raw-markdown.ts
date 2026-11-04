// The Markdown a guide page offers through "Copy Markdown" and "Open"
// (src/pages/[...slug].md.ts): the guide file as written, with its links made
// absolute, so the text still works after it is pasted somewhere else.
//
// Only link destinations change. The rest is copied from the source through
// Fumadocs' source-backed stringifier rather than re-serialized, so headings,
// lists, tables, and code blocks keep their exact formatting.

import { createStringifier, replaceSource } from 'fumadocs-core/mdx-plugins/stringifier';
import type { Definition, Image, Link, Nodes, Root } from 'mdast';
import remarkGfm from 'remark-gfm';
import remarkParse from 'remark-parse';
import { type Plugin, unified } from 'unified';
import { type GuidePluginOptions, resolveGuideHref, rewriteHtmlLinks } from './markdown.ts';

export interface RawMarkdownOptions {
  /** Repo-relative path of the guide, such as `docs/guides/tailscale.md`. */
  sourcePath: string;
  /** Site origin that site-relative URLs resolve against. */
  site: string;
  isDirectory: GuidePluginOptions['isDirectory'];
}

/**
 * The absolute URL a guide link points to, or `undefined` to keep it as written
 * (absolute URLs and in-page anchors).
 */
export function absoluteGuideHref(href: string, options: RawMarkdownOptions): string | undefined {
  const resolved = resolveGuideHref(href, options.sourcePath, options.isDirectory);
  if (resolved === undefined || !resolved.startsWith('/')) return resolved;
  return new URL(resolved, options.site).href;
}

/** A Markdown link destination, in angle brackets when it contains spaces or parentheses. */
function destination(url: string): string {
  return /[\s()<>]/.test(url) ? `<${url.replaceAll('<', '%3C').replaceAll('>', '%3E')}>` : url;
}

function titlePart(title: string | null | undefined): string {
  return title == null ? '' : ` "${title.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"`;
}

/** Image alt text with the characters that would end the brackets escaped. */
function escapeAlt(alt: string): string {
  return alt.replace(/[\\[\]]/g, '\\$&');
}

/** Whether a link is written with brackets (`[text](url)`), not as an autolink (`<url>` or a bare URL). */
function isBracketLink(node: Link, source: string): boolean {
  const start = node.position?.start.offset;
  return start !== undefined && source[start] === '[';
}

function walk(node: Nodes, visit: (node: Nodes) => void): void {
  visit(node);
  if ('children' in node) {
    for (const child of node.children) walk(child, visit);
  }
}

function resourceMarkdown(node: Image | Definition, url: string): string {
  const tail = `${destination(url)}${titlePart(node.title)}`;
  return node.type === 'image' ? `![${escapeAlt(node.alt ?? '')}](${tail})` : `[${node.label ?? node.identifier}]: ${tail}`;
}

/** Unified plugin: records each link rewrite as a replacement of that node's source. */
const rewriteLinks: Plugin<[RawMarkdownOptions], Root> = (options) => (tree, file) => {
  const rewrite = (href: string) => absoluteGuideHref(href, options);
  const source = String(file);
  walk(tree, (node) => {
    switch (node.type) {
      case 'link': {
        const url = rewrite(node.url);
        if (url === undefined || !isBracketLink(node, source)) return;
        replaceSource(file, node, (s) => `[${s.inner(node)}](${destination(url)}${titlePart(node.title)})`);
        return;
      }
      case 'image':
      case 'definition': {
        const url = rewrite(node.url);
        if (url !== undefined) replaceSource(file, node, resourceMarkdown(node, url));
        return;
      }
      case 'html': {
        const html = rewriteHtmlLinks(node.value, rewrite);
        if (html !== node.value) replaceSource(file, node, html);
        return;
      }
    }
  });
};

// unified types a plugin's compiler for any unist node; this one gets the mdast root.
function isRoot(node: { type: string }): node is Root {
  return node.type === 'root';
}

/** Unified plugin: compiles the tree back to its source text, with the replacements applied. */
const compileSource: Plugin<[], Root, string> = function () {
  this.compiler = (tree, file) => {
    if (!isRoot(tree)) throw new Error(`Expected an mdast root, got ${tree.type}`);
    return createStringifier(file).stringify(tree);
  };
};

/** Rewrites a guide's Markdown so that its links and images are absolute URLs. */
export function toRawMarkdown(markdown: string, options: RawMarkdownOptions): string {
  const processor = unified().use(remarkParse).use(remarkGfm).use(rewriteLinks, options).use(compileSource);
  const output = String(processor.processSync(markdown));
  return output.endsWith('\n') ? output : `${output}\n`;
}
