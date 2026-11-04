import { statSync } from 'node:fs';
import { join } from 'node:path';
import type { APIRoute, GetStaticPaths } from 'astro';
import { guidesDir } from '@/lib/guides.ts';
import { toRawMarkdown } from '@/lib/raw-markdown.ts';
import { source } from '@/lib/source.ts';

// Each guide's Markdown at /<slug>.md, for the "Copy Markdown" and "Open"
// page actions (src/components/docs.tsx). The site's own MDX pages have none.
const repoRoot = import.meta.env.HEELER_REPO_ROOT;

function isDirectory(repoPath: string): boolean {
  try {
    return statSync(join(repoRoot, repoPath)).isDirectory();
  } catch {
    return false;
  }
}

export const getStaticPaths = (() =>
  source
    .getPages()
    .filter((page) => page.data.entry.collection === 'guides')
    .map((page) => ({ params: { slug: page.url.slice(1) }, props: { page } }))) satisfies GetStaticPaths;

type Props = ReturnType<typeof getStaticPaths>[number]['props'];

export const GET: APIRoute<Props> = ({ props: { page }, site }) => {
  if (site === undefined) throw new Error('astro.config.mjs must set `site` for absolute links');
  const markdown = toRawMarkdown(page.data.entry.body ?? '', {
    sourcePath: `${guidesDir}/${page.path}`,
    site: site.href,
    isDirectory,
  });
  return new Response(markdown, { headers: { 'Content-Type': 'text/markdown; charset=utf-8' } });
};
