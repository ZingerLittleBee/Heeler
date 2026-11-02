// @ts-check
import { readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import mdx from '@astrojs/mdx';
import { unified } from '@astrojs/markdown-remark';
import react from '@astrojs/react';
import sitemap from '@astrojs/sitemap';
import tailwindcss from '@tailwindcss/vite';
import { imageMetadata } from 'astro/assets/utils';
import { defineConfig } from 'astro/config';
import { rehypeCode, remarkHeading } from 'fumadocs-core/mdx-plugins';
import {
  rehypeFumadocsElements,
  rehypeGithubAlerts,
  rehypeGuideComponents,
  rehypeGuideImages,
  remarkGuideCode,
  remarkGuideLinks,
  remarkGuideTitle,
} from './src/lib/markdown.ts';

// The guides live outside this project, in the repository's docs/guides/.
const repoRoot = fileURLToPath(new URL('..', import.meta.url));

// Raw HTML screenshots bypass Astro's image component. Read their real sizes
// so the Markdown pipeline can reserve space without editing the GitHub guides.
const imagesRoot = join(repoRoot, 'docs/guides/images');
const imageSizes = Object.fromEntries(await Promise.all(
  readdirSync(imagesRoot, { recursive: true, withFileTypes: true })
    .filter((file) => file.isFile() && /\.(png|jpe?g|webp|gif)$/i.test(file.name))
    .map(async (file) => {
      const path = join(file.parentPath, file.name);
      return [`/images/${path.slice(imagesRoot.length + 1).split('\\').join('/')}`, await imageMetadata(readFileSync(path), path)];
    }),
));

/** @param {string} repoPath */
function isDirectory(repoPath) {
  try {
    return statSync(join(repoRoot, repoPath)).isDirectory();
  } catch {
    return false;
  }
}

// Order matters: heading ids are assigned (GitHub slugs, H1 included) before
// remarkGuideTitle removes the H1, so the ids match the anchors GitHub renders.
/** @type {import('@astrojs/markdown-remark').UnifiedProcessorOptions['remarkPlugins']} */
const remarkPlugins = [
  [remarkGuideLinks, { repoRoot, isDirectory }],
  remarkHeading,
  [remarkGuideTitle, { repoRoot }],
  // Code block titles and the `sshconfig` -> Shiki `ssh-config` fence name.
  remarkGuideCode,
];

// Static output only: Fumadocs renders as a React island, and a Cloudflare
// Worker serves `dist/` as plain files (see wrangler.toml).
export default defineConfig({
  site: 'https://docs.heeler.bybee.dev',
  build: {
    // Emit `/404.html` and `/tailscale.html` rather than `…/index.html`, so
    // Workers' asset router picks up the not-found page (same as landing/).
    format: 'file',
  },
  prefetch: { prefetchAll: true },
  markdown: {
    processor: unified({
      remarkPlugins,
      rehypePlugins: [
        rehypeGithubAlerts,
        [rehypeGuideImages, imageSizes],
        // Steps, callouts, and the lead; before rehypeCode, while code blocks
        // are still plain <pre> elements.
        rehypeGuideComponents,
        // Fence languages Shiki does not bundle render as plain text instead
        // of failing the build.
        [rehypeCode, { fallbackLanguage: 'text' }],
        rehypeFumadocsElements,
      ],
      // GitHub renders straight quotes and dashes; smart punctuation would also
      // change heading text and therefore the anchors other guides link to.
      smartypants: false,
    }),
    // Fumadocs' rehypeCode highlights code blocks instead (light and dark themes).
    syntaxHighlight: false,
  },
  integrations: [
    react(),
    mdx({ extendMarkdownConfig: true }),
    sitemap({
      filter: (page) => !/\/404(?:\.html)?\/?$/.test(page),
      i18n: { defaultLocale: 'en', locales: { en: 'en', zh: 'zh-CN' } },
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
  vite: {
    plugins: [tailwindcss()],
    // Lets the image route find docs/guides/images at build time.
    define: { 'import.meta.env.HEELER_REPO_ROOT': JSON.stringify(repoRoot) },
    // The dev server reads the guides from outside the project root.
    server: { fs: { allow: [repoRoot] } },
  },
});
