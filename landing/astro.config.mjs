// @ts-check
import { defineConfig } from 'astro/config';

// Static output only: the page is zero-JS and ships as files that a Cloudflare
// Worker serves straight from `dist/` (see wrangler.toml).
export default defineConfig({
  site: 'https://heeler.bybee.dev',
  build: {
    // Emit `/404.html` rather than `/404/index.html` so Workers' asset router
    // picks it up as the not-found page.
    format: 'file',
  },
});
