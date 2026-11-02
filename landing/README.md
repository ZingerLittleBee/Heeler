# Heeler landing page

The marketing site at <https://heeler.bybee.dev>. Astro, static output with
one small inline script on the homepage, deployed as a static asset bundle on
Cloudflare Workers — the same Cloudflare account that serves `relay/`.

It is self-contained on purpose: nothing outside this directory imports from
it, and no other workflow in the repo depends on it. `ci.yml` (iOS) and
`ci-node.yml` (plugin / relay / codegen) do not include `landing/**`, and
`.github/workflows/landing.yml` only runs for it, so a copy edit here never
starts an iOS build.

## Commands

```bash
npm install          # once
npm run dev          # local dev server with hot reload
npm run check        # astro check (typechecks .astro templates)
npm run build        # static build into dist/
npm run check:seo    # check canonical URLs, sitemap, JSON-LD, and linked assets
npm run preview      # Astro preview; use wrangler dev for Workers routing/headers
npm run deploy       # wrangler deploy (needs Cloudflare credentials)
```

## Layout

| Path | What it holds |
| --- | --- |
| `src/pages/index.astro` | The homepage: hero, seven chapters beside a sticky contents list, Security, numbers, FAQ, close and source. Holds the page's inline script and the chapter steps. |
| `src/pages/404.astro` | Not-found page, served by Workers for unmatched paths. |
| `src/pages/ipad.astro` | Full iPad screenshot gallery, linked from the FAQ. |
| `src/layouts/Layout.astro` | `<head>` metadata, header, footer, global CSS imports. |
| `src/components/home/` | The homepage's parts (hero wall, chapter head, step figure, FAQ list, and so on), its copy in `content.ts`, figure sizes in `figures.ts`, and the shared `home-*` type roles in `home.css`. |
| `src/components/*.astro` | Header, footer, and the pieces the other pages use. |
| `src/styles/substrate/` | Vendored design system (see below). |
| `src/styles/landing.css` | Page skeleton: gutters, section rhythm, shared text roles. |
| `src/assets/` | Logo, thirteen iPhone screenshots, and seven iPad screenshots, optimised at build time. |
| `src/data/ipad-screens.ts` | Shared iPad screenshot order and captions. |
| `public/figures/*.html` | One interactive figure per chapter except Usage, which shows screenshots; embedded with lazy iframes (see below). |

Breakpoints live with the component that needs them. Below 960px the contents
list becomes a strip of chips under the header and each chapter's figure pins
above its steps.

### Motion

The homepage's motion is CSS scroll-driven animation where the browser has it,
with an IntersectionObserver fallback, and none of it runs under reduced
motion. The inline script in `index.astro` marks the current chapter, steps
each chapter's figure with the scroll, counts the stats up, copies the pair
command, and scrolls in-page links itself (Chrome ignores a fragment link
clicked while an earlier smooth scroll is still running). The FAQ animates its
answers open and closed from `FaqList.astro`.

## Design source

The homepage layout comes from `Heeler Landing Redesign.dc.html` in the Claude
Design project `e4156ac4-d37e-42fa-bcda-0bcb77e2d0a7` (option 1c, reworked as
an interactive draft with scroll-driven chapters). Copy changes should stay in
sync with `README.md` at the repo root, which is where most of the content
came from.

`src/styles/substrate/` is the Substrate design system from that project
(`substrate-design-system-4f544429-9771-4068-8ef1-7d18a69e56c0`), vendored
verbatim but trimmed to what this page renders: every token file plus the
Button and Badge rules from `components/core/core.css`. Re-sync those files from
the design project rather than editing them; page-specific CSS belongs in
`landing.css` or a component's `<style>` block.

The Geist and Geist Mono variable fonts in
`src/styles/substrate/assets/fonts/` come from the `geist` npm package (SIL
Open Font License 1.1, `LICENSE.txt` alongside them).

The iPhone screenshots are copies of `docs/images/*-iphone.png` at the repo root,
except `widgets-limits-iphone.png`, which only the Usage chapter shows.
The iPad screenshots are copies of `docs/images/*-ipad.png`.
They are not symlinks — refresh them here when the app screenshots change.
The homepage hero shows the iPhone screenshots as a decorative wall; the FAQ's
iPad answer links to `/ipad` for the full gallery.

## Figures

Each chapter's figure is a generated, self-contained page (inline SVG and
script, dark theme, `noindex`) in `public/figures/`, so it is replaced whole
rather than edited. The pages come from the anatomy figure sources, through a
build script that lives with them (`landing-embeds.py`, outside this repo). It
takes each figure's dark page and lets the card fill its iframe, hides the
legend, numbers the corner in chapter order (Fig 1 to Fig 6), moves the first
tour beat to 0.8 s, and inserts the scroll hook.

The hook is the contract between a figure and the homepage:
`window.heelerFigure.go(beat)` stops the figure's idle tour and plays to that
beat at the tour's own pace, without blanking the drawing on a step back.
Until the page calls it, the figure runs its tour. Each `StepFigure` step names
a beat (`data-beat`), and the page script calls `go()` for the step on the
reading line. A new figure needs a hook whose beats match its steps.

Each card fills its iframe, and `src/components/home/figures.ts` sizes the frame
from the figure's viewBox ratio and card padding, wide and below 560px. A figure
whose drawing or padding changes needs its numbers there updated too.

## Search and sharing

`@astrojs/sitemap` emits `sitemap-index.xml` and `sitemap-0.xml`, linked from
`robots.txt` and the layout. Only `/` and `/ipad` are indexable; the 404 page
and embedded figures are `noindex`. Canonical URLs match Workers' clean paths.
The homepage's JSON-LD uses the same FAQ answers as its visible content, with
no invented ratings, price, company identity, or macOS app support.

Sharing still uses the existing 1024-square logo and Twitter's `summary` card.
A designed 1200×630 card remains a separate asset task; only switch to
`summary_large_image` when that asset exists, and update its dimensions and alt.

Browser icons are resized from `public/logo.png`: PNG at 48 (`favicon`), 180
(`apple-touch-icon`), 192 and 512 (`icon-192`, `icon-512`) pixels, plus an ICO
with 16/32/48-pixel frames. Recreate them with ImageMagick `magick logo.png
-resize NxN output.png` and `magick logo.png -define icon:auto-resize=48,32,16
favicon.ico`, then copy them to `docs-site/public/`. The manifest uses browser
display mode, not an offline/PWA promise.

`public/_headers` caches only fingerprinted `/_astro/*` assets immutably.
Use `npx wrangler dev --local` to verify headers and clean-URL routing without
deploying. Managed robots rules, HTTP-to-HTTPS redirects, and the platform's
307 HTML normalization are hosting policy, not controlled by the page metadata.

## Deployment

`wrangler.toml` describes an assets-only Worker (`heeler-landing`) bound to the
`heeler.bybee.dev` custom domain, so the hostname is part of the deploy rather
than dashboard state. The DNS record is created by Cloudflare when the custom
domain route is first deployed; `bybee.dev` must be in the same account.

A push to `main` that touches `landing/**` deploys automatically. That needs
two repository secrets:

- `CLOUDFLARE_API_TOKEN` — Workers Scripts:Edit on the account owning `bybee.dev`
- `CLOUDFLARE_ACCOUNT_ID`

For a manual deploy, `wrangler login` once, then `npm run build && npm run
deploy`.
