// @ts-check
import { writeFileSync } from 'node:fs';
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

// Static output only: the pages ship as files that a Cloudflare Worker serves
// straight from `dist/` (see wrangler.toml).
export default defineConfig({
  site: 'https://heeler.bybee.dev',
  integrations: [
    sitemap({
      filter: (page) => !/\/404(?:\.html)?\/?$/.test(page),
    }),
    {
      name: 'canonical-redirects',
      hooks: {
        'astro:build:done': ({ dir, pages }) => {
          // Exact published-page aliases override Workers' default 307s.
          // Do not redirect unknown URLs or the noindex error page.
          const redirects = pages.flatMap(({ pathname }) => {
            const path = `/${pathname.replace(/\/$/, '')}`;
            if (path === '/404') return [];
            const aliases = path === '/'
              ? ['/index', '/index.html']
              : [`${path}.html`, `${path}/`, `${path}/index`, `${path}/index.html`];
            return aliases.map((alias) => `${alias} ${path} 301`);
          });
          writeFileSync(new URL('_redirects', dir), `${redirects.join('\n')}\n`);
        },
      },
    },
  ],
  build: {
    // Emit `/404.html` rather than `/404/index.html` so Workers' asset router
    // picks it up as the not-found page.
    format: 'file',
  },
});
