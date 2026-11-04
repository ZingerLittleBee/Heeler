import { type CollectionEntry, getCollection, render } from 'astro:content';
import { defineI18n } from 'fumadocs-core/i18n';
import { structure, type StructuredData } from 'fumadocs-core/mdx-plugins';
import { replaceSource } from 'fumadocs-core/mdx-plugins/stringifier';
import { createGetUrl, loader, type StaticSource } from 'fumadocs-core/source';
import type { SerializedPageTree } from 'fumadocs-core/source/client';
import { lucideIconsPlugin } from 'fumadocs-core/source/plugins/lucide-icons';
import { icons } from 'lucide-react';
import remarkMdx from 'remark-mdx';
import {
  defaultLocale,
  githubRepo,
  guideSections,
  guidesDir,
  isLocale,
  type Locale,
  locales,
  pageIcons,
  sidebarTitle,
} from './guides.ts';
import type { Root as MdastRoot } from 'mdast';
import { extractTitle, hiddenForSearch, htmlNodes } from './markdown.ts';

type Entry = CollectionEntry<'guides'> | CollectionEntry<'pages'>;

/** A Lucide icon's component name, such as `Compass`. */
export type IconName = keyof typeof icons;

interface DocsPageData {
  title: string;
  description: string;
  /** Lucide icon for the sidebar and for cards that link to the page (src/guides.json). */
  icon: IconName;
  /** Source file on GitHub, for the "Edit on GitHub" link. */
  sourceUrl: string;
  entry: Entry;
}

/** Fumadocs i18n configuration: English at `/` and Simplified Chinese under `/zh`. */
export const i18n = defineI18n<Locale>({
  defaultLanguage: defaultLocale,
  languages: [...locales],
  hideLocale: 'default-locale',
  parser: 'dir',
  fallbackLanguage: null,
});

const getUrl = createGetUrl('/', i18n);

/** Fumadocs page source: the site's own pages plus the published guides, in one flat tree per locale. */
export const source = loader({
  source: await createSource(),
  i18n,
  baseUrl: '/',
  plugins: [lucideIconsPlugin()],
  pageTree: {
    transformers: [
      {
        file(node, filePath) {
          const slug = filePath === undefined ? undefined : slugOf(filePath);
          const locale = isLocale(this.locale) ? this.locale : defaultLocale;
          const label = slug === undefined ? undefined : sidebarTitle(slug, locale);
          return label === undefined ? node : { ...node, name: label };
        },
      },
    ],
  },
});

/**
 * The page trees for the `Docs` island, keyed by locale. Their icons are React
 * elements, which cannot cross the island boundary, so they travel as rendered
 * HTML and `deserializePageTree` (in src/components/docs.tsx) turns them back
 * into elements in the browser.
 */
export const serializedPageTrees: Readonly<Record<Locale, SerializedPageTree>> = {
  en: await source.serializePageTree(source.getPageTree('en')),
  zh: await source.serializePageTree(source.getPageTree('zh')),
};

/** A page's sidebar label, icon, and URL, for the cards that link to it from content/index.mdx. */
export function pageLink(slug: string, locale: Locale = defaultLocale): { title: string; icon: IconName; url: string } {
  const slugs = slug === 'index' ? [] : [slug];
  const page = source.getPage(slugs, locale) ?? source.getPage(slugs, defaultLocale);
  if (page === undefined) throw new Error(`There is no page "${slug}" to link to`);
  return {
    title: sidebarTitle(slug, locale) ?? page.data.title,
    icon: page.data.icon,
    url: getUrl(slugs, locale),
  };
}

/** Sidebar section of a guide, for search result breadcrumbs; undefined for the index. */
export function sectionOf(slug: string, locale: Locale = defaultLocale): string | undefined {
  return guideSections.find((section) => section.guides.includes(slug))?.title[locale];
}

/**
 * Search records for a page. A guide's H1 is dropped as it is on the page, and
 * so is raw HTML (the screenshots), which results would otherwise render, and
 * a guide's trailing review note and maintainer pointer (the page shows the
 * one as a footer line and drops the other). Records are sliced from the
 * source text, so these are blanked through Fumadocs' source replacements
 * rather than removed from the tree. MDX pages are parsed as MDX, so imports
 * stay out and card text gets in.
 */
export function getStructuredData(entry: Entry): StructuredData {
  const isMdx = entry.filePath?.endsWith('.mdx') ?? false;
  const searchTransform = () => (tree: MdastRoot, file: Parameters<typeof replaceSource>[0]) => {
    extractTitle(tree);
    const hidden = [...htmlNodes(tree), ...(isMdx ? [] : hiddenForSearch(tree))];
    for (const node of hidden) replaceSource(file, node, '', 'search');
  };
  return structure(entry.body ?? '', isMdx ? [remarkMdx, searchTransform] : [searchTransform]);
}

async function createSource() {
  const out: StaticSource<{ pageData: DocsPageData; metaData: { pages: string[] } }> = { files: [] };

  for (const entry of await getCollection('pages')) {
    const path = collectionPath(entry.filePath, 'content/');
    out.files.push({
      type: 'page',
      path,
      data: {
        ...entry.data,
        icon: iconFor(path),
        sourceUrl: `${githubRepo}/blob/main/docs-site/content/${path}`,
        entry,
      },
    });
  }

  for (const entry of await getCollection('guides')) {
    const path = collectionPath(entry.filePath, '../docs/guides/');
    // remarkGuideTitle moved the H1 and lead paragraph into the frontmatter.
    const frontmatter: Record<string, unknown> = (await render(entry)).remarkPluginFrontmatter;
    const { title, description } = frontmatter;
    if (typeof title !== 'string' || typeof description !== 'string') {
      throw new Error(`${guidesDir}/${path} needs a "# Title" heading followed by a paragraph`);
    }
    out.files.push({
      type: 'page',
      path,
      data: { title, description, icon: iconFor(path), sourceUrl: `${githubRepo}/blob/main/${guidesDir}/${path}`, entry },
    });
  }

  // Sidebar order and grouping: the index, then one separator per section.
  for (const locale of locales) {
    out.files.push({
      type: 'meta',
      path: locale === defaultLocale ? 'meta.json' : `${locale}/meta.json`,
      data: {
        pages: ['index', ...guideSections.flatMap((section) => [`---${section.title[locale]}---`, ...section.guides])],
      },
    });
  }

  return out;
}

/** The sidebar icon of a page file, checked here because Fumadocs only warns about unknown names. */
function iconFor(path: string): IconName {
  const slug = slugOf(path);
  const icon = pageIcons[slug];
  if (icon === undefined) throw new Error(`src/guides.json has no icon for "${slug}"`);
  if (!isIconName(icon)) throw new Error(`src/guides.json: "${icon}" (for "${slug}") is not a Lucide icon name`);
  return icon;
}

function isIconName(name: string): name is IconName {
  return Object.hasOwn(icons, name);
}

function slugOf(path: string): string {
  return (path.split('/').at(-1) ?? path).replace(/\.mdx?$/, '');
}

function collectionPath(filePath: string | undefined, prefix: string): string {
  if (filePath === undefined || !filePath.startsWith(prefix)) {
    throw new Error(`Unexpected content entry path (expected prefix "${prefix}"): ${filePath}`);
  }
  const path = filePath.slice(prefix.length);
  if (path === '') throw new Error(`Content entry has no relative path: ${filePath}`);
  return path;
}
