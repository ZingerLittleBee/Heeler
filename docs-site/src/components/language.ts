import type { I18nProviderProps } from '@fumadocs/base-ui/contexts/i18n';
import { navigate } from 'astro:transitions/client';
import { defaultLocale, isLocale, localeFromPath, localePath } from '@/lib/guides.ts';

/** Languages offered by the language switch at the bottom of the sidebar. */
const locales = [
  { locale: 'en', name: 'English' },
  { locale: 'zh', name: '简体中文' },
];

/** Simplified Chinese translations for Fumadocs UI built-in labels. */
const zhTranslations: Partial<Record<string, string>> = {
  'Ask AI(AI chat button)': '询问 AI',
  'Back to Home(404 not found page)': '返回首页',
  'Choose a language(language switcher)': '选择语言',
  'Choose a language(language switcher)(aria-label)': '选择语言',
  'Close Banner(banner)(aria-label)': '关闭横幅',
  'Close Search(search dialog)(aria-label)': '关闭搜索',
  'Close Sidebar(aria-label)': '关闭侧栏',
  'Close Sidebar(sidebar)(aria-label)': '关闭侧栏',
  'Collapse Sidebar(sidebar)(aria-label)': '收起侧栏',
  'Copied Anchor Link(heading anchor)(aria-label)': '已复制锚点链接',
  'Copied Link(accordion)(aria-label)': '已复制链接',
  'Copied Markdown(page actions)': '已复制 Markdown',
  'Copied Text(code block)(aria-label)': '已复制代码',
  'Copy Anchor Link(heading anchor)(aria-label)': '复制锚点链接',
  'Copy Link(accordion)(aria-label)': '复制链接',
  'Copy Markdown(page actions)': '复制 Markdown',
  'Copy Text(code block)(aria-label)': '复制代码',
  'Dark(theme switcher)(aria-label)': '深色',
  'Default(type table)': '默认值',
  'Edit on GitHub(edit page)': '在 GitHub 上编辑',
  'Hide Sidebar(sidebar)': '隐藏侧栏',
  'Language(language switcher)': '语言',
  'Last updated on(page footer)': '最后更新于',
  'Layout Tab(layout tab trigger)': '布局标签页',
  'Light(theme switcher)(aria-label)': '浅色',
  'Next Page(pagination)': '下一页',
  'No Headings(table of contents)': '暂无目录',
  'No results found(search dialog)': '未找到匹配结果',
  'On this page(table of contents)': '本页目录',
  'Open Search(search trigger)(aria-label)': '打开搜索',
  'Open Sidebar(aria-label)': '打开侧栏',
  'Open Sidebar(sidebar)(aria-label)': '打开侧栏',
  'Open in ChatGPT(page actions)': '在 ChatGPT 中打开',
  'Open in Claude(page actions)': '在 Claude 中打开',
  'Open in Cursor(page actions)': '在 Cursor 中打开',
  'Open in GitHub(page actions)': '在 GitHub 中打开',
  'Open in Scira AI(page actions)': '在 Scira AI 中打开',
  'Open(page actions)': '打开方式',
  'Options(aria-label)': '选项',
  'Page Not Found(404 not found page)': '未找到页面',
  'Parameters(type table)': '参数',
  'Previous Page(pagination)': '上一页',
  'Prop(type table)': '属性',
  'Read {url}, I want to ask questions about it.(page actions)': '请阅读 {url}，我想就其中的内容提问。',
  'Returns(type table)': '返回值',
  'Search(search dialog)': '搜索',
  'Search(search trigger)': '搜索',
  'Show Sidebar(sidebar)': '显示侧栏',
  'System(theme switcher)(aria-label)': '跟随系统',
  'Table of Contents(inline table of contents)': '本页目录',
  'The page you are looking for might have been removed, had its name changed, or is temporarily unavailable.(404 not found page)':
    '你要访问的页面可能已被移除、已更改名称，或暂时不可用。',
  'Theme(site menu)': '主题',
  'Toggle Menu(home layout header)(aria-label)': '切换菜单',
  'Toggle Theme(theme switcher)(aria-label)': '切换主题',
  'Type(type table)': '类型',
  'View as Markdown(page actions)': '查看 Markdown 原文',
  displayName: '简体中文',
};

/**
 * Props for Fumadocs' I18nProvider (RootProvider's `i18n`). The URL is the
 * single source of truth; switching navigates to the matching page in the
 * other language without keeping any `#fragment`, since heading anchors differ.
 */
export function useLanguage(pathname: string): Omit<I18nProviderProps, 'children'> {
  const locale = localeFromPath(pathname);
  return {
    locale,
    locales,
    defaultLanguage: defaultLocale,
    hideLocale: 'default-locale',
    translations: locale === 'zh' ? zhTranslations : undefined,
    onLocaleChange(value) {
      if (!isLocale(value) || value === locale) return;
      void navigate(localePath(pathname, value));
    },
  };
}
