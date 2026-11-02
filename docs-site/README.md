# Heeler docs site

The user guides at <https://docs.heeler.bybee.dev>. [Fumadocs](https://fumadocs.dev)
on Astro (the Base UI flavour, `@fumadocs/base-ui`, with its Spacious layout, as
a React island; Tailwind CSS 4), built to static files and deployed as an
assets-only Cloudflare Worker, the same way as `landing/`.

It is self-contained: nothing outside this directory imports from it, and it
imports nothing from `landing/` (the fonts and logo are copies).
`.github/workflows/docs-site.yml` runs for `docs-site/**`, `docs/guides/**`,
and its own file. The app workflows (`ci.yml`, `ci-node.yml`) include none of
these paths, so a docs change never starts the iOS test lanes; for the same
reason the docs site has no `make` targets, as `ci.yml` runs for any change to
the root `Makefile`.

## Commands

Use Node 22.18 or newer and pnpm 11.11.0 (pinned in `package.json`). From the repository root:

```bash
cd docs-site
pnpm install --frozen-lockfile  # install locked dependencies when needed
pnpm run dev                    # start the dev server
# Optional: pnpm run dev --host 0.0.0.0 --port 4322
```

Open the local URL printed by Astro (normally <http://localhost:4321>). Install pnpm using [its installation guide](https://pnpm.io/installation) if it is not on your PATH.

For individual commands, run these in `docs-site/`:

```bash
pnpm install --frozen-lockfile # install the committed dependency versions
pnpm run dev                  # local dev server with hot reload
pnpm test                     # unit tests for src/lib (node:test)
pnpm run check                # astro check (typechecks .astro and .ts files)
pnpm run build                # static build into dist/
pnpm run check:links          # after build: internal links, #anchors, published pages and Markdown
pnpm run preview              # serve dist/ locally
pnpm run deploy               # wrangler deploy (needs Cloudflare credentials)
```

Astro caches rendered guides in `node_modules/.astro/` and re-renders only
when a guide or `astro.config.mjs` changes. After editing the plugins in
`src/lib/markdown.ts`, run `rm -rf node_modules/.astro` before building. CI
always starts from a clean checkout.

The `Docs` React island persists across client-side navigation, including the
404 page. Astro refreshes its page props; `layout.astro` refreshes its static
article slot before the swap, since persisted island slots are not updated by
Astro. Keep persistence on the island, not on `<body>` or a wrapper.
Only the page content is keyed by pathname, so page-specific TOC observers and
state reset without remounting the sidebar, search, or theme provider.

On wide screens the Spacious layout scrolls the article inside its panel, not
the window, so neither the browser nor Astro restores that position.
`src/components/panel-scroll.ts` remembers it for each history entry and
restores it on Back and Forward (also between `#fragment` entries of one page);
a new page or `#fragment` scrolls the panel instead. It also scrolls the panel
for the scroll keys (Page Up and Page Down, Space, the arrow keys, Home, and
End) while nothing has focus, which the browser would send to the window.

After changing navigation, serve the production build and check home → guide →
another guide → Back, search-result navigation, and 404 → home. The sidebar DOM
node must stay the same while the title, article, table of contents, active
sidebar link, and "Edit on GitHub" destination update. On a wide window, also
check Back after a table-of-contents click (also after then clicking the same
page in the sidebar) and Page Down right after a page loads. Also check
copying code and heading links and the screenshot lightbox after a client-side
navigation, "Copy Markdown" and "Open", theme retention, and the mobile
navigation drawer (it takes focus when it opens and keeps it until it closes).

## Layout

| Path | What it holds |
| --- | --- |
| `src/guides.json` | Which guides are published, their localized sidebar groups and order, localized sidebar label overrides (`en` / `zh`), and each page's Lucide icon. |
| `src/content.config.ts` | Content collections: `guides` (read from `../docs/guides`, including `zh/*.md`) and `pages` (`content/index.mdx` and `content/zh/index.mdx`). |
| `src/lib/markdown.ts` | Remark/rehype plugins that adapt the GitHub-flavoured English and Chinese guides and give their conventions Fumadocs UI component markup (see below). Tests in `markdown.test.ts`. |
| `src/lib/source.ts` | Fumadocs `defineI18n` config (`en` default at `/`, `zh` at `/zh`), page source, and per-locale page trees built from both collections. |
| `src/lib/toc.ts` | The table of contents, with numbered circles for English and Chinese step headings. |
| `src/lib/raw-markdown.ts` | A guide's Markdown with absolute links, for the page actions. |
| `src/components/docs.tsx` | The Fumadocs shell: nav, sidebar, search, page header with "Copy Markdown" and "Open", "Edit on GitHub", and localized 404 panel. |
| `src/components/layout-slots.tsx` | Spacious slot overrides: the language and theme switches at the bottom of the sidebar and the navigation drawer, and the website and GitHub links always in the page header. |
| `src/components/language.ts` | Supported languages (`en` and `zh`), URL-driven locale helpers, Fumadocs UI translations and custom UI copy, and `localStorage` preference memory. |
| `src/components/search.tsx` | Search dialog backed by a per-locale static Orama index (`/api/search.json` or `/zh/api/search.json`) with `Intl.Segmenter` word tokenization for Chinese. |
| `src/components/panel-scroll.ts` | Saves and restores the article's scroll position (see above). |
| `src/components/guide-card.tsx` | `<GuideCard>` for `content/index.mdx` and `content/zh/index.mdx`: a card with a guide's localized sidebar label, route, and icon. |
| `src/components/layout.astro` | `<head>` metadata (`lang`, `canonical`, `hreflang`, OpenGraph locale) and the global stylesheet. |
| `src/pages/[...slug].astro` | Every English (`/`, `/<slug>`) and Chinese (`/zh`, `/zh/<slug>`) page. `404.astro` is the bilingual not-found page. |
| `src/pages/[...slug].md.ts` | Each guide's Markdown at `/<slug>.md` and `/zh/<slug>.md`. |
| `src/pages/api/search.json.ts` | English static search index, emitted as `dist/api/search.json`. |
| `src/pages/zh/api/search.json.ts` | Chinese static search index with `Intl.Segmenter` word tokenization, emitted as `dist/zh/api/search.json`. |
| `src/pages/images/[...path].ts` | Copies `docs/guides/images/**` to `/images/**`. |
| `src/styles/global.css` | Tailwind and Fumadocs CSS, Geist fonts, and the brand palette. |
| `src/styles/content.css` | Styles for the guide markup from `markdown.ts` (steps, task lists, tables, screenshots, `<details>`, heading buttons) and the screenshot lightbox. |
| `src/scripts/content.ts` | Article behaviour, as delegated listeners (the article is never hydrated): copying code and heading links, and the screenshot lightbox. |
| `content/index.mdx`, `content/zh/index.mdx` | The English and Simplified Chinese home pages (site-owned). |
| `scripts/check-links.mjs` | Post-build link, fragment, and bilingual parity checker (Node built-ins only). |

## Content source

The guides stay in `docs/guides/` (English) and `docs/guides/zh/` (Simplified
Chinese) as the single source of truth and must keep rendering on GitHub, so
they are not edited for the site: no frontmatter, no site-specific syntax. Each
Chinese guide starts with `<!-- Translated from docs/guides/<slug>.md at <sha> -->`
before `# Title`. The build adapts both languages (`src/lib/markdown.ts`, with
tests in `markdown.test.ts`):

- **Title, lead, and description.** The leading `# Title` becomes the page
  title and is removed from the body (skipping any top HTML comment such as the
  translation provenance comment); the first paragraph after it becomes the
  meta description (plain text, about 160 characters). If the body opens with
  that paragraph, and it is at most 320 characters of inline text (links,
  emphasis, and code are fine; images and raw HTML are not) that does not end
  in a colon (`:` or `：`), it also moves into the page header under the title,
  keeping its links and formatting.
- **Links.** Relative links are resolved against the guide's path in the
  repository. A published guide becomes `/<slug>` in English or `/zh/<slug>` in
  Chinese (keeping `#fragment`); `docs/guides/images/**` becomes `/images/**`;
  anything else in the repository becomes a GitHub link on `main` (`/blob/` for
  files, `/tree/` for directories, keeping `#L12`-style anchors). Because
  `docs/guides/zh/` is one directory deeper, links from Chinese guides to
  shared images use `../images/...` and links to unpublished files in
  `docs/guides/` use `../<file>.md`. This also covers raw HTML `<a><img></a>`
  screenshots.
- **Heading anchors.** Ids use GitHub's slugger and are assigned before the H1
  is removed, so `guide.md#some-heading` links work the same on both. Smart
  punctuation is off for the same reason. Each heading gets a copy-link
  button, like `<Heading>`.
- **GitHub alerts.** `> [!NOTE]`, `TIP`, `IMPORTANT`, `WARNING`, and `CAUTION`
  render with the markup of Fumadocs' `<Callout>` (with localized labels on
  Chinese pages).
- **Code blocks.** Highlighted by Fumadocs' `rehypeCode` and wrapped in the
  `<CodeBlock>` frame with a copy button. The frame's title comes from the
  language and the sentence before the block: "Terminal" (`终端`) for shells,
  "PowerShell", the file that sentence names for `sshconfig` (or "SSH config" /
  `SSH 配置`, highlighted as Shiki's `ssh-config`), and the `.plist` named just
  before an XML block. A text block after a sentence ending in "Expected:",
  "Expected state:", "must show:", or "The required result is:" (or Chinese
  `预期：`, `预期输出：`, `预期状态：`, `应显示：`, `必须显示：`, `所需结果为：`)
  is "Expected output" (`预期输出`), after "must not show:" (`不应显示：`,
  `不得显示：`) "Must not appear" (`不应出现`), and neither gets a copy button.
  A fence with its own meta keeps it.
- **Markdown copy.** Each guide is also served at `/<slug>.md` and
  `/zh/<slug>.md` for the "Copy Markdown" and "Open" page actions: the file as
  written, with only its link and image destinations made absolute
  (`src/lib/raw-markdown.ts`).

The guides' prose conventions also become Fumadocs UI components in both
languages, so keep following them in new guides and translations:

- **Steps.** A run of numbered `##` or `###` headings ("1. Install herdr",
  "Step 2: …", "Phase 2: …", or Chinese `步骤 2：…`, `阶段 2：…`), numbered
  from 1 with at least two, becomes `<Steps>`. The number moves into the step
  circle; the heading's text and id stay the same.
- **Callouts.** "You need …" (`你需要…`) paragraphs before the first `##`
  become an info callout. "**It worked if** …" (`**成功的标志是**…`) becomes a
  success callout, and so does a "Checkpoint:" (`检查点：`) paragraph with the
  blocks after it (a command and what it must print, say).
- **Checklists.** A bulleted list (not a task list) under a `##` "Before you
  start" or "Prerequisites" heading (`开始之前`, `准备工作`, `前置条件`) gets
  check marks. It must come right after the heading or after one lead-in
  paragraph such as "You need:" (`你需要：`).
- **Inline.** A paragraph holding only a bold "Run on: …" label (or "Run first
  on:", "Run in another session on:", "Then run on:", or Chinese
  `**运行位置：…**`, `**运行于：…**`, `**在 … 上运行**`) becomes a badge, key
  combinations in bold or code (**Control-C**) become `<kbd>`, and bold menu
  paths such as **Settings > General** get chevrons.
- **Tables.** "Field | Value" (`字段 | 值`) tables and the other header rows
  listed in `FIELD_TABLE_HEADERS` get a form-values layout; a table of
  screenshots becomes a gallery.
- **Screenshots and `<details>`.** A screenshot link opens the image in a
  lightbox instead of leaving the page, and `<details>` looks like
  `<Accordion>`.
- **Trailers.** Among the last three blocks, review metadata ("Last checked on
  …", "Checked against …", "Commands were checked …", "Commands and console
  labels were checked …", or Chinese `最后核对于 …`, `核对依据为 …`,
  `已对照 …`, `命令已对照/核对于 …`, `命令与控制台标签已对照/核对于 …`) becomes
  a muted footer line and a "Maintainers: …" (`维护者：…`) note is dropped;
  search leaves out both.

The `guides` collection's glob loader uses `base: '../docs/guides'`, which
Astro resolves against the project root, so it reads outside `docs-site/`
without extra setup. The dev server also gets `vite.server.fs.allow` for the
repository root.

### Published guides

`pairing`, `overlay-networks`, `tailscale`, `zerotier`, `easytier`,
`cloudflare-tunnel`, `vps-jump-host-setup`, `vps-jump-host`, `host-routes`,
`windows-setup`, `selinux`, `chat`, and `chat-troubleshooting`.
Maintainer documents in `docs/guides/` (`releasing.md`,
`native-windows-testing.md`), ADRs, and everything else under `docs/` stay
GitHub-only; links to them point at GitHub.

### Adding or updating a guide

1. Write `docs/guides/<slug>.md` for GitHub as usual, starting with `# Title`
   and a paragraph. Keep that paragraph short (one or two sentences) so it can
   be the page's lead.
2. Translate the guide into `docs/guides/zh/<slug>.md`, starting with
   `<!-- Translated from docs/guides/<slug>.md at <commit-sha> -->` on line 1
   followed by `# 标题`. Keep the Chinese prose conventions above so callouts,
   steps, badges, and expected-output blocks render identically.
3. Add `<slug>` to a section in `src/guides.json` with a
   [Lucide](https://lucide.dev/icons) icon under `icons`, plus short
   single-line sidebar labels under `sidebarTitles` (`en` and `zh`) if the H1
   is long.
4. Add `<GuideCard slug="<slug>">One sentence.</GuideCard>` to its section in
   both `content/index.mdx` and `content/zh/index.mdx`.
5. When editing an existing English guide, update `docs/guides/zh/<slug>.md`
   and bump the commit SHA in its top `<!-- Translated from ... -->` comment.
   To inspect what changed since a translation was last synced, compare the
   recorded SHA in `head -n 1 docs/guides/zh/<slug>.md` with
   `git diff <sha>..HEAD -- docs/guides/<slug>.md`.
6. Run `pnpm run build && pnpm run check:links`. The checker fails if any
   English or Chinese page, Markdown file, or search index is missing, an
   unlisted page is emitted, or a link or `#fragment` does not resolve.

## Design

The layout follows <https://fumadocs.dev/docs>: the Spacious layout, a page
header with "Copy Markdown" and "Open", a block table of contents, and Lucide
icons in the sidebar. The palette in `src/styles/global.css` sets Fumadocs'
`--color-fd-*` variables: most of the dark neutrals come from the landing
page's Substrate tokens (`landing/src/styles/substrate/tokens/colors.css`), and
the light ones are plain greys in the same roles. The one brand hue is teal,
set by `--color-fd-primary` in `:root` (light) and `.dark`; it marks the active
sidebar and table-of-contents items, step numbers, checklist and "Run on"
icons, task-list checkboxes, the 404 page's "Back to home" button, link
underlines, focus rings, and selection, and Fumadocs also uses it for key caps
and search matches. Teal is about as light as the muted grey of the other
items, so active table-of-contents entries also get a cue that needs no colour,
a bar beside them; keep it when changing the palette. The active sidebar item
keeps just its tinted background, as on fumadocs.dev: a heavier weight made its
label widen when it became active. Callouts keep the Substrate status hues.
When changing the palette, check text contrast (4.5:1) on the panel, on the
hover accent (a selected search result), on the sidebar's active tint, on the
step circles' tint, and on the 404 button. The theme follows the system
setting; readers can switch it at the bottom of the sidebar (of the navigation
drawer on phones). The language switch beside it offers English and 简体中文:
its active state comes from the current URL (`/` and `/<slug>` for English,
`/zh` and `/zh/<slug>` for Simplified Chinese), and switching navigates to the
same page in the chosen language while saving the preference in `localStorage`
(`src/components/language.ts`).

The Geist and Geist Mono variable fonts in `src/styles/fonts/` and
`public/logo.png` / `public/favicon.png` are copies of the files in `landing/`.
The fonts come from the `geist` npm package (SIL Open Font License 1.1,
`LICENSE.txt` alongside them).

## Search and sharing

`@astrojs/sitemap` includes only clean HTML page URLs, with reciprocal `en`
and `zh-CN` alternatives. The layout also emits `x-default` links to English,
localized Twitter metadata, and JSON-LD (`WebSite`, plus `TechArticle` and
`BreadcrumbList` for guides). It omits canonical, alternates, and JSON-LD on
the `noindex` 404 page. `pnpm run check:links` checks these build outputs.

`public/_headers` keeps guide Markdown and both static search indexes available
but sends `X-Robots-Tag: noindex`; do not disallow crawling them in robots.txt,
which would hide that directive. Its `/*.md` splat includes `/zh/` paths.
Only fingerprinted `/_astro/*` assets get immutable caching. Verify these
rules with `pnpm exec wrangler dev --local`, not Astro preview.

The build writes `_redirects` from published HTML pages in both languages.
Their `.html`, trailing-slash, and `/index` aliases redirect directly to the
clean canonical URL with status 301. Unknown paths keep their 404 status.
Direct `/404` access remains a 200 asset with noindex; static redirect rules
cannot change that response to 404 without introducing Worker runtime logic.

`rehypeGuideImages` uses real screenshot dimensions from `astro.config.mjs`
to reserve their aspect ratios and add lazy loading without changing the
GitHub guides or full-resolution lightbox links. Icons and the 1200×630 sharing
image follow [the landing site's asset notes](../landing/README.md#search-and-sharing).
Managed robots and HTTPS redirect policy still require Cloudflare review.

## Deployment

`wrangler.toml` describes an assets-only Worker (`heeler-docs`) bound to the
`docs.heeler.bybee.dev` custom domain. Pages are emitted as `dist/<slug>.html`
(`build.format: 'file'`), which Workers serves at `/<slug>`, and
`dist/404.html` answers unmatched paths.

A push to `main` that touches `docs-site/**`, `docs/guides/**`, or the docs site workflow deploys automatically, using the same `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` repository secrets as the landing page.

For a manual deploy, `pnpm exec wrangler login` once, then `pnpm run build && pnpm run deploy`.
