import { glob } from 'astro/loaders';
import { defineCollection } from 'astro:content';
import { z } from 'astro/zod';
import { publishedGuides } from './lib/guides.ts';

// The published guides, read in place from the repository's docs/guides/ so
// GitHub and the site render the same files. They have no frontmatter; the
// title and description come from the body (see remarkGuideTitle). The base
// resolves against the project root, so `..` reaches the repository.
const guides = defineCollection({
  loader: glob({
    base: '../docs/guides',
    pattern: publishedGuides.flatMap((slug) => [`${slug}.md`, `zh/${slug}.md`]),
  }),
  schema: z.object({}),
});

// Pages owned by the docs site itself (the index), with regular frontmatter.
const pages = defineCollection({
  loader: glob({ base: './content', pattern: '**/*.{md,mdx}' }),
  schema: z.object({
    title: z.string(),
    description: z.string(),
  }),
});

export const collections = { guides, pages };
