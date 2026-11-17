# Heeler landing page

The marketing site at <https://heeler.bybee.dev>. Astro, static output with
two small script bundles, deployed as a static asset bundle on Cloudflare
Workers, the same Cloudflare account that serves `relay/`.

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
| `src/pages/index.astro` | The homepage: the sections in order, its metadata and JSON-LD. |
| `src/pages/404.astro` | Not-found page, served by Workers for unmatched paths. |
| `src/pages/ipad.astro` | Full iPad screenshot gallery, linked from the FAQ. |
| `src/layouts/Layout.astro` | `<head>` metadata, header, footer, the shared stylesheet and the header script. |
| `src/components/home/` | One component per homepage section (`Stage`, `Backends`, `Reach`, `Box`, `Setup`, `Faq`, `Closing`), the device frames, and the copy in `content.ts`. |
| `src/components/*.astro` | Header, footer, logo, and the pieces the other pages use. |
| `src/scripts/` | Client behaviour: `motion.ts` (frame loop, scrub, reveal, pointer helpers), `header.ts` (every page), and `home/` (the pinned stage and the sections below it). |
| `src/styles/site.css` | Design tokens, the header and the footer, shared by every page. |
| `src/styles/home/` | The homepage: `base.css` (page box, reveal, device frames), `stage.css`, `sections.css`. |
| `src/styles/substrate/` | Vendored design system used by `/ipad` and `/404` (see below). |
| `src/styles/landing.css` | Page skeleton for `/ipad` and `/404`: gutters, section rhythm, shared text roles. |
| `src/data/` | Outbound links, and the iPad screenshot order and captions. |
| `src/assets/` | Logo, store badges, five iPhone screenshots and seven iPad screenshots, optimised at build time. |

### Homepage

The homepage opens on a pinned stage: the hero hands one phone over to a
five-step story (Console, Chat, Terminal, Away, Usage) that the scroll scrubs
through, with small fragments floating above the screenshot at each step.
Below it come the backends, voice and reach, privacy, the smaller features,
setup, the FAQ and the close.

The markup is static and server-rendered, so the page reads without scripts:
the hero is one static screen, every section is visible, both ways to add a
machine are listed, and the FAQ opens and closes natively; the looping demos
rest. An inline script in the layout adds `js` to `<html>` before first paint
(and `is-still` under reduced motion); styles that hide something for an
entrance are gated on it, and the few no-script fallbacks on its absence.

Class names are short and scoped by nesting: every homepage rule sits under
`.lp.home`, and the header and footer under `.lp`, which also carries the
tokens. Breakpoints live with the rules they change. Below 900px the header
folds into a menu; the stage stacks the phone under the copy below 560px, and
below 900px in portrait.

### Motion

`src/scripts/motion.ts` runs one `requestAnimationFrame` loop for every
scroll-linked value and sleeps when settled. `scrub()` maps an element's
scroll progress to 0..1, `reveal()` adds `.is-in` to `[data-rv]` elements as
they enter, and `visible()` runs a looping demo only while it is on screen.
The stage derives all of its state from one scrub, so nothing can be skipped
or fall out of sync. Under reduced motion every value lands in its finished
state with nothing in flight.

In-page links scroll by hand from `header.ts` (Chrome drops a fragment link
clicked while an earlier smooth scroll is still running) and land clear of the
sticky header.

## Design source

The homepage comes from `1a Pocket.dc.html` in the Claude Design project
"Heeler Landing v2" (`8463d693-85b2-4ff4-859a-6b8dde9e8421`). The design is a
script-rendered prototype; this site keeps its class names, styles and timing,
and renders the markup at build time instead. Copy changes should stay in
sync with `README.md` at the repo root.

`src/styles/substrate/` is the Substrate design system from the earlier
design project (`substrate-design-system-4f544429-9771-4068-8ef1-7d18a69e56c0`),
vendored verbatim but trimmed to its token files plus the Button and Badge
rules from `components/core/core.css`. Only `/ipad` and `/404` load it; the
homepage takes just its font faces. Re-sync those files from the design
project rather than editing them.

The Geist and Geist Mono variable fonts in
`src/styles/substrate/assets/fonts/` come from the `geist` npm package (SIL
Open Font License 1.1, `LICENSE.txt` alongside them).

The screenshots are copies of `docs/images/*-iphone.png` and
`docs/images/*-ipad.png` at the repo root. They are not symlinks: refresh
them here when the app screenshots change. The stage draws each iPhone
screenshot larger than the phone's screen and pads it in the screenshot's own
edge colour, so a light screenshot never shows black around it mid-swap; a
new stage screenshot needs its edge colour added in `stage.css`. The FAQ's
iPad answer links to `/ipad` for the full gallery.

## Search and sharing

`@astrojs/sitemap` emits `sitemap-index.xml` and `sitemap-0.xml`, linked from
`robots.txt` and the layout. Only `/` and `/ipad` are indexable; the 404 page
is `noindex`. Canonical URLs match Workers' clean paths.
The homepage's JSON-LD uses the same FAQ answers as its visible content, with
no invented ratings, price, company identity, or macOS app support.

Sharing uses `public/social-card.jpg`, a 1200×630 card with the Heeler mark,
iPhone/iPad product description, and the real Agent List screenshot, and
Twitter's `summary_large_image` card. The screenshot comes from
`src/assets/screens/console-iphone.png`: crop 1206×1690 from the top-left,
resize to 398×558, and place at (750, 36), without redrawing the UI. The docs
site has an identical copy. When replacing it, update both copies together
and keep the metadata dimensions and alt accurate.

Browser icons are resized from `public/logo.png`: PNG at 48 (`favicon`), 180
(`apple-touch-icon`), 192 and 512 (`icon-192`, `icon-512`) pixels, plus an ICO
with 16/32/48-pixel frames. Recreate them with ImageMagick `magick logo.png
-resize NxN output.png` and `magick logo.png -define icon:auto-resize=48,32,16
favicon.ico`, then copy them to `docs-site/public/`. The manifest uses browser
display mode, not an offline/PWA promise.

`public/_headers` caches only fingerprinted `/_astro/*` assets immutably.
The build writes `_redirects` from the published HTML pages, making their
`.html`, trailing-slash, and `/index` aliases permanent 301 redirects to the
clean canonical URLs. Unknown paths and the noindex 404 page are not redirected.
Use `npx wrangler dev --local` to verify headers and clean-URL routing without
deploying. Managed robots rules and HTTP-to-HTTPS redirects still require
Cloudflare review. Direct `/404` access remains a 200 asset with noindex;
unmatched paths return 404. Changing that direct asset's status would require
Worker runtime logic, not a static redirect rule.

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
