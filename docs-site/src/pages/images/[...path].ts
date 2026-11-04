import { readdir, readFile } from 'node:fs/promises';
import { extname, join } from 'node:path';
import type { APIRoute, GetStaticPaths } from 'astro';
import { guideImagesDir } from '@/lib/guides.ts';

// Serves docs/guides/images/** at /images/**. The guides embed screenshots as
// raw HTML (<a><img></a>), which Astro's image pipeline does not process, so
// the files are emitted as-is and remarkGuideLinks points the links here.
const imagesRoot = join(import.meta.env.HEELER_REPO_ROOT, guideImagesDir);

const contentTypes: Record<string, string> = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.svg': 'image/svg+xml',
};

export const getStaticPaths = (async () => {
  const files = await readdir(imagesRoot, { recursive: true, withFileTypes: true });
  return files
    .filter((file) => file.isFile() && extname(file.name).toLowerCase() in contentTypes)
    .map((file) => {
      const path = join(file.parentPath, file.name).slice(imagesRoot.length + 1).split('\\').join('/');
      return { params: { path } };
    });
}) satisfies GetStaticPaths;

export const GET: APIRoute = async ({ params }) => {
  const path = params.path ?? '';
  const type = contentTypes[extname(path).toLowerCase()];
  if (type === undefined) return new Response(null, { status: 404 });
  return new Response(await readFile(join(imagesRoot, path)), { headers: { 'Content-Type': type } });
};
