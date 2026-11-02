// @ts-check
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

// Static output only: the pages ship as files that a Cloudflare Worker serves
// straight from `dist/` (see wrangler.toml).
export default defineConfig({
  site: 'https://heeler.bybee.dev',
  integrations: [sitemap({
    filter: (page) => !/\/404(?:\.html)?\/?$/.test(page),
  })],
  build: {
    // Emit `/404.html` rather than `/404/index.html` so Workers' asset router
    // picks it up as the not-found page.
    format: 'file',
  },
});
