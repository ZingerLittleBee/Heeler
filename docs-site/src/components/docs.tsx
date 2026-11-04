import type { AstroProviderProps } from 'fumadocs-core/framework/astro';
import { deserializePageTree, type SerializedPageTree } from 'fumadocs-core/source/client';
import type { TOCItemType } from 'fumadocs-core/toc';
import { useSidebar } from '@fumadocs/base-ui/components/sidebar/base';
import { DocsLayout, useSpaciousLayout } from '@fumadocs/base-ui/layouts/spacious';
import {
  DocsBody,
  DocsDescription,
  DocsPage,
  DocsTitle,
  EditOnGitHub,
  MarkdownCopyButton,
  ViewOptionsPopover,
} from '@fumadocs/base-ui/layouts/spacious/page';
import { RootProvider } from '@fumadocs/base-ui/provider/astro';
import { GlobeIcon, House } from 'lucide-react';
import { type ReactNode, useEffect, useMemo, useState } from 'react';
import { navigate } from 'astro:transitions/client';
import { githubRepo, htmlLang, type Locale, localeFromPath } from '@/lib/guides.ts';
import { useLanguage } from './language';
import { layoutSlots } from './layout-slots';
import { usePanelScroll } from './panel-scroll';
import StaticSearchDialog from './search';

export interface DocsProps {
  /** From `serializedPageTrees` in src/lib/source.ts. */
  trees: Readonly<Record<Locale, SerializedPageTree>>;
  pathname: string;
  params: AstroProviderProps['params'];
  /** Omitted on the 404 page, which has no article chrome. */
  page?: {
    title: string;
    /** Plain-text line under the title (the site's own pages). */
    description?: string;
    /** A guide's lead paragraph as HTML, shown under the title instead of in the body. */
    lead?: string;
    toc: TOCItemType[];
    sourceUrl: string;
    /** The page's Markdown (guides only), for the Copy Markdown and Open actions. */
    markdownUrl?: string;
  };
  children?: ReactNode;
}

/** The Fumadocs shell (sidebar, nav, search, theme) around one page's rendered HTML. */
export function Docs({ trees, pathname, params, page, children }: DocsProps) {
  // Workers serves a single dist/404.html for every unknown path; on the 404
  // page, read the actual browser pathname so /zh/... 404s render in Chinese.
  const [clientPath, setClientPath] = useState(pathname);
  useEffect(() => {
    if (page) return;
    const sync = () => {
      const current = window.location.pathname;
      setClientPath(current);
      const loc = localeFromPath(current);
      document.documentElement.lang = htmlLang(loc);
      document.title = loc === 'zh' ? '未找到页面 | Heeler 文档' : 'Page not found | Heeler Docs';
    };
    sync();
    document.addEventListener('astro:page-load', sync);
    return () => document.removeEventListener('astro:page-load', sync);
  }, [page, pathname]);

  const activePathname = page ? pathname : clientPath;
  const locale = localeFromPath(activePathname);
  const isZh = locale === 'zh';
  const tree = trees[locale];
  // deserializePageTree rewrites its argument in place, and during the build
  // every page renders the same serialized tree, so it gets a copy.
  const pageTree = useMemo(() => deserializePageTree(structuredClone(tree)), [tree]);
  usePanelScroll(activePathname);
  const language = useLanguage(activePathname);
  const websiteLabel = isZh ? 'Heeler 官网' : 'Heeler website';

  return (
    <RootProvider
      pathname={activePathname}
      params={params}
      navigate={navigate}
      search={{ SearchDialog: StaticSearchDialog }}
      i18n={language}
    >
      <DocsLayout
        tree={pageTree}
        nav={{
          url: isZh ? '/zh' : '/',
          title: (
            <>
              <img src="/logo.png" alt="" width={20} height={20} className="size-5 rounded-[5px]" />
              <span className="font-medium">{isZh ? 'Heeler 文档' : 'Heeler Docs'}</span>
            </>
          ),
        }}
        // An icon beside GitHub's in the page header (and the drawer's top row),
        // rather than a text link at the top of the sidebar.
        links={[
          {
            type: 'icon',
            text: websiteLabel,
            label: websiteLabel,
            icon: <GlobeIcon />,
            url: 'https://heeler.bybee.dev',
            external: true,
          },
        ]}
        githubUrl={githubRepo}
        // layoutSlots puts the theme switch at the bottom of the sidebar instead.
        themeSwitch={{ enabled: false }}
        slots={layoutSlots}
      >
        <DrawerFocus />
        {page ? (
          <DocsPage
            key={pathname}
            toc={page.toc}
            // Spacious has no <main>; make the article the main landmark.
            role="main"
            // The phone table-of-contents bar has no focus indicator of its own.
            tableOfContentPopover={{
              trigger: { className: 'focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-fd-ring' },
            }}
          >
            <DocsTitle>{page.title}</DocsTitle>
            {page.lead !== undefined ? (
              <p
                className="mb-2 text-lg text-fd-muted-foreground [&_a]:font-medium [&_a]:text-fd-foreground [&_a]:underline [&_a]:decoration-fd-primary [&_a]:decoration-[1.5px] [&_a]:underline-offset-[3.5px] [&_code]:rounded-md [&_code]:bg-fd-muted [&_code]:px-1 [&_code]:py-0.5 [&_code]:font-mono [&_code]:text-[0.875em] [&_strong]:font-medium [&_strong]:text-fd-foreground"
                dangerouslySetInnerHTML={{ __html: page.lead }}
              />
            ) : (
              page.description !== undefined && (
                <DocsDescription>{page.description}</DocsDescription>
              )
            )}
            {page.markdownUrl && (
              // Page actions under the title, as on fumadocs.dev.
              <div className="mb-4 flex flex-row flex-wrap items-center gap-2 border-b pb-6">
                <MarkdownCopyButton markdownUrl={page.markdownUrl} />
                <ViewOptionsPopover markdownUrl={page.markdownUrl} githubUrl={page.sourceUrl} />
              </div>
            )}
            <DocsBody className="text-fd-foreground/90">{children}</DocsBody>
            <EditOnGitHub href={page.sourceUrl} className="mt-6 self-start" />
          </DocsPage>
        ) : (
          <NotFoundPanel locale={locale}>{children}</NotFoundPanel>
        )}
      </DocsLayout>
    </RootProvider>
  );
}

/**
 * Spacious renders the phone sidebar drawer after the page, so keyboard focus
 * would walk the whole article before reaching it, and Shift-Tab would leave
 * the open drawer for the page under its overlay. While the drawer is open,
 * the page behind it is inert and focus starts in the drawer; when it closes,
 * focus returns to its trigger. Escape closes it.
 */
function DrawerFocus() {
  const { open, setOpen, mode } = useSidebar();
  useEffect(() => {
    if (mode !== 'drawer' || !open) return;
    const drawer = document.getElementById('nd-sidebar-mobile');
    // The page behind the drawer: the header, table-of-contents bar, and page
    // panel, its siblings in the layout grid. The overlay is fixed like the
    // drawer and stays live, so tapping it still closes the drawer.
    const background = [...(drawer?.parentElement?.children ?? [])].filter(
      (element): element is HTMLElement =>
        element instanceof HTMLElement && element !== drawer && getComputedStyle(element).position !== 'fixed',
    );
    for (const element of background) element.inert = true;
    drawer?.querySelector<HTMLElement>('a[href], button:not(:disabled)')?.focus();
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') setOpen(false);
    };
    document.addEventListener('keydown', onKeyDown);
    return () => {
      document.removeEventListener('keydown', onKeyDown);
      for (const element of background) element.inert = false;
      if (drawer?.contains(document.activeElement)) {
        document.querySelector<HTMLElement>('[aria-controls="nd-sidebar-mobile"]')?.focus();
      }
    };
  }, [open, mode, setOpen]);
  return null;
}

/**
 * Spacious lays its children out on a named grid (sidebar | header | main), and
 * only DocsPage draws the inset panel with its header actions (the website and
 * GitHub links).
 * The 404 page has no DocsPage, so it gets the same panel and actions here.
 * On `/zh/...` URLs it renders Simplified Chinese copy while keeping links to
 * both language home pages.
 */
function NotFoundPanel({ locale, children }: { locale: Locale; children?: ReactNode }) {
  const { slots } = useSpaciousLayout();
  return (
    <div className="mx-2 mt-2 flex min-h-0 min-w-0 flex-col rounded-t-2xl border-x border-t bg-fd-background [grid-area:main] md:ms-0 md:mb-2 md:overflow-y-auto md:rounded-2xl md:border md:shadow-sm">
      <div className="flex h-(--fd-header-height) shrink-0 items-center ps-6 pe-4 max-md:hidden">
        <slots.actions className="ms-auto" />
      </div>
      {locale === 'zh' ? (
        <main className="flex flex-1 flex-col items-center justify-center gap-4 px-8 py-16 text-center">
          <p aria-hidden="true" className="text-6xl font-bold text-fd-muted-foreground">
            404
          </p>
          <h1 className="text-2xl font-semibold">未找到页面</h1>
          <p className="max-w-md text-fd-muted-foreground">
            该地址没有对应的指南。请使用搜索功能，或从侧栏选择一篇指南。
          </p>
          <div className="mt-4 flex flex-wrap items-center justify-center gap-3">
            <a
              href="/zh"
              className="inline-flex items-center justify-center gap-1.5 rounded-md bg-fd-primary px-3 py-2 text-sm font-medium text-fd-primary-foreground transition-colors duration-100 hover:bg-fd-primary/90"
            >
              <House className="size-4" aria-hidden="true" />
              返回首页
            </a>
            <a
              href="/"
              lang="en"
              className="inline-flex items-center justify-center gap-1.5 rounded-md border px-3 py-2 text-sm font-medium text-fd-muted-foreground transition-colors duration-100 hover:bg-fd-accent hover:text-fd-accent-foreground"
            >
              English home
            </a>
          </div>
        </main>
      ) : (
        children
      )}
    </div>
  );
}
