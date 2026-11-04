import config from '../guides.json' with { type: 'json' };

/** Supported site locales: English at `/` and Simplified Chinese under `/zh`. */
export const locales = ['en', 'zh'] as const;
export type Locale = (typeof locales)[number];
export const defaultLocale: Locale = 'en';

export function isLocale(value: string | undefined): value is Locale {
  return value === 'en' || value === 'zh';
}

/** BCP 47 language tag for `<html lang>`. */
export function htmlLang(locale: Locale): 'en' | 'zh-CN' {
  return locale === 'zh' ? 'zh-CN' : 'en';
}

/** Locale of a site pathname (`/zh` and `/zh/...` are Chinese, everything else English). */
export function localeFromPath(pathname: string): Locale {
  const clean = pathname.split(/[?#]/, 1)[0] ?? '/';
  return clean === '/zh' || clean.startsWith('/zh/') ? 'zh' : 'en';
}

/**
 * The same page pathname in `locale`, with any `.html` suffix, query, or
 * `#fragment` stripped (heading anchors differ between languages).
 */
export function localePath(pathname: string, locale: Locale): string {
  const clean = (pathname.split(/[?#]/, 1)[0] ?? '/').replace(/(\/index)?\.html$/, '') || '/';
  const unprefixed = clean === '/zh' ? '/' : clean.startsWith('/zh/') ? clean.slice(3) : clean;
  const base = unprefixed.length > 1 ? unprefixed.replace(/\/+$/, '') : '/';
  if (locale === defaultLocale) return base;
  return base === '/' ? `/${locale}` : `/${locale}${base}`;
}

/** Repository that hosts the guides; links outside the site point here. */
export const githubRepo = 'https://github.com/ZingerLittleBee/Heeler';

/** Repo-relative directory the published guides are read from. */
export const guidesDir = 'docs/guides';

/** Repo-relative directory whose files the site serves under `/images/`. */
export const guideImagesDir = 'docs/guides/images';

export interface GuideSection {
  title: Readonly<Record<Locale, string>>;
  guides: readonly string[];
}

export const guideSections: readonly GuideSection[] = config.sections;

/** Basenames (without `.md`) of every published guide, in sidebar order. */
export const publishedGuides: readonly string[] = guideSections.flatMap((section) => section.guides);

/** Sidebar labels that differ from a guide's H1 title, by locale. */
export const sidebarTitles: Readonly<Record<Locale, Readonly<Record<string, string>>>> = config.sidebarTitles;

/** A page's sidebar label override in `locale`, if configured in `src/guides.json`. */
export function sidebarTitle(slug: string, locale: Locale = defaultLocale): string | undefined {
  return sidebarTitles[locale][slug];
}

/** Lucide icon name for each page (the index and every guide), keyed by slug. */
export const pageIcons: Readonly<Record<string, string>> = config.icons;
