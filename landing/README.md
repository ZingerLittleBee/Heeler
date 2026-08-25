# Heeler landing page

The marketing site at <https://heeler.bybee.dev>. Astro, zero client-side
JavaScript, deployed as a static asset bundle on Cloudflare Workers — the same
Cloudflare account that serves `relay/`.

It is self-contained on purpose: nothing outside this directory imports from
it, and no other workflow in the repo depends on it. `ci.yml` excludes
`landing/**` and `.github/workflows/landing.yml` only runs for it, so a copy
edit here never starts an iOS build.

## Commands

```bash
npm install          # once
npm run dev          # local dev server with hot reload
npm run check        # astro check (typechecks .astro templates)
npm run build        # static build into dist/
npm run preview      # serve dist/ as Cloudflare will
npm run deploy       # wrangler deploy (needs Cloudflare credentials)
```

## Layout

| Path | What it holds |
| --- | --- |
| `src/pages/index.astro` | The page: composes the section components in order. |
| `src/pages/404.astro` | Not-found page, served by Workers for unmatched paths. |
| `src/layouts/Layout.astro` | `<head>` metadata, header, footer, global CSS imports. |
| `src/components/*.astro` | One component per section, plus `Button`/`Badge`. |
| `src/styles/substrate/` | Vendored design system (see below). |
| `src/styles/landing.css` | Page skeleton: gutters, section rhythm, shared text roles. |
| `src/assets/` | Logo and the six iPhone screenshots, optimised at build time. |

Breakpoints live with the component that needs them. The source design is
desktop-only; the responsive behaviour (header nav collapse, the screenshot
rail below 1060px, single-column grids on phones) was added here.

## Design source

The page is an implementation of `Heeler Landing.dc.html` in the Claude Design
project [项目落地页制作](https://claude.ai/design/p/eebe1402-ef74-4c67-9a76-c8ca5d6124c6).
Copy changes should stay in sync with `README.md` at the repo root, which is
where the content came from.

`src/styles/substrate/` is the Substrate design system from that project
(`substrate-design-system-4f544429-9771-4068-8ef1-7d18a69e56c0`), vendored
verbatim but trimmed to what this page renders: every token file plus the
Button and Badge rules from `components/core/core.css`. Re-sync those files from
the design project rather than editing them; page-specific CSS belongs in
`landing.css` or a component's `<style>` block.

The Geist and Geist Mono variable fonts in
`src/styles/substrate/assets/fonts/` come from the `geist` npm package (SIL
Open Font License 1.1, `LICENSE.txt` alongside them).

The screenshots are copies of `docs/images/*.png` at the repo root, not
symlinks — refresh them here when the app screenshots change.

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
