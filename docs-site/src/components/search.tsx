import { useStaticSearch } from 'fumadocs-core/search/client';
import {
  SearchDialog,
  SearchDialogClose,
  SearchDialogContent,
  SearchDialogHeader,
  SearchDialogIcon,
  SearchDialogInput,
  SearchDialogList,
  SearchDialogOverlay,
  type SharedProps,
} from '@fumadocs/base-ui/components/dialog/search';
import { useI18n } from '@fumadocs/base-ui/contexts/i18n';
import { defaultLocale, isLocale, type Locale } from '@/lib/guides.ts';

/** Path of a locale's prebuilt search index (src/pages/api/search.json.ts). */
export function searchIndexPath(locale: Locale = defaultLocale): string {
  return locale === defaultLocale ? '/api/search.json' : `/${locale}/api/search.json`;
}

// Static search: the browser downloads the active locale's index once and
// queries it locally, so the site needs no server.
export default function StaticSearchDialog(props: SharedProps) {
  const { locale: active } = useI18n();
  const locale = active && isLocale(active) ? active : defaultLocale;
  const search = useStaticSearch({ from: searchIndexPath(locale), locale });

  return (
    <SearchDialog {...search} {...props}>
      <SearchDialogOverlay />
      <SearchDialogContent>
        <SearchDialogHeader>
          <SearchDialogIcon />
          <SearchDialogInput />
          <SearchDialogClose />
        </SearchDialogHeader>
        <SearchDialogList />
      </SearchDialogContent>
    </SearchDialog>
  );
}
