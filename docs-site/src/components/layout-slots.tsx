import { useSidebar } from '@fumadocs/base-ui/components/sidebar/base';
import { buttonVariants } from '@fumadocs/base-ui/components/ui/button';
import { Popover, PopoverContent, PopoverTrigger } from '@fumadocs/base-ui/components/ui/popover';
import { useI18n } from '@fumadocs/base-ui/contexts/i18n';
import { LinkItem } from '@fumadocs/base-ui/layouts/shared';
import { type DocsLayoutProps, useSpaciousLayout } from '@fumadocs/base-ui/layouts/spacious';
import {
  Sidebar,
  SidebarDrawer,
  type SidebarProps,
  SidebarProvider,
} from '@fumadocs/base-ui/layouts/spacious/slots/sidebar';
import { useTheme } from '@fumadocs/base-ui/provider/base';
import {
  CheckIcon,
  ChevronsUpDownIcon,
  LanguagesIcon,
  type LucideIcon,
  MonitorIcon,
  MoonIcon,
  SunIcon,
} from 'lucide-react';
import { type ComponentProps, useEffect, useId, useState } from 'react';
import { createPortal, flushSync } from 'react-dom';

/**
 * Spacious slots that put the language and theme switches at the bottom of the
 * sidebar and of the phone drawer. Spacious puts them in the page header (the
 * theme in its options menu) and in the drawer's top row, which suits
 * fumadocs.dev's long sidebar; this site's sidebar is short and leaves room
 * below. Pass to DocsLayout along with `themeSwitch={{ enabled: false }}`, which
 * removes the built-in theme switches; `languageSelect: false` here removes the
 * built-in language selects.
 */
export const layoutSlots: DocsLayoutProps['slots'] = {
  sidebar: { provider: SidebarProvider, main: SidebarWithFooter, drawer: DrawerWithFooter },
  actions: HeaderActions,
  languageSelect: false,
};

// Neither sidebar has a footer slot, so the footer is portalled to the end of
// each one's flex column once it has mounted. Being inside the sidebar, it
// fades out and goes inert with it when collapsed and takes the sidebar's
// colour overrides.

function SidebarWithFooter(props: SidebarProps) {
  // Sidebar passes its props, ref included, to its <aside>, whose one child is the column.
  const [aside, setAside] = useState<HTMLElement | null>(null);
  const column = aside?.firstElementChild;
  return (
    <>
      <Sidebar {...props} ref={setAside} />
      {column && createPortal(<SidebarFooter />, column)}
    </>
  );
}

function DrawerWithFooter() {
  const { mode } = useSidebar();
  const [drawer, setDrawer] = useState<HTMLElement | null>(null);
  // SidebarDrawer takes no props, so its <aside> (the column) is found by id.
  // It stays mounted while the drawer is closed, as long as the layout is in
  // drawer mode.
  useEffect(() => {
    setDrawer(mode === 'drawer' ? document.getElementById('nd-sidebar-mobile') : null);
  }, [mode]);
  return (
    <>
      <SidebarDrawer />
      {mode === 'drawer' && drawer && createPortal(<SidebarFooter />, drawer)}
    </>
  );
}

/**
 * The page panel's header actions. Spacious shows icon links from lg up and
 * folds them into the options menu below that; without the theme switch the
 * menu would hold just those links (the website and GitHub), so they show at
 * every width.
 */
function HeaderActions({ className, ...props }: ComponentProps<'div'>) {
  const { menuItems } = useSpaciousLayout();
  return (
    <div className={`flex items-center gap-0.5 rounded-lg bg-fd-background ${className ?? ''}`} {...props}>
      {menuItems.map(
        (item) =>
          item.type === 'icon' && (
            <LinkItem
              key={item.url}
              item={item}
              aria-label={item.label}
              // The globe is less obvious than GitHub's mark, so name each on hover.
              title={item.label}
              className={buttonVariants({ variant: 'ghost', size: 'icon-sm', className: 'text-fd-muted-foreground' })}
            >
              {item.icon}
            </LinkItem>
          ),
      )}
    </div>
  );
}

function SidebarFooter() {
  return (
    // The rule keeps the row from reading as one more page link when the list
    // above runs down to it.
    <div className="mx-3 flex shrink-0 items-center gap-2 border-t py-2.5 text-fd-muted-foreground">
      <LanguageSwitch />
      <ThemeSwitch />
    </div>
  );
}

/**
 * Spacious' language select (its icon, the current language, and a chevron),
 * opening a list to pick another. Names carry their `lang`, so screen readers
 * say 简体中文 in Chinese. The choice goes to Fumadocs' I18nProvider (see
 * language.ts).
 */
function LanguageSwitch() {
  const { locale, locales = [], onChange } = useI18n();
  const [open, setOpen] = useState(false);
  const current = locales.find((item) => item.locale === locale);
  const isZh = locale === 'zh';
  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger className="flex h-9 min-w-0 cursor-pointer items-center gap-1.5 rounded-lg px-2.5 transition-colors hover:bg-fd-accent/60 hover:text-fd-accent-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-fd-ring data-popup-open:bg-fd-accent/60 data-popup-open:text-fd-accent-foreground">
        {/* The extra margin lines the name up with the page titles above. */}
        <LanguagesIcon className="me-1.5 size-4 shrink-0" />
        <span className="sr-only">{isZh ? '语言：' : 'Language: '}</span>
        {current && (
          <span lang={current.locale} className="truncate">
            {current.name}
          </span>
        )}
        <ChevronsUpDownIcon className="size-3.5 shrink-0" />
      </PopoverTrigger>
      {/* As wide as the trigger (or its longest name): at the popover's default
          240px, its edge would land just short of the theme switch's. */}
      <PopoverContent
        aria-label={isZh ? '语言' : 'Language'}
        align="start"
        className="flex w-max min-w-(--anchor-width) flex-col gap-0.5 p-1"
      >
        {locales.map((item) => (
          <button
            key={item.locale}
            type="button"
            lang={item.locale}
            aria-current={item.locale === locale}
            className="flex min-h-9 w-full cursor-pointer items-center gap-3 rounded-lg px-2.5 py-1.5 text-start transition-colors hover:bg-fd-accent hover:text-fd-accent-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-fd-ring"
            onClick={() => {
              onChange?.(item.locale);
              setOpen(false);
            }}
          >
            <span className="flex-1">{item.name}</span>
            {item.locale === locale && <CheckIcon className="size-4 shrink-0 text-fd-primary" />}
          </button>
        ))}
      </PopoverContent>
    </Popover>
  );
}

const themes: [value: string, label: { en: string; zh: string }, icon: LucideIcon, turn: string][] = [
  ['system', { en: 'System', zh: '跟随系统' }, MonitorIcon, '0deg'],
  ['light', { en: 'Light', zh: '浅色' }, SunIcon, '-90deg'],
  ['dark', { en: 'Dark', zh: '深色' }, MoonIcon, '40deg'],
];

/**
 * The theme segments of Spacious' options menu (system, light, dark, with their
 * sliding thumb and icon turn), on native radios so that the current theme is
 * announced and the arrow keys move between the options.
 */
function ThemeSwitch() {
  const { theme, setTheme } = useTheme();
  const { locale } = useI18n();
  const isZh = locale === 'zh';
  const id = useId();
  const index = themes.findIndex(([value]) => value === theme);

  function pick(value: string, icon: Element | null, turn: string) {
    if (typeof document.startViewTransition === 'function') {
      // global.css keeps the pointer cursor while the transition runs.
      document.startViewTransition(() => flushSync(() => setTheme(value)));
    } else {
      setTheme(value);
    }
    if (!matchMedia('(prefers-reduced-motion: reduce)').matches) {
      icon?.animate([{ rotate: turn, scale: 0.6 }, { rotate: '0deg', scale: 1 }], {
        duration: 520,
        easing: 'cubic-bezier(0.34, 1.56, 0.64, 1)',
      });
    }
  }

  return (
    <div
      role="radiogroup"
      aria-label={isZh ? '主题' : 'Theme'}
      className="relative ms-auto flex shrink-0 rounded-full border bg-fd-secondary p-0.5"
    >
      {index !== -1 && (
        <span
          aria-hidden
          className="absolute start-0.5 top-0.5 size-7 rounded-full bg-fd-background shadow-sm ring-1 ring-fd-border transition-transform duration-300 ease-[cubic-bezier(0.22,1,0.36,1)] motion-reduce:transition-none"
          style={{ translate: `${index * 100}%` }}
        />
      )}
      {themes.map(([value, label, Icon, turn]) => (
        <label
          key={value}
          className={`relative flex size-7 cursor-pointer items-center justify-center rounded-full transition-colors duration-150 has-focus-visible:ring-2 has-focus-visible:ring-fd-ring ${
            value === theme
              ? 'text-fd-foreground'
              : 'hover:bg-fd-accent hover:text-fd-accent-foreground'
          }`}
        >
          <input
            type="radio"
            name={id}
            value={value}
            checked={value === theme}
            aria-label={isZh ? label.zh : label.en}
            className="sr-only"
            onChange={(event) => pick(value, event.currentTarget.nextElementSibling, turn)}
          />
          <Icon className="size-3.5" />
        </label>
      ))}
    </div>
  );
}
