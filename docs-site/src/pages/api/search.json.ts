import type { APIRoute } from 'astro';
import { createSearchAPI } from 'fumadocs-core/search/server';
import type { Locale } from '@/lib/guides.ts';
import { getStructuredData, sectionOf, source } from '@/lib/source.ts';

/**
 * Prebuilt per-locale search index, emitted as dist/api/search.json (en) and
 * dist/zh/api/search.json (zh) and loaded by the search dialog (useStaticSearch).
 * ZBSearch's 'multilingual' tokenizer segments CJK words via Intl.Segmenter;
 * 'english' keeps English stemming for the default locale.
 */
export function createLocaleSearch(locale: Locale) {
  return createSearchAPI('advanced', {
    language: locale === 'zh' ? 'multilingual' : 'english',
    indexes: () =>
      source.getPages(locale).map((page) => {
        const section = sectionOf(page.slugs.join('/'), locale);
        return {
          id: page.url,
          title: page.data.title,
          description: page.data.description,
          // The sidebar section; the default would also start with the tree's root name.
          breadcrumbs: section === undefined ? [] : [section],
          structuredData: getStructuredData(page.data.entry),
          url: page.url,
        };
      }),
  });
}

const server = createLocaleSearch('en');

export const GET: APIRoute = () => server.staticGET();
